#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""xctrace 트레이스 한 개를 JSON으로 요약한다. 들어 있는 표에 따라 항목이 달라진다.

- hitches                       → hitch 수·합계·최대·hitch time ratio(ms/s), 창(window) 안만
- time-profile (Time Profiler)  → 메인 스레드 앱 프레임 상위(inclusive ms), `--frame` 부분 문자열의 누적 ms
- activity-monitor-process-live → 앱 최대 physical footprint
- os-signpost                   → `--signpost` 이름 구간의 개수·합계 ms

창은 UI 테스트의 `PERF_WINDOW <이름> ... start_epoch=<s> end_epoch=<s>` 줄과 TOC의 녹화 시작 시각으로 계산한다
(기기·Mac 시계가 NTP로 맞춰져 있다고 가정). 창이 없으면 트레이스 전체다.

  trace_summary.py <trace> [--app RichMarkdownDemo] [--ui-log ui.log --window <이름>] [--frame RichMarkdownParser.parse]
  trace_summary.py --self-test
"""
import argparse
import datetime
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

LIBRARY_HINTS = ("RichMarkdown", "Latex", "MathRender", "Mermaid", "Prism", "Markdown", "RaTeX", "ratex")
IGNORED_FRAMES = {"main", "<deduplicated_symbol>"}


def xctrace(*args, attempts=8):
    """xctrace export는 심볼 정리 중 segfault(rc 139)로 자주 끝난다(실측, 다시 돌리면 통과) — 몇 번 더 시도한다."""
    for _ in range(attempts):
        run = subprocess.run(["xcrun", "xctrace", *args], capture_output=True, text=True, check=False)
        if run.returncode == 0:
            return run.stdout
    sys.stderr.write(f"xctrace {' '.join(args[:3])} 실패 rc={run.returncode}\n")
    return run.stdout


def toc_info(trace):
    toc = xctrace("export", "--input", trace, "--toc")
    start = re.search(r"<start-date>([^<]+)</start-date>", toc)
    schemas = set(re.findall(r'schema="([^"]+)"', toc))
    started = datetime.datetime.fromisoformat(start.group(1)).timestamp() if start else None
    return started, schemas


def parse_table(xml_text):
    """xctrace export XML → 열 이름을 키로 한 행 목록. id/ref 압축을 풀어 요소를 그대로 돌려준다."""
    if "<trace-query-result" not in xml_text:
        return []
    node = ET.fromstring(xml_text).find("node")
    if node is None or node.find("schema") is None:
        return []
    columns = [col.findtext("mnemonic") for col in node.find("schema").findall("col")]
    registry, rows = {}, []
    for row in node.findall("row"):
        for element in row.iter():
            if "id" in element.attrib:
                registry[element.get("id")] = element
        cells = [resolve(cell, registry) for cell in row]
        rows.append(dict(zip(columns, cells)))
    return rows


def resolve(element, registry):
    return registry.get(element.get("ref"), element) if element is not None and "ref" in element.attrib else element


def export(trace, schema):
    return parse_table(xctrace("export", "--input", trace, "--xpath",
                               f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'))


def number(element):
    try:
        return int(element.text)
    except (AttributeError, TypeError, ValueError):
        return None


def label(element):
    return element.get("fmt", "") if element is not None else ""


# 기기 시계 epoch ↔ 트레이스 시각 대응 오차. 교차 확인 트레이스에서 측정 구간의 첫 parse 표본이
# epoch 창보다 0.14–0.21 s 늦었다(iPad Pro M5 실측). 경계에서 이벤트를 놓치지 않게 양쪽을 넓혀 세고,
# 비율(ms/s)의 분모는 기기 시계로 잰 시나리오 길이를 그대로 쓴다.
WINDOW_SLACK_MS = 300


def in_window(start_ns, window):
    return window is None or window[0] - WINDOW_SLACK_MS <= start_ns / 1e6 <= window[1] + WINDOW_SLACK_MS


def hitch_summary(rows, app, window, duration_s):
    hitches = [
        {"start_ms": number(r["start"]) / 1e6, "ms": number(r["duration"]) / 1e6,
         "system": label(r.get("is-system")) == "Yes", "process": label(r.get("process"))}
        for r in rows if number(r.get("start")) is not None and in_window(number(r["start"]), window)
    ]
    mine = [h for h in hitches if h["process"].startswith(app)]
    span_s = (window[1] - window[0]) / 1000 if window else duration_s
    total = sum(h["ms"] for h in mine)
    return {
        "count": len(mine),
        "total_ms": round(total, 1),
        "max_ms": round(max((h["ms"] for h in mine), default=0), 1),
        "ratio_ms_per_s": round(total / span_s, 2) if span_s else None,
        "window_s": round(span_s, 2) if span_s else None,
        "other_process_count": len(hitches) - len(mine),
        "durations_ms": [round(h["ms"], 1) for h in mine],
    }


def resolve_stacks(xml_text):
    """time-profile 행마다 (시각 ns, 스레드 이름, 프로세스 이름, 가중치 ns, 프레임 목록)."""
    if "<trace-query-result" not in xml_text:
        return []
    node = ET.fromstring(xml_text).find("node")
    columns = [col.findtext("mnemonic") for col in node.find("schema").findall("col")]
    registry, samples = {}, []
    for row in node.findall("row"):
        for element in row.iter():
            if "id" in element.attrib:
                registry[element.get("id")] = element
        cells = dict(zip(columns, [resolve(cell, registry) for cell in row]))
        stack = cells.get("stack")
        if stack is not None:
            backtrace = stack if stack.tag == "backtrace" else resolve(stack.find("backtrace"), registry)
            frames = []
            for frame in (backtrace if backtrace is not None else []):
                frame = resolve(frame, registry)
                binary = resolve(frame.find("binary"), registry)
                frames.append((frame.get("name", ""), binary.get("name", "") if binary is not None else ""))
        else:
            frames = []
        samples.append((number(cells.get("time")) or 0, label(cells.get("thread")),
                        label(cells.get("process")), number(cells.get("weight")) or 0, frames))
    return samples


def profile_summary(samples, app, window, frame_queries, top=8):
    scoped = [s for s in samples if s[2].startswith(app) and in_window(s[0], window)]
    main = [s for s in scoped if "Main Thread" in s[1]]
    inclusive, leaf, leaf_binary = {}, {}, {}
    for _, _, _, weight, frames in main:
        if frames:
            leaf_binary[frames[0][1]] = leaf_binary.get(frames[0][1], 0) + weight
        app_frames = [name for name, binary in frames if binary == app and name not in IGNORED_FRAMES
                      and not name.startswith("0x")]
        for name in set(app_frames):
            inclusive[name] = inclusive.get(name, 0) + weight
        library = [name for name in app_frames if any(hint in name for hint in LIBRARY_HINTS)]
        if library:
            leaf[library[0]] = leaf.get(library[0], 0) + weight
    rank = lambda table: [{"frame": k, "ms": round(v / 1e6, 1)} for k, v in sorted(table.items(), key=lambda kv: -kv[1])[:top]]
    result = {
        "app_samples_ms": round(sum(s[3] for s in scoped) / 1e6, 1),
        "main_thread_ms": round(sum(s[3] for s in main) / 1e6, 1),
        # XCUITest 러너의 접근성 조회가 앱 메인 스레드에서 도는 시간(하네스 부하, DEVELOPMENT.md §7).
        "main_accessibility_ms": round(sum(s[3] for s in main if any(
            "ccessibility" in name or binary.startswith(("AXRuntime", "UIAccessibility")) for name, binary in s[4]
        )) / 1e6, 1),
        "main_top_app_frames": rank(inclusive),
        "main_top_library_leaf_frames": rank(leaf),
        # 메인 스레드 표본의 leaf 바이너리. XCUITest 접근성 조회 부하(AXRuntime·UIAccessibility 등)가 여기서 보인다.
        "main_leaf_binaries": [{"binary": k, "ms": v["ms"]} for k, v in
                               [(b, {"ms": round(w / 1e6, 1)}) for b, w in sorted(leaf_binary.items(), key=lambda kv: -kv[1])[:top]]],
    }
    for query in frame_queries:
        hits = [s for s in scoped if any(query in name for name, _ in s[4])]
        result.setdefault("frame_ms", {})[query] = {
            "all_threads_ms": round(sum(s[3] for s in hits) / 1e6, 1),
            "samples": len(hits),
        }
    return result


def footprint_summary(rows, app):
    values = [number(r.get("memory-physical-footprint")) for r in rows if label(r.get("process")).startswith(app)]
    values = [v for v in values if v is not None]
    return {"samples": len(values), "peak_footprint_mib": round(max(values) / 2**20, 1) if values else None,
            "min_footprint_mib": round(min(values) / 2**20, 1) if values else None}


def signpost_summary(rows, name):
    durations = [number(r.get("duration")) for r in rows if label(r.get("name")) == name]
    durations = [d for d in durations if d is not None]
    return {"name": name, "count": len(durations), "total_ms": round(sum(durations) / 1e6, 2)}


def window_from_log(ui_log, name, trace_start):
    pattern = re.compile(rf"^PERF_WINDOW {re.escape(name)} .*start_ms=(-?\d+) end_ms=(-?\d+)"
                         rf"(?: start_epoch=([\d.]+) end_epoch=([\d.]+))?")
    with open(ui_log, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = pattern.match(line.strip())
            if not match:
                continue
            if match.group(3) and trace_start:
                start_epoch = float(match.group(3))
                start = 0.0 if start_epoch == 0 else (start_epoch - trace_start) * 1000  # 0 = 녹화 시작
                return start, (float(match.group(4)) - trace_start) * 1000
            return float(match.group(1)), float(match.group(2))
    return None


def summarize(trace, app, ui_log, window_name, frame_queries, signpost):
    trace_start, schemas = toc_info(trace)
    window = window_from_log(ui_log, window_name, trace_start) if ui_log and window_name else None
    duration = re.search(r"<duration>([\d.]+)</duration>", xctrace("export", "--input", trace, "--toc"))
    duration_s = float(duration.group(1)) if duration else None
    result = {"trace": trace, "window": window_name, "window_ms": [round(v) for v in window] if window else None,
              "duration_s": duration_s}
    if "hitches" in schemas:
        result["hitches"] = hitch_summary(export(trace, "hitches"), app, window, duration_s)
    if "time-profile" in schemas:
        xml_text = xctrace("export", "--input", trace, "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
        result["profile"] = profile_summary(resolve_stacks(xml_text), app, window, frame_queries)
    if "activity-monitor-process-live" in schemas:
        result["memory"] = footprint_summary(export(trace, "activity-monitor-process-live"), app)
    if signpost and "os-signpost-interval" in schemas:
        result["signpost"] = signpost_summary(export(trace, "os-signpost-interval"), signpost)
    return result


def report(directory, top=3):
    """한 기기 폴더의 *.summary.json·*.xcprof.json을 시나리오 표(Markdown)로 묶는다."""
    import glob
    import os
    rows = ["| 시나리오 | 창 s | hitch 수 | 합계 ms | 최대 ms | ms/s | 메인 스레드 ms (접근성) | 메인 스레드 앱 프레임 (TP incl. ms) | CPU Profiler 라이브러리 프레임 (xcprof, 앱 CPU 표본 중 incl. %) | 최대 footprint MiB |",
            "|---|---:|---:|---:|---:|---:|---:|---|---|---:|"]
    for path in sorted(glob.glob(os.path.join(directory, "*.hitches.*.summary.json"))):
        summary = json.load(open(path))
        scenario, window = os.path.basename(path).split(".hitches.")[0], summary["window"]
        hitches, profile = summary.get("hitches", {}), summary.get("profile", {})
        frames = ", ".join(f"{f['frame'][:48]} {f['ms']:g}" for f in profile.get("main_top_app_frames", [])[:top])
        cpu_path = os.path.join(directory, f"{scenario}.cpu.{window}.xcprof.json")
        cpu = ""
        if os.path.exists(cpu_path) and os.path.getsize(cpu_path):
            user = [f for f in json.load(open(cpu_path)).get("user_frames", [])
                    if f["name"] not in IGNORED_FRAMES and not f["name"].startswith(("0x", "closure #1 in static", "static "))]
            library = sorted((f for f in user if any(h in f["name"] for h in LIBRARY_HINTS)),
                             key=lambda f: -f["inclusive_pct"])
            # xcprof의 ms는 "표본 비율 × 창 길이"라 프로세스가 놀고 있으면 부풀려진다. 비율(%)만 쓴다.
            cpu = ", ".join(f"{f['name'][:48]} {f['inclusive_pct']:g}%" for f in library[:top])
        memory_path = os.path.join(directory, f"{scenario}.memory.{window}.summary.json")
        peak = json.load(open(memory_path)).get("memory", {}).get("peak_footprint_mib") if os.path.exists(memory_path) else None
        rows.append(f"| {window} | {hitches.get('window_s', '-')} | {hitches.get('count', '-')} | {hitches.get('total_ms', '-')} | "
                    f"{hitches.get('max_ms', '-')} | {hitches.get('ratio_ms_per_s', '-')} | "
                    f"{profile.get('main_thread_ms', '-')} ({profile.get('main_accessibility_ms', '-')}) | {frames} | {cpu} | "
                    f"{peak if peak is not None else '-'} |")
    return "\n".join(rows)


def self_test():
    xml_text = """<?xml version="1.0"?><trace-query-result><node><schema name="hitches">
    <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col>
    <col><mnemonic>process</mnemonic></col><col><mnemonic>is-system</mnemonic></col></schema>
    <row><start-time id="1">1000000000</start-time><duration id="2">8333333</duration><process id="3" fmt="App (1)"/><boolean id="4" fmt="No">0</boolean></row>
    <row><start-time id="5">2000000000</start-time><duration id="6">16666666</duration><process ref="3"/><boolean ref="4"/></row>
    <row><start-time id="7">9000000000</start-time><duration ref="6"/><process ref="3"/><boolean ref="4"/></row>
    </node></trace-query-result>"""
    summary = hitch_summary(parse_table(xml_text), "App", (500, 5000), 10)
    assert summary["count"] == 2 and summary["total_ms"] == 25.0 and summary["max_ms"] == 16.7, summary
    assert summary["ratio_ms_per_s"] == round(25.0 / 4.5, 2)
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace", nargs="?")
    parser.add_argument("--app", default="RichMarkdownDemo")
    parser.add_argument("--ui-log")
    parser.add_argument("--window")
    parser.add_argument("--frame", action="append", default=[])
    parser.add_argument("--signpost")
    parser.add_argument("--window-only", action="store_true", help="xcprof analyze용 `--start-ms A --end-ms B`만 출력")
    parser.add_argument("--report", metavar="DIR", help="기기 폴더의 요약을 시나리오 표로 출력")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.report:
        return print(report(args.report))
    if not args.trace:
        parser.error("트레이스 경로가 필요하다")
    if args.window_only:
        window = window_from_log(args.ui_log, args.window, toc_info(args.trace)[0]) if args.ui_log and args.window else None
        print(f"--start-ms {max(0, round(window[0]))} --end-ms {round(window[1])}" if window else "")
        return
    json.dump(summarize(args.trace, args.app, args.ui_log, args.window, args.frame, args.signpost),
              sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
