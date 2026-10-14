#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""BENCH 줄을 모아 metric별 통계(median·p90·min·max·stdev)를 results.json으로 쓴다.

입력은 xcodebuild 로그(텍스트) 또는 .xcresult. xcresult는 `xcresulttool get log --type action`의
테스트 출력에서 BENCH 줄을 읽고, 없으면 `get test-results metrics`의 측정값으로 대신한다.
단위 변환: ns → ms, byte → kB(1000 byte, XCTest 표시와 같음).

  scripts/bench/collect.py <log|xcresult>... --label "iPhone 16 Pro" --out results.json [--table]
  scripts/bench/collect.py --self-test
"""
import argparse
import json
import re
import statistics
import subprocess
import sys

BENCH_RE = re.compile(r"^(BENCH|BENCH_INPUT|BENCH_ENV|BENCH_EVIDENCE) (\{.*\})\s*$")
UNIT_SCALE = {"ns": ("ms", 1e-6), "byte": ("kB", 1e-3)}
# metrics fallback(xcresult 표시 단위)을 BENCH 기본 단위로 되돌린다.
DISPLAY_TO_BASE = {"s": ("ns", 1e9), "kB": ("byte", 1e3), "kI": ("I", 1e3), "kC": ("C", 1e3)}


def bench_lines(text):
    for line in text.splitlines():
        match = BENCH_RE.match(line.strip())
        if match:
            yield match.group(1), json.loads(match.group(2))


def strings_in(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from strings_in(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings_in(value)


def xcresulttool(*args):
    return subprocess.run(["xcrun", "xcresulttool", *args], capture_output=True, text=True, check=False).stdout


def read_xcresult(path):
    action = xcresulttool("get", "log", "--type", "action", "--compact", "--path", path)
    text = "\n".join(strings_in(json.loads(action))) if action.strip().startswith(("{", "[")) else ""
    found = list(bench_lines(text))
    if any(tag == "BENCH" for tag, _ in found):
        return found
    return found + list(metrics_fallback(path))


def metrics_fallback(path):
    raw = xcresulttool("get", "test-results", "metrics", "--compact", "--path", path)
    for test in json.loads(raw or "[]"):
        name = "xcresult:" + test["testIdentifier"]
        for run in test.get("testRuns", []):
            for metric in run.get("metrics", []):
                unit, scale = DISPLAY_TO_BASE.get(metric["unitOfMeasurement"], (metric["unitOfMeasurement"], 1))
                yield "BENCH", {
                    "name": name,
                    "metric": metric["identifier"],
                    "label": metric["displayName"],
                    "unit": unit,
                    "values": [value * scale for value in metric["measurements"]],
                }


def summarize(entry):
    unit, scale = UNIT_SCALE.get(entry["unit"], (entry["unit"], 1))
    values = [value * scale for value in entry["values"]]
    summary = {
        "name": entry["name"],
        "metric": entry["metric"],
        "label": entry.get("label", ""),
        "unit": unit,
        "n": len(values),
        "median": statistics.median(values),
        "p90": statistics.quantiles(values, n=10, method="inclusive")[8] if len(values) > 1 else values[0],
        "min": min(values),
        "max": max(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "values": values,
    }
    if "warmup" in entry:
        summary["warmup"] = entry["warmup"] * scale
    return summary


def collect(paths):
    entries, inputs, extras = {}, {}, {"BENCH_ENV": [], "BENCH_EVIDENCE": []}
    for path in paths:
        if path.endswith(".xcresult"):
            found = read_xcresult(path)
        else:
            with open(path, encoding="utf-8", errors="replace") as handle:
                found = list(bench_lines(handle.read()))
        for tag, obj in found:
            # 같은 줄이 로그 표현마다 반복되므로 (name, metric)으로 중복을 없앤다. 뒤의 실행이 이긴다.
            if tag == "BENCH":
                entries[(obj["name"], obj["metric"])] = obj
            elif tag == "BENCH_INPUT":
                inputs[obj["name"]] = obj
            elif obj not in extras[tag]:
                extras[tag].append(obj)
    return [summarize(entry) for entry in entries.values()], list(inputs.values()), extras


def table(benchmarks):
    by_name = {}
    for item in benchmarks:
        by_name.setdefault(item["name"], {})[item["metric"].rsplit(".", 1)[-1]] = item
    rows = ["| 벤치마크 | 시계 중앙값 ms | 시계 p90 ms | CPU 시간 중앙값 ms | 최대 물리 메모리 중앙값 kB |", "|---|---:|---:|---:|---:|"]
    for name, metrics in by_name.items():
        # 런치 테스트처럼 시계 metric이 없으면 첫 ms 단위 metric(예: 앱 런치 시간)을 쓴다.
        clock = metrics.get("monotonic") or next((m for m in metrics.values() if m["unit"] == "ms"), None)
        cpu, peak = metrics.get("time"), metrics.get("physical_peak")
        cell = lambda m, key="median": f"{m[key]:.2f}" if m else "-"
        rows.append(f"| {name} | {cell(clock)} | {cell(clock, 'p90')} | {cell(cpu)} | {cell(peak, 'median') if peak else '-'} |")
    return "\n".join(rows)


def self_test():
    line = 'BENCH {"label":"Clock Monotonic Time","metric":"com.apple.dt.XCTMetric_Clock.time.monotonic","name":"t","unit":"ns","values":[1000000,2000000,3000000,4000000,5000000,6000000,7000000,8000000,9000000,10000000],"warmup":50000000}'
    (tag, obj), = bench_lines("noise\n" + line + "\n")
    result = summarize(obj)
    assert tag == "BENCH" and result["unit"] == "ms" and result["n"] == 10
    assert result["median"] == 5.5 and abs(result["p90"] - 9.1) < 1e-9 and result["warmup"] == 50.0
    assert table([result]).count("| t |") == 1
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="*")
    parser.add_argument("--out")
    parser.add_argument("--label", default="")
    parser.add_argument("--table", action="store_true", help="표준 출력에 Markdown 표를 쓴다")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.inputs:
        parser.error("입력 로그 또는 .xcresult가 필요하다")
    benchmarks, inputs, extras = collect(args.inputs)
    if not benchmarks:
        sys.exit("BENCH 줄을 찾지 못했다")
    result = {"label": args.label, "sources": args.inputs, "inputs": inputs, "benchmarks": benchmarks,
              "environment": extras["BENCH_ENV"], "evidence": extras["BENCH_EVIDENCE"]}
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
    if args.table or not args.out:
        print(table(benchmarks))


if __name__ == "__main__":
    main()
