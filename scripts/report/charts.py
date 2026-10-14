#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""`collect.py`가 만든 CSV만 읽어 검증 보고서 그래프를 PNG로 그린다(흰 바탕, 논문·슬라이드 공용).

    python3 scripts/report/charts.py --data <data 폴더> --out <charts 폴더>

색 규칙(검증된 팔레트, 라이트): iOS 파랑 #2a78d6, Android 주황 #eb6834, SwiftUI 청록 #1baf7a, UIKit 노랑 #eda100.
청록·노랑은 흰 바탕 대비가 낮아 막대·선 옆에 값 라벨을 항상 붙인다. 그림 제목은 넣지 않는다(문서 캡션이 맡는다).
"""
from __future__ import annotations

import argparse
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

IOS, ANDROID, SWIFTUI, UIKIT = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
INK, INK_2, MUTED, GRID = "#1f2328", "#57606a", "#8c959f", "#e5e7eb"
ORANGE_RAMP = ["#f9c9b4", "#f39a74", "#eb6834", "#b4471c"]
WIDTH_IN = 6.4


def setup_style() -> None:
    installed = {entry.name for entry in font_manager.fontManager.ttflist}
    family = next((f for f in ["Apple SD Gothic Neo", "AppleGothic", "Noto Sans CJK KR"] if f in installed), "sans-serif")
    plt.rcParams.update({
        "font.family": family, "font.size": 9, "axes.unicode_minus": False,
        "axes.edgecolor": MUTED, "axes.labelcolor": INK_2, "axes.linewidth": 0.8,
        "xtick.color": INK_2, "ytick.color": INK_2, "xtick.major.width": 0.8, "ytick.major.width": 0.8,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
        "axes.spines.top": False, "axes.spines.right": False,
        "legend.frameon": False, "figure.facecolor": "white", "axes.facecolor": "white",
        "savefig.dpi": 220, "savefig.bbox": "tight", "savefig.pad_inches": 0.08,
    })


def read(data: Path, name: str) -> list[dict]:
    path = data / f"{name}.csv"
    if not path.exists():
        print(f"skip {name}: CSV 없음")
        return []
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def save(fig, out: Path, name: str) -> None:
    fig.savefig(out / f"{name}.png")
    plt.close(fig)
    print(f"{name}.png")


def value_label(ax, x, y, text, **kwargs) -> None:
    ax.annotate(text, (x, y), xytext=(4, 0), textcoords="offset points", va="center",
                fontsize=8, color=kwargs.pop("color", INK), **kwargs)


def bar_axis(ax) -> None:
    """가로 막대: 세로 격자만 남긴다."""
    ax.grid(axis="y", visible=False)


# ---------------------------------------------------------------- 성능

def parse_latency(data: Path, out: Path) -> None:
    rows = read(data, "parse_latency")
    if not rows:
        return
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 3.4))
    for platform, color in [("iOS", IOS), ("Android", ANDROID)]:
        by_size = defaultdict(list)
        for row in rows:
            if row["platform"] == platform:
                by_size[int(row["size_kib"])].append(float(row["ms"]))
        if not by_size:
            continue
        sizes = sorted(by_size)
        for size in sizes:
            ax.scatter([size] * len(by_size[size]), by_size[size], s=10, color=color, alpha=0.35, linewidths=0, zorder=3)
        medians = [statistics.median(by_size[s]) for s in sizes]
        ax.plot(sizes, medians, color=color, linewidth=2, marker="o", markersize=5, zorder=4,
                markeredgecolor="white", markeredgewidth=1)
        device = next(r["environment"] for r in rows if r["platform"] == platform).split(" · ")[0]
        ax.annotate(f"{platform} · {device}\n256 KiB 중앙값 {medians[-1]:.0f} ms", (sizes[-1], medians[-1]),
                    xytext=(10, -14 if platform == "iOS" else 0), textcoords="offset points", va="center",
                    fontsize=8, color=INK)
        for size, median in zip(sizes[:-1], medians[:-1]):
            ax.annotate(f"{median:.1f}" if median < 10 else f"{median:.0f}", (size, median),
                        xytext=(0, 7 if platform == "Android" else -12), textcoords="offset points",
                        ha="center", fontsize=7.5, color=INK_2)
    ax.hlines(50, 0.7, 300, color=MUTED, linewidth=1, linestyle=(0, (4, 3)), zorder=2)
    ax.annotate("20 Hz 갱신 간격 50 ms", (0.8, 50), xytext=(0, 4), textcoords="offset points", fontsize=7.5, color=INK_2)
    ax.set_ylim(0.15, None)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xticks([1, 10, 50, 256], ["1", "10", "50", "256"])
    ax.set_xlim(0.7, 1500)
    plain_log_ticks(ax.yaxis)
    ax.set_xlabel("입력 크기 (KiB, 로그)")
    ax.set_ylabel("파싱 시간 (ms, 로그)")
    ax.grid(axis="x", visible=False)
    save(fig, out, "chart-01-parse-latency")


def ios_hitches(data: Path, out: Path) -> None:
    rows = read(data, "ios_hitches")
    if not rows:
        return
    order = ["콜드 런치", "챗 첫 진입", "Mermaid 진입", "챗 스크롤", "SSE 20 Hz"]
    rows.sort(key=lambda r: (order.index(r["scenario"]), r["renderer"]))
    values = [float(r["hitch_ms_per_s"]) for r in rows]
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 3.2))
    ys = list(range(len(rows)))[::-1]
    ax.barh(ys, values, color=[SWIFTUI if r["renderer"] == "SwiftUI" else UIKIT for r in rows], height=0.62, zorder=3)
    runs = [int(r.get("runs") or 1) for r in rows]
    lows = [float(r.get("hitch_min_ms_per_s") or r["hitch_ms_per_s"]) for r in rows]
    highs = [float(r.get("hitch_max_ms_per_s") or r["hitch_ms_per_s"]) for r in rows]
    if max(runs) > 1:  # 반복 측정의 최소–최대
        ax.errorbar(values, ys, xerr=[[v - lo for v, lo in zip(values, lows)], [hi - v for v, hi in zip(values, highs)]],
                    fmt="none", ecolor=INK, elinewidth=1, capsize=3, zorder=4)
    for yi, value, low, high, n in zip(ys, values, lows, highs, runs):
        label = f"{value:g} ms/s ({low:g}–{high:g})" if n > 1 else f"{value:g} ms/s"
        value_label(ax, max(high, value), yi, label)
    for threshold in (5, 10):
        ax.axvline(threshold, color=MUTED, linewidth=1, linestyle=(0, (4, 3)), zorder=2)
        ax.annotate(f"{threshold} ms/s", (threshold, len(rows) - 0.45), xytext=(2, 0), textcoords="offset points",
                    fontsize=7.5, color=INK_2)
    ax.set_yticks(ys, [f"{r['scenario']} · {r['renderer']}" for r in rows])
    ax.set_xlim(0, max(highs + values) * 1.5)
    ax.set_xlabel(f"hitch 시간 비율 (ms/s, 앱 프로세스, 시나리오별 {max(runs)}회 중앙값, 가는 선은 최소–최대)"
                  if max(runs) > 1 else "hitch 시간 비율 (ms/s, 앱 프로세스, 시나리오별 1회)")
    bar_axis(ax)
    handles = [plt.Rectangle((0, 0), 1, 1, color=SWIFTUI), plt.Rectangle((0, 0), 1, 1, color=UIKIT)]
    ax.legend(handles, ["SwiftUI 렌더러", "UIKit 렌더러"], loc="lower right", fontsize=8)
    save(fig, out, "chart-02-ios-hitches")


def android_frames(data: Path, out: Path) -> None:
    rows = read(data, "android_frames")
    if not rows:
        return
    percentiles = [("p50_ms", "P50"), ("p90_ms", "P90"), ("p95_ms", "P95"), ("p99_ms", "P99")]
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 3.0))
    width = 0.18
    for index, (key, label) in enumerate(percentiles):
        xs = [i + (index - 1.5) * (width + 0.02) for i in range(len(rows))]
        values = [float(r[key]) for r in rows]
        ax.bar(xs, values, width=width, color=ORANGE_RAMP[index], label=label, zorder=3)
        for x, value in zip(xs, values):
            ax.annotate(f"{value:g}", (x, value), xytext=(0, 2), textcoords="offset points",
                        ha="center", fontsize=7, color=INK_2)
    ax.axhline(8.33, color=INK_2, linewidth=1, linestyle=(0, (4, 3)), zorder=2, label="120 Hz 프레임 예산 8.3 ms")
    ax.set_xticks(range(len(rows)), [f"{r['scenario']}\n{r['metric']}" for r in rows], fontsize=8)
    ax.set_ylabel("프레임 시간 (ms)")
    ax.grid(axis="x", visible=False)
    ax.legend(ncol=5, loc="upper left", fontsize=8, handlelength=1.6, columnspacing=1.0)
    ax.set_ylim(0, max(float(r["p99_ms"]) for r in rows) * 1.3)
    save(fig, out, "chart-03-android-frames")


def memory_timeline(data: Path, out: Path) -> None:
    rows = read(data, "memory_timeline")
    if not rows:
        return
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 2.9))
    longest = 0.0
    for renderer, color in [("SwiftUI", SWIFTUI), ("UIKit", UIKIT)]:
        points = [r for r in rows if r["renderer"] == renderer]
        if not points:
            continue
        start, end = float(points[0]["stream_start_s"]), float(points[0]["stream_end_s"])
        longest = max(longest, end - start)
        xs = [float(p["t_s"]) - start for p in points]
        ys = [float(p["footprint_mib"]) for p in points]
        ax.plot(xs, ys, color=color, linewidth=2, marker="o", markersize=3.5, zorder=3,
                label=f"{renderer} 렌더러 · 최대 {max(ys):.1f} MiB")
    low, high = ax.get_ylim()
    ax.set_ylim(low - 1, high + 1.5)
    ax.axvspan(0, longest, color="#f3f4f6", zorder=1)
    ax.annotate("스트리밍 구간", (longest / 2, low - 1), xytext=(0, 4), textcoords="offset points",
                ha="center", fontsize=7.5, color=INK_2)
    ax.set_xlabel("스트리밍 시작 기준 시간 (s)")
    ax.set_ylabel("physical footprint (MiB)")
    ax.legend(fontsize=8, loc="lower right")
    save(fig, out, "chart-04-memory-timeline")


def launch(data: Path, out: Path) -> None:
    rows = read(data, "launch")
    if not rows:
        return
    preferred = ["iOS 콜드", "Android 콜드 · 컴파일 없음", "Android 콜드 · 부분 컴파일",
                 "Android 웜 · 컴파일 없음", "Android 웜 · 부분 컴파일"]
    present = list(dict.fromkeys(r["case"] for r in rows))
    cases = [c for c in preferred if c in present] + [c for c in present if c not in preferred]
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 2.7))
    for index, case in enumerate(cases[::-1]):
        values = [float(r["ms"]) for r in rows if r["case"] == case]
        ax.scatter(values, [index] * len(values), s=22, color=IOS if case.startswith("iOS") else ANDROID,
                   alpha=0.55, linewidths=0, zorder=3)
        median = statistics.median(values)
        ax.plot([median, median], [index - 0.28, index + 0.28], color=INK, linewidth=1.6, zorder=4)
        spread = f", 최대 {max(values):.0f}" if max(values) > median * 1.5 else ""
        value_label(ax, max(values), index, f"중앙값 {median:.0f} ms (n={len(values)}{spread})")
    ax.set_yticks(range(len(cases)), cases[::-1])
    ax.set_xlim(0, max(float(r["ms"]) for r in rows) * 1.45)
    ax.set_xlabel("첫 화면 표시까지 (ms) · iOS XCTApplicationLaunchMetric, Android StartupTimingMetric TTID")
    bar_axis(ax)
    save(fig, out, "chart-05-launch")


def app_size(data: Path, out: Path) -> None:
    rows = read(data, "app_size")
    if not rows:
        return
    groups = list(dict.fromkeys(r["group"] for r in rows))
    heights = [sum(1 for r in rows if r["group"] == g) for g in groups]
    fig, axes = plt.subplots(len(groups), 1, figsize=(WIDTH_IN, 0.27 * sum(heights) + 1.1), sharex=True,
                             gridspec_kw={"height_ratios": heights}, squeeze=False)
    for ax, group in zip(axes[:, 0], groups):
        items = sorted((r for r in rows if r["group"] == group), key=lambda r: float(r["kib"]))
        ys = list(range(len(items)))
        ax.barh(ys, [float(r["kib"]) for r in items], color=IOS if group.startswith("iOS") else ANDROID,
                height=0.62, zorder=3)
        for yi, item in zip(ys, items):
            value_label(ax, float(item["kib"]), yi, f"{float(item['kib']):,.0f} KiB")
        ax.set_yticks(ys, [r["item"] for r in items], fontsize=8)
        ax.set_title(group, loc="left", fontsize=8.5, color=INK_2)
        bar_axis(ax)
    axes[-1, 0].set_xlabel("크기 (KiB)")
    axes[-1, 0].set_xlim(0, max(float(r["kib"]) for r in rows) * 1.25)
    fig.tight_layout()
    save(fig, out, "chart-06-app-size")


# ---------------------------------------------------------------- 품질

def coverage(data: Path, out: Path) -> None:
    rows = read(data, "coverage")
    if not rows:
        return
    rows.sort(key=lambda r: (r["platform"] != "iOS", -float(r["line_pct"])))
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 0.3 * len(rows) + 0.9))
    ys = list(range(len(rows)))[::-1]
    ax.barh(ys, [float(r["line_pct"]) for r in rows],
            color=[IOS if r["platform"] == "iOS" else ANDROID for r in rows], height=0.62, zorder=3)
    for yi, row in zip(ys, rows):
        value_label(ax, float(row["line_pct"]), yi,
                    f"{float(row['line_pct']):.1f}%  ({int(row['covered_lines']):,}/{int(row['executable_lines']):,})")
    ax.axvline(80, color=INK_2, linewidth=1, linestyle=(0, (4, 3)), zorder=2)
    ax.annotate("게이트 80%", (80, -0.75), xytext=(3, 0), textcoords="offset points", ha="left",
                fontsize=7.5, color=INK_2)
    ax.set_ylim(-0.9, len(rows) - 0.5)
    ax.set_yticks(ys, [f"{r['platform']} · {r['module']}" for r in rows], fontsize=8)
    ax.set_xlim(0, 135)
    ax.set_xticks([0, 20, 40, 60, 80, 100])
    ax.set_xlabel("라인 커버리지 (%)")
    bar_axis(ax)
    save(fig, out, "chart-07-coverage")


def fixtures(data: Path, out: Path) -> None:
    rows = read(data, "fixtures")
    if not rows:
        return
    rows.sort(key=lambda r: int(r["inputs"]))
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 0.27 * len(rows) + 0.8))
    ys = list(range(len(rows)))
    ax.barh(ys, [int(r["inputs"]) for r in rows], color=INK_2, height=0.62, zorder=3)
    for yi, row in zip(ys, rows):
        value_label(ax, int(row["inputs"]), yi, f"{int(row['inputs']):,}")
    ax.set_xscale("log")
    ax.set_xticks([1, 10, 100, 1000], ["1", "10", "100", "1,000"])
    ax.set_yticks(ys, [r["category"] for r in rows], fontsize=8)
    ax.set_xlabel("입력 수 (로그)")
    ax.set_xlim(1, max(int(r["inputs"]) for r in rows) * 3)
    bar_axis(ax)
    save(fig, out, "chart-08-fixtures")


def complexity(data: Path, out: Path) -> None:
    rows = read(data, "complexity")
    if not rows:
        return
    buckets = [("1", 1, 1), ("2", 2, 2), ("3–5", 3, 5), ("6–10", 6, 10), ("11–15", 11, 15), ("16–20", 16, 20),
               ("21+", 21, 10_000)]
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 2.9))
    width = 0.38
    for offset, (platform, color) in zip([-width / 2, width / 2], [("iOS", IOS), ("Android", ANDROID)]):
        ccn = [int(r["ccn"]) for r in rows if r["platform"] == platform]
        if not ccn:
            continue
        counts = [sum(lo <= c <= hi for c in ccn) for _, lo, hi in buckets]
        shares = [count * 100 / len(ccn) for count in counts]
        xs = [i + offset for i in range(len(buckets))]
        ax.bar(xs, shares, width=width - 0.03, color=color, zorder=3,
               label=f"{platform} (함수 {len(ccn):,}개, 중앙값 {statistics.median(ccn):g})")
        for x, share, count in zip(xs, shares, counts):
            ax.annotate(f"{count}", (x, share), xytext=(0, 2), textcoords="offset points", ha="center",
                        fontsize=7, color=INK_2)
    ax.set_xticks(range(len(buckets)), [b[0] for b in buckets])
    ax.set_xlabel("함수별 순환 복잡도 (lizard CCN, 테스트 코드 제외)")
    ax.set_ylabel("함수 비율 (%)")
    ax.grid(axis="x", visible=False)
    ax.legend(fontsize=8)
    save(fig, out, "chart-09-complexity")


def plain_log_ticks(axis) -> None:
    """로그축 눈금을 10ⁿ 대신 0.1·1·10·1,000처럼 쓴다(수학 글꼴의 음수 기호 누락도 피한다)."""
    axis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}" if v >= 1 else f"{v:g}"))


def ms(value: float) -> str:
    return f"{value:,.0f}" if value >= 10 else f"{value:,.1f}"


def pathological(data: Path, out: Path) -> None:
    rows = read(data, "pathological")
    if not rows:
        return
    rows.sort(key=lambda r: float(r["before_ms"]) if r["before_status"] == "ok" else 1e12)
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 0.24 * len(rows) + 0.9))
    for index, row in enumerate(rows):
        after = float(row["after_ms"])
        if row["before_status"] != "ok":
            ax.scatter([after], [index], s=26, color=SWIFTUI, zorder=4)
            value_label(ax, after, index, f"수정 전 {row['before_status']} → 수정 후 {after:,.1f} ms")
            continue
        before = float(row["before_ms"])
        ax.plot([min(after, before), max(after, before)], [index, index], color=GRID, linewidth=2, zorder=2)
        ax.scatter([before], [index], s=22, color=MUTED, zorder=3)
        ax.scatter([after], [index], s=26, color=SWIFTUI, zorder=4)
        if before / max(after, 0.001) >= 3:
            value_label(ax, max(before, after), index, f"{ms(before)} → {ms(after)} ms")
        elif after >= 1 and after / before >= 1.5:  # 1 ms 이상에서 크게 느려진 입력도 숨기지 않는다
            value_label(ax, max(before, after), index, f"{ms(before)} → {ms(after)} ms (느려짐)")
    ax.set_xscale("log")
    plain_log_ticks(ax.xaxis)
    ax.set_yticks(range(len(rows)), [r["id"] for r in rows], fontsize=7.5)
    ax.set_xlabel("파싱 시간 (ms, 로그) · 회색 수정 전(0.9.1) · 청록 수정 후")
    bar_axis(ax)
    peak = max(max(float(r["after_ms"]), float(r["before_ms"] or 0)) for r in rows)
    ax.set_xlim(ax.get_xlim()[0], peak * 25)  # 오른쪽 값 라벨 자리
    save(fig, out, "chart-10-pathological")


def parity(data: Path, out: Path) -> None:
    rows = read(data, "parity")
    if not rows:
        return
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 0.5 * len(rows) + 0.8))
    ys = list(range(len(rows)))[::-1]
    for yi, row in zip(ys, rows):
        total = int(row["total"])
        parts = [(int(row["match"]), SWIFTUI, "일치"), (int(row["approved"]), UIKIT, "승인 예외"),
                 (int(row["upstream"]), ANDROID, "상위 파서 차이"), (int(row["unresolved"]), "#c0392b", "미해결")]
        left = 0.0
        for count, color, _ in parts:
            share = count * 100 / total
            ax.barh(yi, share, left=left, color=color, height=0.5, zorder=3, edgecolor="white", linewidth=1)
            left += share
        detail = " · ".join(f"{name} {count:,}" for count, _, name in parts if count) + f" · 미해결 {int(row['unresolved'])}"
        ax.annotate(detail, (0, yi - 0.3), fontsize=7.5, color=INK_2, va="top")
    ax.set_yticks(ys, [f"{r['set']}\n({int(r['total']):,}건)" for r in rows], fontsize=8)
    ax.set_xlim(0, 100)
    ax.set_xlabel("iOS·Android 정규화 결과 비율 (%)")
    bar_axis(ax)
    ax.set_ylim(-0.9, len(rows) - 0.5)
    save(fig, out, "chart-11-parity")


def defects(data: Path, out: Path) -> None:
    rows = read(data, "defects")
    if not rows:
        return
    groups = {"F": "Core 정확성·성능·패리티", "E": "편집기", "R": "표시(렌더)", "S": "보안·공급망", "M": "메모리 안전",
              "P": "성능", "T": "테스트·fixture", "D": "상위 파서·승인 예외"}
    fixed, recorded = defaultdict(int), defaultdict(int)
    for row in rows:
        group = groups.get(row["id"][0], row["id"][0])
        (fixed if row["status"].startswith("수정") else recorded)[group] += 1
    names = sorted((g for g in groups.values() if fixed[g] or recorded[g]), key=lambda g: fixed[g] + recorded[g])
    fig, ax = plt.subplots(figsize=(WIDTH_IN, 0.3 * len(names) + 0.9))
    ys = list(range(len(names)))
    ax.barh(ys, [fixed[g] for g in names], color=IOS, height=0.6, zorder=3, label="수정")
    ax.barh(ys, [recorded[g] for g in names], left=[fixed[g] for g in names], color="#c9d1d9", height=0.6,
            zorder=3, label="기록·확인(수정 대상 아님)")
    for yi, g in zip(ys, names):
        value_label(ax, fixed[g] + recorded[g], yi, f"수정 {fixed[g]} · 기록 {recorded[g]}")
    ax.set_yticks(ys, names, fontsize=8)
    ax.set_xlabel("항목 수")
    ax.set_xlim(0, max(fixed[g] + recorded[g] for g in names) * 1.5)
    bar_axis(ax)
    ax.legend(fontsize=8, loc="lower right")
    save(fig, out, "chart-12-defects")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    setup_style()
    for draw in [parse_latency, ios_hitches, android_frames, memory_timeline, launch, app_size,
                 coverage, fixtures, complexity, pathological, parity, defects]:
        draw(args.data, args.out)


if __name__ == "__main__":
    main()
