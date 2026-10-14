#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""검증 보고서 수치의 단일 출처를 만든다: 원시 결과(벤치마크 JSON·xccov·Kover·lizard·fixture manifest·
결함 대장)를 읽어 `<out>/*.csv`로 쓴다. `charts.py`가 이 CSV만 읽어 그래프를 그린다.

    python3 scripts/report/collect.py --ios-raw <iOS 빌드 폴더> --android-raw <Android 빌드 폴더> \
        --ios-coverage <xccov JSON> --android-build <Android 빌드 루트> --out <data 폴더>

원시 파일이 없으면 해당 CSV를 건너뛰고 표준 오류에 적는다(부분 실행 허용).
"""
from __future__ import annotations

import argparse
import csv
import glob
import importlib.util
import json
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CLOCK = "com.apple.dt.XCTMetric_Clock.time.monotonic"
IOS_ENV = "iPad Pro 11 (M5) · iPadOS 26.6.2 · Release"
ANDROID_ENV = "Galaxy S20 Ultra (SM-G988N) · Android 13 · release"


def write_csv(out: Path, name: str, header: list[str], rows: list[list]) -> None:
    with (out / f"{name}.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)
    print(f"{name}.csv {len(rows)} rows")


def skip(name: str, reason: str) -> None:
    print(f"skip {name}: {reason}", file=sys.stderr)


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------- 성능

def ios_micro(ios: Path) -> dict[tuple[str, str], dict]:
    path = ios / "p2/ios/ipad-pro-m5/micro/results.json"
    return {(b["name"], b["metric"]): b for b in load_json(path)["benchmarks"]} if path.exists() else {}


def android_micro(android: Path) -> dict[str, dict]:
    # 실행마다 `p2/micro/<시각>/`에 쌓인다. 가장 최근 결과를 쓴다(이름순이 아니라 수정 시각순).
    files = sorted(glob.glob(str(android / "p2/micro/**/*benchmarkData.json"), recursive=True), key=lambda f: Path(f).stat().st_mtime)
    return {b["name"]: b for b in load_json(Path(files[-1]))["benchmarks"]} if files else {}


def android_macro(android: Path) -> list[dict]:
    """실행 시각 순서. 같은 이름은 뒤 실행이 앞 실행을 덮는다."""
    benches: dict[str, dict] = {}
    for path in sorted(glob.glob(str(android / "p2/macro/*/benchmark/connected/*/*benchmarkData.json"))):
        for bench in load_json(Path(path))["benchmarks"]:
            benches[bench["name"]] = bench
    return list(benches.values())


def parse_latency(ios: Path, android: Path, out: Path) -> None:
    sizes = {1: ("core.parse.1KiB.dollarOff", "parse_1k"), 10: ("core.parse.10KiB.dollarOff", "parse_10k"),
             50: ("core.parse.50KiB.dollarOff", "parse_50k"), 256: ("core.parse.256KiB.dollarOff", "parse_256k")}
    micro_ios, micro_android = ios_micro(ios), android_micro(android)
    rows = []
    for size, (ios_name, android_name) in sizes.items():
        for value in micro_ios.get((ios_name, CLOCK), {}).get("values", []):
            rows.append(["iOS", IOS_ENV, size, round(value, 4)])
        for ns in micro_android.get(android_name, {}).get("metrics", {}).get("timeNs", {}).get("runs", []):
            rows.append(["Android", ANDROID_ENV, size, round(ns / 1e6, 4)])
    if rows:
        write_csv(out, "parse_latency", ["platform", "environment", "size_kib", "ms"], rows)
    else:
        skip("parse_latency", "벤치마크 결과 없음")


def micro_summary(ios: Path, android: Path, out: Path) -> None:
    """두 플랫폼에 같은 입력으로 있는 Core 항목의 중앙값."""
    pairs = [("파싱 1 KiB", "core.parse.1KiB.dollarOff", "parse_1k"),
             ("파싱 10 KiB", "core.parse.10KiB.dollarOff", "parse_10k"),
             ("파싱 50 KiB", "core.parse.50KiB.dollarOff", "parse_50k"),
             ("파싱 256 KiB", "core.parse.256KiB.dollarOff", "parse_256k"),
             ("MathScanner 50 KiB", "core.mathScanner.50KiB", "mathScanner_50k"),
             ("수식 보호·복원 50 KiB", "core.protectRestore.50KiB", "protectRestore_50k")]
    micro_ios, micro_android = ios_micro(ios), android_micro(android)
    rows = []
    for label, ios_name, android_name in pairs:
        ios_bench = micro_ios.get((ios_name, CLOCK))
        android_time = micro_android.get(android_name, {}).get("metrics", {}).get("timeNs")
        rows.append([label,
                     round(ios_bench["median"], 4) if ios_bench else "",
                     round(ios_bench["p90"], 4) if ios_bench else "",
                     round(android_time["median"] / 1e6, 4) if android_time else "",
                     round(android_time["minimum"] / 1e6, 4) if android_time else ""])
    write_csv(out, "micro_summary", ["item", "ios_median_ms", "ios_p90_ms", "android_median_ms", "android_min_ms"], rows)


IOS_SCENARIOS = [("chat-scroll-swiftui", "chat-scroll-swiftui", "챗 스크롤", "SwiftUI"),
                 ("chat-scroll-uikit", "chat-scroll-uikit", "챗 스크롤", "UIKit"),
                 ("sse-swiftui", "sse-swiftui", "SSE 20 Hz", "SwiftUI"),
                 ("sse-uikit", "sse-uikit", "SSE 20 Hz", "UIKit"),
                 ("cold-launch-chat", "cold-launch-chat.launch", "콜드 런치", "SwiftUI"),
                 ("cold-launch-chat", "cold-launch-chat.entry", "챗 첫 진입", "SwiftUI"),
                 ("mermaid-entry", "mermaid-entry", "Mermaid 진입", "SwiftUI")]


def ios_hitches(ios: Path, out: Path) -> None:
    """시나리오별 hitch 시간 비율. 기기 폴더와 반복 측정 하위 폴더(`rep*/`)의 요약을 모아 실행별 값의 중앙값·최소·최대를 쓴다.
    hitch 수·합·최대·구간 길이는 중앙값에 가장 가까운 실행의 값이다."""
    root = ios / "p2/ios/ipad-pro-m5"
    run_dirs = [root] + sorted(path for path in root.glob("rep*") if path.is_dir())
    rows = []
    for base, window, scenario, renderer in IOS_SCENARIOS:
        runs = []
        for run_dir in run_dirs:
            path = run_dir / f"{base}.hitches.{window}.summary.json"
            if not path.exists():
                continue
            summary = load_json(path)
            durations = summary.get("hitches", {}).get("durations_ms", [])
            seconds = (summary["window_ms"][1] - summary["window_ms"][0]) / 1000
            if seconds:
                runs.append((sum(durations) / seconds, durations, seconds))
        if not runs:
            continue
        rates = [rate for rate, _, _ in runs]
        median = statistics.median(rates)
        _, durations, seconds = min(runs, key=lambda run: abs(run[0] - median))
        rows.append([scenario, renderer, len(durations), round(sum(durations), 1),
                     round(max(durations), 1) if durations else 0, round(seconds, 2),
                     round(median, 2), len(runs), round(min(rates), 2), round(max(rates), 2)])
    if rows:
        write_csv(out, "ios_hitches", ["scenario", "renderer", "hitch_count", "hitch_total_ms", "hitch_max_ms",
                                       "window_s", "hitch_ms_per_s", "runs", "hitch_min_ms_per_s", "hitch_max_ms_per_s"], rows)
    else:
        skip("ios_hitches", "요약 JSON 없음")


def android_frames(android: Path, out: Path) -> None:
    """Macrobenchmark SSE(frameDurationCpuMs)와 gfxinfo 스크롤 백분위. 지표가 달라 지표 이름을 함께 쓴다."""
    rows = []
    for bench in android_macro(android):
        if bench["name"] == "sse_streaming":
            metric = bench["sampledMetrics"]["frameDurationCpuMs"]
            rows.append(["SSE 20 Hz (Compose)", "Macrobenchmark frameDurationCpuMs",
                         round(metric["P50"], 2), round(metric["P90"], 2), round(metric["P95"], 2), round(metric["P99"], 2)])
    results = android / "p2/android-results.md"
    if results.exists():
        pattern = re.compile(r"\| (ViewChatActivity|ComposeChatActivity) \|[^|]+\| (\d+) ms \| (\d+) ms \| (\d+) ms \| (\d+) ms \|")
        for line in results.read_text(encoding="utf-8").splitlines():
            match = pattern.match(line)
            if match:
                name = "챗 스크롤 (View)" if match.group(1).startswith("View") else "챗 스크롤 (Compose)"
                rows.append([name, "gfxinfo 총 프레임 시간"] + [int(match.group(i)) for i in range(2, 6)])
    if rows:
        write_csv(out, "android_frames", ["scenario", "metric", "p50_ms", "p90_ms", "p95_ms", "p99_ms"], rows)
    else:
        skip("android_frames", "결과 없음")


def memory_timeline(ios: Path, out: Path) -> None:
    path = ios / "p2/ios/ipad-pro-m5/sse-memory-timeline.json"
    if not path.exists():
        skip("memory_timeline", "sse-memory-timeline.json 없음")
        return
    data = load_json(path)
    rows = []
    for key, renderer in [("sse-swiftui", "SwiftUI"), ("sse-uikit", "UIKit")]:
        entry = data.get(key, {})
        start, end = entry.get("window_ms", [0, 0])
        for seconds, mib in entry.get("points_s_mib", []):
            rows.append([renderer, seconds, mib, round(start / 1000, 3), round(end / 1000, 3)])
    write_csv(out, "memory_timeline", ["renderer", "t_s", "footprint_mib", "stream_start_s", "stream_end_s"], rows)


def launch(ios: Path, android: Path, out: Path) -> None:
    rows = []
    for path in sorted((ios / "p2/ios/ipad-pro-m5").glob("launch-metrics-*.json")):
        for bench in load_json(path)["benchmarks"]:
            if "testColdLaunch" in bench["name"] and "AppLaunch" in bench["metric"]:
                rows += [["iOS 콜드", "XCTApplicationLaunchMetric", round(v, 2)] for v in bench["values"]]
    names = {"startup_cold_none": "Android 콜드 · 컴파일 없음", "startup_cold_partial": "Android 콜드 · 부분 컴파일",
             "startup_warm_none": "Android 웜 · 컴파일 없음", "startup_warm_partial": "Android 웜 · 부분 컴파일"}
    for bench in android_macro(android):
        ttid = bench.get("metrics", {}).get("timeToInitialDisplayMs")
        if bench["name"] in names and ttid:
            rows += [[names[bench["name"]], "StartupTimingMetric TTID", round(v, 2)] for v in ttid["runs"]]
    if rows:
        write_csv(out, "launch", ["case", "metric", "ms"], rows)
    else:
        skip("launch", "결과 없음")


def app_size(ios: Path, android: Path, out: Path) -> None:
    rows = []
    linkmap = ios / "p2/ios/size/linkmap-summary.json"
    if linkmap.exists():
        names = {"Demo app": "데모 앱 코드 (라이브러리 아님)", "other": "기타"}
        for module in load_json(linkmap)["modules"]:
            rows.append(["iOS 데모 실행 파일 · arm64 (링크 맵 기준)", names.get(module["module"], module["module"]),
                         round(module["bytes"] / 1024, 1)])
    sizes = android / "p2/sizes.json"
    if sizes.exists():
        data = load_json(sizes)
        for module in data.get("modules", []):
            rows.append(["Android 산출물 · 라이브러리와 의존성 네이티브(arm64-v8a)", module["artifact"],
                         round(module["bytes"] / 1024, 1)])
        for lib in data.get("demoApk", {}).get("nativeLibs", []):
            if lib["path"].startswith("lib/arm64-v8a/") and "graphics.path" not in lib["path"]:
                name = Path(lib["path"]).name
                rows.append(["Android 산출물 · 라이브러리와 의존성 네이티브(arm64-v8a)", f"{name} (의존성)",
                             round(lib["bytes"] / 1024, 1)])
    if rows:
        write_csv(out, "app_size", ["group", "item", "kib"], rows)
    else:
        skip("app_size", "결과 없음")


# ---------------------------------------------------------------- 품질

IOS_TARGETS = ["RichMarkdownCore", "RichMarkdown", "RichMarkdownBlockEditor", "RichMarkdownHighlight", "RichMarkdownMermaid"]


ANDROID_MODULES = ["richmarkdown-core", "richmarkdown", "richmarkdown-highlight", "richmarkdown-mermaid", "richmarkdown-editor"]


def jacoco_lines(path: Path) -> dict[tuple[str, str, int], bool]:
    """JaCoCo 형식 XML(Kover XML도 같은 형식)의 줄별 실행 여부."""
    lines: dict[tuple[str, str, int], bool] = {}
    if not path.exists():
        return lines
    # 입력은 이 Mac의 Gradle·Kover·AGP가 만든 로컬 보고서뿐이다(외부·사용자 입력 아님). 표준 expat은 외부 엔티티를 풀지 않는다.
    for package in ET.parse(path).getroot().iter("package"):  # nosemgrep: python.lang.security.use-defused-xml-parse.use-defused-xml-parse
        for source in package.findall("sourcefile"):
            for line in source.findall("line"):
                key = (package.get("name"), source.get("name"), int(line.get("nr")))
                lines[key] = lines.get(key, False) or int(line.get("ci")) > 0
    return lines


def coverage(ios_coverage: Path | None, android_build: Path | None, out: Path) -> None:
    rows = []
    if ios_coverage and ios_coverage.exists():
        # 같은 소스가 여러 테스트 번들에 정적 링크되므로 CI 게이트와 같은 집계(파일별 최대값)를 쓴다.
        spec = importlib.util.spec_from_file_location("coverage_gate", REPO / "scripts/coverage-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        modules = gate.per_module(load_json(ios_coverage))
        for name in IOS_TARGETS:
            if name in modules:
                covered, executable = modules[name]
                rows.append(["iOS", name, covered, executable, round(covered * 100 / executable, 1), "xccov"])
    if android_build:
        # JVM 단위 테스트(Kover)와 계측 테스트(AGP JaCoCo)를 줄 단위로 합친다. 어느 한쪽에서라도 실행된 줄이면 커버.
        for module in ANDROID_MODULES:
            unit = jacoco_lines(android_build / module / "reports/kover/report.xml")
            instrumented = jacoco_lines(android_build / module / "reports/coverage/androidTest/debug/connected/report.xml")
            keys = set(unit) | set(instrumented)
            if not keys:
                skip("coverage", f"{module} 보고서 없음")
                continue
            covered = sum(1 for key in keys if unit.get(key) or instrumented.get(key))
            source = "Kover + JaCoCo(계측)" if instrumented else "Kover"
            rows.append(["Android", module, covered, len(keys), round(covered * 100 / len(keys), 1), source])
    if rows:
        write_csv(out, "coverage", ["platform", "module", "covered_lines", "executable_lines", "line_pct", "source"], rows)
    else:
        skip("coverage", "커버리지 결과 없음")


def complexity(ios: Path, out: Path) -> None:
    """lizard --csv 열: NLOC, CCN, token, PARAM, length, location, file, function, long_name, start, end."""
    rows = []
    for platform, name in [("iOS", "lizard-ios.csv"), ("Android", "lizard-android.csv")]:
        path = ios / "p3/final" / name if (ios / "p3/final" / name).exists() else ios / "p3" / name
        if not path.exists():
            continue
        with path.open(encoding="utf-8") as handle:
            for record in csv.reader(handle):
                is_test = "/Tests/" in record[6] or "/src/test/" in record[6] or "/src/androidTest/" in record[6]
                if len(record) >= 8 and record[1].isdigit() and not is_test:
                    rows.append([platform, int(record[1]), int(record[0]), Path(record[6]).name, record[7]])
    if rows:
        write_csv(out, "complexity", ["platform", "ccn", "nloc", "file", "function"], rows)
    else:
        skip("complexity", "lizard 결과 없음")


def fixtures(out: Path) -> None:
    manifest = REPO / "Tests/Fixtures/manifest.json"
    if not manifest.exists():
        skip("fixtures", "manifest 없음")
        return
    counts: dict[str, int] = {}
    for entry in load_json(manifest)["files"]:
        path = entry["path"]
        if not path.endswith((".md", ".gen.json", ".mmd")) or path.startswith("commonmark/") or path.endswith("README.md"):
            continue
        parts = path.split("/")
        category = "security/mermaid" if path.startswith("security/mermaid/") else parts[0]
        counts[category] = counts.get(category, 0) + 1
    rows = [[k, v] for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]
    rows.append(["commonmark", 652])
    write_csv(out, "fixtures", ["category", "inputs"], rows)


def public_text(text: str) -> str:
    """대장 문구에서 내부 작업 경로 표기(`p1/…`·`Android p3/…`·`slot-…`)를 지운다(공개 사본·부록용)."""
    text = re.sub(r"\(`?(?:Android )?(?:p\d|slot-|baseline-)[^)]*\)", "", text)
    text = re.sub(r"`(?:Android )?(?:p\d|slot-)[^`]*`", "", text)
    return re.sub(r"\s{2,}", " ", text).strip()


def defects(ios: Path, out: Path) -> None:
    ledger = ios / "p1/findings.md"
    if not ledger.exists():
        skip("defects", "결함 대장 없음")
        return
    rows, full = [], []
    order = {k: i for i, k in enumerate("FERSPMTD")}
    for line in ledger.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 7 and re.fullmatch(r"[A-Z]-\d{2}", cells[0]):
            rows.append([cells[0], cells[1], cells[2], cells[6]])
            full.append([cells[0], cells[1], cells[2], public_text(cells[4] + " → " + cells[5]), public_text(cells[6])])
    full.sort(key=lambda r: (order.get(r[0][0], 9), r[0]))
    write_csv(out, "defects", ["id", "kind", "target", "status"], rows)
    write_csv(out, "defects_full", ["id", "kind", "target", "content", "status"], full)


def parity(parity_dir: Path | None, out: Path) -> None:
    """고정 fixture 패리티(fixtures-parity.py)와 퍼즈 잔여 분류(fuzz-residual.py) 결과."""
    if not parity_dir or not (parity_dir / "parity.json").exists():
        skip("parity", "parity.json 없음")
        return
    counts = load_json(parity_dir / "parity.json")["counts"]
    total = sum(counts.values())
    rows = [["고정 fixture", total, counts.get("match", 0), counts.get("exception", 0), 0,
             total - counts.get("match", 0) - counts.get("exception", 0)]]
    for name, label in [("residual-10k.json", "퍼즈 1만 건"), ("residual-100k.json", "퍼즈 10만 건")]:
        path = parity_dir / name
        if path.exists():
            data = load_json(path)
            other = data["counts"].get("기타", 0) + data["counts"].get("입력 불일치", 0)
            upstream = sum(v for k, v in data["counts"].items() if k not in ("기타", "입력 불일치"))
            rows.append([label, data["compared"], data["sameDoc"], 0, upstream, other])
    write_csv(out, "parity", ["set", "total", "match", "approved", "upstream", "unresolved"], rows)


def pathological(patho_csv: Path | None, out: Path) -> None:
    if not patho_csv or not patho_csv.exists():
        skip("pathological", "측정 CSV 없음")
        return
    with patho_csv.open(encoding="utf-8") as handle:
        data = list(csv.DictReader(handle))
    write_csv(out, "pathological", list(data[0].keys()), [list(r.values()) for r in data])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ios-raw", type=Path, required=True)
    parser.add_argument("--android-raw", type=Path, required=True)
    parser.add_argument("--ios-coverage", type=Path, help="xccov view --report --json 결과")
    parser.add_argument("--android-build", type=Path, help="Android 빌드 루트(-Prichmarkdown.buildRoot). 모듈별 Kover·JaCoCo XML을 읽는다")
    parser.add_argument("--parity-dir", type=Path, help="parity.json·residual-*.json이 있는 폴더")
    parser.add_argument("--patho-csv", type=Path, help="병리 입력 전후 측정 CSV")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    parse_latency(args.ios_raw, args.android_raw, args.out)
    micro_summary(args.ios_raw, args.android_raw, args.out)
    ios_hitches(args.ios_raw, args.out)
    android_frames(args.android_raw, args.out)
    memory_timeline(args.ios_raw, args.out)
    launch(args.ios_raw, args.android_raw, args.out)
    app_size(args.ios_raw, args.android_raw, args.out)
    coverage(args.ios_coverage, args.android_build, args.out)
    complexity(args.ios_raw, args.out)
    fixtures(args.out)
    defects(args.ios_raw, args.out)
    parity(args.parity_dir, args.out)
    pathological(args.patho_csv, args.out)


if __name__ == "__main__":
    main()
