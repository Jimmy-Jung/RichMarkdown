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

`--window-signpost <이름>`을 주면 앱이 남긴 os_signpost 구간(SSE 데모의 `sse-stream`: 첫 청크 직전 → 마지막
flush 직후)을 두 번째 창으로 쓴다. 트레이스 시계 그대로라 epoch 대응 오차가 없고 끝의 유휴 꼬리가 빠진다.
flush 뒤의 최종 렌더는 창 양끝 여유(`WINDOW_SLACK_MS`)로 hitch·Time Profiler·CPU Profiler에 똑같이 든다.
결과는 `window_stream`·`hitches_stream`·`profile_stream`에 따로 담고, 기존 키(`hitches`·`profile`)는 UI 로그 창
그대로 둬 이전 수치와 나란히 비교한다. 구간이 트레이스에 없으면 UI 로그 창으로 대신한다(`window_stream.source`).

  trace_summary.py <trace> [--app RichMarkdownDemo] [--ui-log ui.log --window <이름>] [--window-signpost sse-stream]
                   [--frame RichMarkdownParser.parse]
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
    """xctrace export XML → 열 이름을 키로 한 행 목록. id/ref 압축을 풀어 요소를 그대로 돌려준다.
    같은 schema 표가 여럿이면(os_signpost·Points of Interest를 함께 기록) 모두 이어 붙인다."""
    if "<trace-query-result" not in xml_text:
        return []
    registry, rows = {}, []
    for node in ET.fromstring(xml_text).findall("node"):
        if node.find("schema") is None:
            continue
        columns = [col.findtext("mnemonic") for col in node.find("schema").findall("col")]
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
    if element is None:
        return ""
    return element.get("fmt") or (element.text or "")


# 기기 시계 epoch ↔ 트레이스 시각 대응 오차. 교차 확인 트레이스에서 측정 구간의 첫 parse 표본이
# epoch 창보다 0.14–0.21 s 늦었다(iPad Pro M5 실측). 경계에서 이벤트를 놓치지 않게 양쪽을 넓혀 세고,
# 비율(ms/s)의 분모는 기기 시계로 잰 시나리오 길이를 그대로 쓴다.
# signpost 창(`sse-stream`)에는 epoch 오차가 없지만 같은 여유가 스트림 끝 꼬리 몫을 한다. 구간은 마지막 flush
# 직후에 끝나고, 최종 parse 게시·렌더와 스트리밍 종료 재구성(streaming → nil)은 그 뒤 비동기로 돈다.
# hitch·Time Profiler(`in_window`)와 CPU Profiler(`xcprof_range`)가 이 여유를 똑같이 쓴다.
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


# 접근성 부하를 좁게 나눈다(p7 분석). 넓은 `main_accessibility_ms`는 UIKit의 일반 `accessibility*` 속성 조회까지
# 세어 실제 부하보다 크게 나왔다 — 이전 수치와 잇기 위해 그대로 두고 아래 세 값을 따로 낸다.
#   ax_mode_ms   : 접근성 모드가 켜져 있어 도는 일(AXRuntime·UIAccessibility·SwiftUI 접근성 그래프), XCTest 조회 제외
#   xct_query_ms : XCUITest 러너의 조회(XCTAutomationSupport)
#   mtc_ms       : Main Thread Checker(libMainThreadChecker.dylib)
SWIFTUI_AX = re.compile(r"Accessibility(ViewGraph|Attachment|Properties|Node|Core|ButtonModifier|ToggleModifier)"
                        r"|applyAccessibility|automationElements|_UIAXBroadcast")


def harness_load(frames):
    """메인 스레드 표본 한 개의 하네스 부하 분류 → (ax_mode, xct_query, mtc)."""
    xct = any(binary == "XCTAutomationSupport" for _, binary in frames)
    ax = any(binary in ("AXRuntime", "UIAccessibility") or SWIFTUI_AX.search(name) or "_accessibility" in name
             for name, binary in frames)
    mtc = any(binary == "libMainThreadChecker.dylib" for _, binary in frames)
    return ax and not xct, xct, mtc


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
        **harness_summary(main),
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


def harness_summary(main):
    totals = [0, 0, 0]
    for _, _, _, weight, frames in main:
        for index, hit in enumerate(harness_load(frames)):
            totals[index] += weight if hit else 0
    return {key: round(total / 1e6, 1) for key, total in zip(("ax_mode_ms", "xct_query_ms", "mtc_ms"), totals)}


def footprint_summary(rows, app):
    values = [number(r.get("memory-physical-footprint")) for r in rows if label(r.get("process")).startswith(app)]
    values = [v for v in values if v is not None]
    return {"samples": len(values), "peak_footprint_mib": round(max(values) / 2**20, 1) if values else None,
            "min_footprint_mib": round(min(values) / 2**20, 1) if values else None}


def signpost_summary(rows, name):
    durations = [number(r.get("duration")) for r in rows if label(r.get("name")) == name]
    durations = [d for d in durations if d is not None]
    return {"name": name, "count": len(durations), "total_ms": round(sum(durations) / 1e6, 2)}


def signpost_window(rows, name, app):
    """`name` os_signpost 구간 → (시작 ms, 끝 ms, 개수). 트레이스 시각(ns, 녹화 시작 기준) 그대로다.
    여러 번이면 첫 구간을 쓴다(데모는 스트림당 하나)."""
    spans = sorted(
        (number(r.get("start")), number(r.get("duration"))) for r in rows
        if label(r.get("name")) == name and label(r.get("process")).startswith(app)
        and number(r.get("start")) is not None and number(r.get("duration")) is not None
    )
    if not spans:
        return None
    start, duration = spans[0]
    return start / 1e6, (start + duration) / 1e6, len(spans)


def stream_window(signpost_rows, name, app, fallback):
    """signpost 창 → (창, 출처). 구간이 없으면 UI 로그 창(`fallback`)으로 대신한다."""
    found = signpost_window(signpost_rows, name, app) if name else None
    if found:
        return found[:2], "signpost"
    return fallback, ("ui-log" if fallback else None)


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


def trace_windows(trace, app, ui_log, window_name, window_signpost):
    """(TOC 스키마, 녹화 시작 epoch, UI 로그 창, (signpost 창, 출처), os-signpost-interval 행)."""
    trace_start, schemas = toc_info(trace)
    window = window_from_log(ui_log, window_name, trace_start) if ui_log and window_name else None
    rows = export(trace, "os-signpost-interval") if "os-signpost-interval" in schemas else []
    stream = stream_window(rows, window_signpost, app, window) if window_signpost else (None, None)
    return schemas, window, stream, rows


def summarize(trace, app, ui_log, window_name, frame_queries, signpost, window_signpost):
    schemas, window, (stream, stream_source), signpost_rows = trace_windows(trace, app, ui_log, window_name,
                                                                            window_signpost)
    duration = re.search(r"<duration>([\d.]+)</duration>", xctrace("export", "--input", trace, "--toc"))
    duration_s = float(duration.group(1)) if duration else None
    result = {"trace": trace, "window": window_name, "window_ms": [round(v) for v in window] if window else None,
              "duration_s": duration_s}
    if window_signpost:
        result["window_stream"] = {"signpost": window_signpost, "source": stream_source,
                                   "ms": [round(v) for v in stream] if stream else None}
    if "hitches" in schemas:
        rows = export(trace, "hitches")
        result["hitches"] = hitch_summary(rows, app, window, duration_s)
        if stream:
            result["hitches_stream"] = hitch_summary(rows, app, stream, duration_s)
    if "time-profile" in schemas:
        xml_text = xctrace("export", "--input", trace, "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]')
        samples = resolve_stacks(xml_text)
        result["profile"] = profile_summary(samples, app, window, frame_queries)
        if stream:
            result["profile_stream"] = profile_summary(samples, app, stream, frame_queries)
    if "activity-monitor-process-live" in schemas:
        result["memory"] = footprint_summary(export(trace, "activity-monitor-process-live"), app)
    if signpost and signpost_rows:
        result["signpost"] = signpost_summary(signpost_rows, signpost)
    return result


def xcprof_range(window):
    """xcprof analyze 범위. `in_window`와 같은 여유를 붙여 CPU Profiler·hitch·Time Profiler가 같은 창을 본다."""
    if not window:
        return ""
    return f"--start-ms {max(0, round(window[0] - WINDOW_SLACK_MS))} --end-ms {round(window[1] + WINDOW_SLACK_MS)}"


def report(directory, top=3):
    """한 기기 폴더의 *.summary.json·*.xcprof.json을 시나리오 표(Markdown)로 묶는다.
    `stream` 열은 signpost 창(`hitches_stream`)이다 — 자동 재생 시나리오는 이 열이 본 수치다
    (UI 로그 창이 없어 기존 열은 트레이스 전체). CPU 열은 `<시나리오>.cpu.<창>.xcprof.json`이다."""
    import glob
    import os
    rows = ["| 시나리오 | 창 s | hitch 수 | 합계 ms | 최대 ms | ms/s | stream 창 s | stream hitch 수 | stream ms/s | 메인 스레드 ms (접근성) | 메인 스레드 앱 프레임 (TP incl. ms) | CPU Profiler 라이브러리 프레임 (xcprof, 앱 CPU 표본 중 incl. %) | 최대 footprint MiB |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|"]
    for path in sorted(glob.glob(os.path.join(directory, "*.hitches.*.summary.json"))):
        summary = json.load(open(path))
        # 창 이름은 analyze가 쓴 파일 이름(`<시나리오>.hitches.<창>.summary.json`)에서 얻는다. 자동 재생은
        # `--window` 없이 요약해 summary["window"]가 null이지만 CPU·메모리 파일은 같은 창 이름으로 쓰인다.
        scenario, window = os.path.basename(path)[:-len(".summary.json")].split(".hitches.", 1)
        hitches, stream = summary.get("hitches", {}), summary.get("hitches_stream", {})
        # UI 로그 창이 없는 자동 재생 시나리오는 메인 스레드 열도 signpost 창으로 읽는다(전체 트레이스엔 런치가 섞인다).
        profile = summary.get("profile_stream" if summary.get("window_ms") is None and "profile_stream" in summary
                              else "profile", {})
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
                    f"{stream.get('window_s', '-')} | {stream.get('count', '-')} | {stream.get('ratio_ms_per_s', '-')} | "
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
    hitch_rows = parse_table(xml_text)
    summary = hitch_summary(hitch_rows, "App", (500, 5000), 10)
    assert summary["count"] == 2 and summary["total_ms"] == 25.0 and summary["max_ms"] == 16.7, summary
    assert summary["ratio_ms_per_s"] == round(25.0 / 4.5, 2)

    # os-signpost-interval 열 구성은 Instruments 문서(Narrative.instrdst fulldoc)의 schema 그대로다.
    # 표 두 개(os_signpost·Points of Interest)에 나뉘어도 찾고, 다른 이름·다른 프로세스 구간은 고르지 않는다.
    signpost_xml = """<?xml version="1.0"?><trace-query-result><node><schema name="os-signpost-interval">
    <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>layout-qualifier</mnemonic></col>
    <col><mnemonic>name</mnemonic></col><col><mnemonic>category</mnemonic></col><col><mnemonic>subsystem</mnemonic></col>
    <col><mnemonic>identifier</mnemonic></col><col><mnemonic>process</mnemonic></col></schema>
    <row><start-time id="1" fmt="00:00.200">200000000</start-time><duration id="2" fmt="9 s">9000000000</duration><layout-id id="3" fmt="0">0</layout-id>
    <string id="4" fmt="parse">parse</string><category id="5" fmt="parse">parse</category><subsystem id="6" fmt="dev.richmarkdown">dev.richmarkdown</subsystem>
    <os-signpost-identifier id="7" fmt="1">1</os-signpost-identifier><process id="8" fmt="App (1)"/></row>
    <row><start-time id="9" fmt="00:01.000">1000000000</start-time><duration ref="2"/><layout-id ref="3"/>
    <string id="10" fmt="sse-stream">sse-stream</string><category id="11" fmt="PointsOfInterest">PointsOfInterest</category>
    <subsystem id="12" fmt="dev.richmarkdown.demo">dev.richmarkdown.demo</subsystem><os-signpost-identifier ref="7"/><process id="13" fmt="Other (2)"/></row>
    </node><node><schema name="os-signpost-interval">
    <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>name</mnemonic></col><col><mnemonic>process</mnemonic></col></schema>
    <row><start-time id="20" fmt="00:01.500">1500000000</start-time><duration id="21" fmt="2 s">2000000000</duration>
    <string id="22">sse-stream</string><process id="23" fmt="App (1)"/></row>
    </node></trace-query-result>"""
    signpost_rows = parse_table(signpost_xml)
    assert len(signpost_rows) == 3, signpost_rows
    assert signpost_window(signpost_rows, "sse-stream", "App") == (1500.0, 3500.0, 1)
    stream, source = stream_window(signpost_rows, "sse-stream", "App", (500, 5000))
    assert (stream, source) == ((1500.0, 3500.0), "signpost")
    # 1.0 s hitch는 창 시작 300 ms 여유 밖, 2.0 s만 들어온다. 분모는 signpost 길이(2 s)다.
    streamed = hitch_summary(hitch_rows, "App", stream, 10)
    assert streamed["count"] == 1 and streamed["total_ms"] == 16.7 and streamed["ratio_ms_per_s"] == 8.33, streamed
    assert stream_window([], "sse-stream", "App", (500, 5000)) == ((500, 5000), "ui-log")
    assert stream_window([], "sse-stream", "App", None) == (None, None)
    # CPU Profiler 창도 hitch·Time Profiler와 같은 여유를 붙인다 — signpost 끝 뒤의 최종 렌더가 세 지표 모두에 든다.
    assert xcprof_range(stream) == "--start-ms 1200 --end-ms 3800" and xcprof_range(None) == ""
    assert xcprof_range((100, 900)) == "--start-ms 0 --end-ms 1200"

    # --report: 자동 재생 요약은 window가 null이다. 행 이름·CPU·메모리 파일은 analyze가 쓴 파일 이름의 창으로 찾는다.
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        def write(name, payload):
            with open(os.path.join(directory, name), "w") as handle:
                json.dump(payload, handle)
        write("sse-long-uikit-auto.hitches.sse-long-uikit-auto.summary.json",
              {"window": None, "window_ms": None, "hitches": {"count": 9}, "hitches_stream": {"count": 4},
               "profile_stream": {"main_thread_ms": 120}})
        write("sse-long-uikit-auto.cpu.sse-long-uikit-auto.xcprof.json",
              {"user_frames": [{"name": "RichMarkdownUIView.rebuild()", "inclusive_pct": 12.5}]})
        write("sse-long-uikit-auto.memory.sse-long-uikit-auto.summary.json", {"memory": {"peak_footprint_mib": 88.1}})
        write("cold-launch-chat.hitches.cold-launch-chat.launch.summary.json",
              {"window": "cold-launch-chat.launch", "window_ms": [0, 900], "hitches": {"count": 1}})
        table = report(directory).splitlines()
    assert table[2].startswith("| cold-launch-chat.launch | "), table[2]
    auto = table[3]
    assert auto.startswith("| sse-long-uikit-auto | ") and "| 120 (-) |" in auto, auto
    assert "RichMarkdownUIView.rebuild() 12.5%" in auto and auto.endswith("| 88.1 |"), auto

    # 하네스 부하 분류: XCTest 조회 스택은 ax_mode에서 빼고, 일반 UIKit accessibility 속성 조회는 세지 않는다.
    main = [
        (0, "Main Thread", "App", 1_000_000, [("-[UIView _accessibilityUserTestingChildren]", "UIAccessibility"),
                                              ("XCTRunnerDaemon query", "XCTAutomationSupport")]),
        (0, "Main Thread", "App", 2_000_000, [("AccessibilityNode.update", "SwiftUI")]),
        (0, "Main Thread", "App", 4_000_000, [("-[UIView accessibilityIdentifier]", "UIKitCore")]),
        (0, "Main Thread", "App", 8_000_000, [("__main_thread_checker_on_report", "libMainThreadChecker.dylib")]),
    ]
    assert harness_summary(main) == {"ax_mode_ms": 2.0, "xct_query_ms": 1.0, "mtc_ms": 8.0}, harness_summary(main)
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace", nargs="?")
    parser.add_argument("--app", default="RichMarkdownDemo")
    parser.add_argument("--ui-log")
    parser.add_argument("--window")
    parser.add_argument("--frame", action="append", default=[])
    parser.add_argument("--signpost")
    parser.add_argument("--window-signpost", metavar="NAME",
                        help="os_signpost 구간(예: sse-stream)을 두 번째 창으로 쓴다. 없으면 UI 로그 창으로 대신한다")
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
        # signpost 창이 있으면 그쪽, 없으면 UI 로그 창이다.
        _, window, (stream, _), _ = trace_windows(args.trace, args.app, args.ui_log, args.window, args.window_signpost)
        print(xcprof_range(stream or window))
        return
    json.dump(summarize(args.trace, args.app, args.ui_log, args.window, args.frame, args.signpost,
                        args.window_signpost),
              sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
