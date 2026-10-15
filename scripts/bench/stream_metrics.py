#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-15
"""SSE 스트림 창의 견고한 지표. Hitches 계측기의 hitch 판정(witness 규칙)에 기대지 않는다.

Instruments는 늦은 프레임을 그 수명 동안 다른 프레임(여기서는 ProgressView 스피너)이 화면에 나갔을 때만 hitch로
센다. 그래서 hitch 수는 스트림 시작의 vsync 위상에 따라 크게 갈린다. 아래 지표는 그 조건 없이 같은 창을 잰다.

창: 앱의 첫 `sse-stream` signpost 구간 ±slack ms(기본 trace_summary.py `WINDOW_SLACK_MS` = 300 — 같은 규칙).
시작 시각이 창 안인 이벤트만 세고, 초당 값의 분모는 구간 길이(여유 제외)다. 여유 없이 잰 이전 late excess 값과
비교할 때는 `--slack-ms 0`을 준다.

지표 (`metrics`)
  busy_ms_s         Time Profiler 앱 메인 스레드 표본 가중치 합 ms / s
  late_excess_ms_s  앱 프레임(앱 커밋의 swap-id를 가진 frame lifetime)마다 수명이 vsync 2개를 넘으면(round(수명/vsync) > 2)
                    수명 − 2 vsync를 더한 합 ms / s. 2프레임 렌더 루프를 놓친 지연의 총량이다.
  late_frames       위 조건의 앱 프레임 수 (app_frames = 창 안 앱 프레임 수)
  upd_*             hitches-updates 앱 커밋(containment-level 0): upd_n 개수, upd_s 개수/s, upd_p50·upd_p90 ms(선형 보간),
                    upd_over 프레임 예산(vsync 1개, budget_ms) 초과 개수, upd_ms_s 커밋 합 ms/s
  fps               hitches-frame-lifetimes 행(화면에 나간 프레임, 모든 surface) / s
  hitch_ms_s        hitches 표 앱 hitch 합 ms / s — 참고용, trace_summary `hitches_stream.ratio_ms_per_s`와 같은 정의
  parse_* rebuild_* raster_*   dev.richmarkdown signpost 구간: _n 개수, _s 개수/s, _mean 평균 ms, _ms_s 합 ms/s
메타데이터
  vsync         hz·source. 구간 시작 메시지의 max_fps(데모의 UIScreen.maximumFramesPerSecond)가 있으면 그 값(signpost),
                없으면 프레임 간격(창 안 frame lifetime 시작 간격 중 2 ms 초과의 5 백분위)을 60·120 Hz 중 가까운 값으로(cadence).
                cadence_hz는 항상 함께 낸다 — 저전력 모드처럼 실제 주사율이 최대보다 낮으면 둘이 갈린다.
  phase         구간 시작 메시지의 phase_seed·phase_offset_ms·max_fps (SSE 데모가 vsync에서 잰 첫 청크 offset)와
                실측 measured_ms·grid_r: 창 시작 ±200 ms frame lifetime 시작들의 원형 평균(vsync 1개 주기)을 격자로 잡고, 창 시작
                (첫 청크 전달)이 그 격자 뒤 몇 ms인지. grid_r(0–1)이 낮으면 격자가 흐려 measured_ms를 믿지 않는다.
                위상 층화·필터는 measured_ms로 한다 — offset_ms와 상수(격자 정의 차이)+깨어남 지연만큼 다르다.
  device_state  `device-state` signpost 이벤트의 at=start|end → thermal·low_power

`--table`은 여러 요약 JSON을 cfg별로 묶어 (기기, 시나리오, 지표)마다 중앙값·평균·최소–최대·n과 cfg 쌍의
Cliff's δ(P(앞 > 뒤) − P(앞 < 뒤), ±1 = 완전 분리, + = 뒤 cfg에서 값이 줄었다)를 Markdown 표로 낸다.

  stream_metrics.py <trace> [--app RichMarkdownDemo] [--slack-ms 300] > <base>.<창>.metrics.json
  stream_metrics.py --table [--metric busy_ms_s ...] <cfg>=<요약 JSON 또는 폴더> [<cfg>=...]
  stream_metrics.py --self-test
"""
import argparse
import glob
import json
import math
import os
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

from trace_summary import WINDOW_SLACK_MS, label, number

WINDOW_SIGNPOST = "sse-stream"
DEMO_SUBSYSTEM = "dev.richmarkdown.demo"
LIB_SUBSYSTEM = "dev.richmarkdown"
LIB_CATEGORIES = ("parse", "rebuild", "raster")
TABLES = ["os-signpost-interval", "os-signpost", "time-profile", "hitches-updates", "hitches-frame-lifetimes", "hitches"]
# ponytail: iOS 화면은 60 Hz 또는 120 Hz(ProMotion)뿐이라 프레임 간격 추정을 둘 중 가까운 값으로 맞춘다.
REFRESH_RATES = (60, 120)
PHASE_GRID_MS = 200
TABLE_METRICS = ["busy_ms_s", "late_excess_ms_s", "late_frames", "upd_s", "upd_p50", "upd_p90", "upd_over", "fps",
                 "hitch_ms_s"]

# xctrace는 한 번에 여러 표를 export하면 첫 표에만 <schema>를 붙인다(실측, Xcode 26.6). 나머지 표는 이 열 순서로
# 읽고, 쓰는 열은 첫 행의 요소 태그로 검증한다(열 구성이 바뀌면 조용히 틀리지 않고 멈춘다). 태그 None = 검증 안 함.
_PROFILE = [("time", "sample-time"), ("thread", "thread"), ("process", "process"), ("core", None),
            ("thread-state", None), ("weight", None), ("stack", None)]
COLUMNS = {
    "hitches-updates": [("start", "start-time"), ("duration", "duration"), ("process", "process"), ("display", None),
                        ("swap-id", "uint32"), ("surface-id", None), ("frame-color", None),
                        ("containment-level", "uint32"), ("label", None)],
    "hitches-frame-lifetimes": [("start", "start-time"), ("duration", "duration"), ("display", None),
                                ("swap-id", "uint32"), ("surface-id", None), ("frame-color", None),
                                ("layout-qualifier", None), ("label", None)],
    "hitches": [("start", "start-time"), ("duration", "duration"), ("process", "process"), ("is-system", None),
                ("swap-id", None), ("label", None), ("display", None), ("narrative-description", None)],
    "time-profile": _PROFILE,
    "os-signpost-interval": [("start", "start-time"), ("duration", "duration"), ("layout-qualifier", None),
                             ("name", "string"), ("category", "category"), ("subsystem", "subsystem"),
                             ("identifier", None), ("process", "process"), ("end-process", None),
                             ("start-thread", None), ("end-thread", None), ("start-message", None),
                             ("end-message", None), ("start-backtrace", None), ("end-backtrace", None),
                             ("start-emit-location", None), ("end-emit-location", None), ("signature", None)],
    "os-signpost": [("time", "event-time"), ("thread", None), ("process", "process"), ("event-type", "event-type"),
                    ("scope", None), ("identifier", None), ("name", "signpost-name"), ("format-string", None),
                    ("backtrace", None), ("subsystem", "subsystem"), ("category", None), ("message", None),
                    ("emit-location", None)],
}


# ---------- xctrace ----------

def xctrace(*args, attempts=4):
    """xctrace export는 가끔 segfault(rc 139)·빈 출력으로 끝난다 — 다시 돌리면 통과한다(실측)."""
    for _ in range(attempts):
        run = subprocess.run(["xcrun", "xctrace", *args], capture_output=True, text=True, check=False)
        if run.returncode == 0 and run.stdout.strip():
            return run.stdout
    raise RuntimeError(f"xctrace {' '.join(args[:3])} rc={run.returncode}: {run.stderr.strip()[-200:]}")


def parse_export(xml_text, schema_by_index):
    """xctrace export XML → {schema: [행 {열: 요소}]}. id/ref 압축은 문서 전체(표 사이 포함)에 걸쳐 푼다."""
    tables, registry = {}, {}
    for node in ET.fromstring(xml_text).findall("node"):
        schema = schema_by_index[int(re.search(r"table\[(\d+)\]", node.get("xpath", "")).group(1))]
        declared = node.find("schema")
        known = COLUMNS.get(schema, [])
        columns = ([col.findtext("mnemonic") for col in declared.findall("col")] if declared is not None
                   else [name for name, _ in known])
        expected = dict(known)
        rows = tables.setdefault(schema, [])
        for row in node.findall("row"):
            for element in row.iter():
                if "id" in element.attrib:
                    registry[element.get("id")] = element
            cells = [registry.get(c.get("ref"), c) if "ref" in c.attrib else c for c in row]
            if len(cells) != len(columns):
                raise ValueError(f"{schema}: 열 {len(columns)}개를 기대했는데 {len(cells)}개 — COLUMNS를 고친다")
            if not rows:
                for name, cell in zip(columns, cells):
                    if expected.get(name) and cell.tag not in (expected[name], "sentinel"):
                        raise ValueError(f"{schema}.{name}: 태그 {expected[name]}을 기대했는데 {cell.tag}")
            rows.append(dict(zip(columns, cells)))
    return tables


def export_tables(trace):
    """TOC 1번 + 있는 표 전부를 XPath `or`로 1번 export → (표, 기기 정보)."""
    toc = ET.fromstring(xctrace("export", "--input", trace, "--toc"))
    run = toc.find("run")
    schema_by_index = {i: t.get("schema") for i, t in enumerate(run.find("data").findall("table"), 1)}
    present = [s for s in TABLES if s in schema_by_index.values()]
    device = run.find("info/target/device")
    # 기기 이름(name)은 사람 이름이 들어갈 수 있어 남기지 않는다.
    info = {key: device.get(key) for key in ("model", "os-version")} if device is not None else {}
    if not present:
        return {}, info
    xpath = '/trace-toc/run[@number="1"]/data/table[' + " or ".join(f'@schema="{s}"' for s in present) + "]"
    return parse_export(xctrace("export", "--input", trace, "--xpath", xpath), schema_by_index), info


# ---------- 원자료 → 지표 ----------

def key_values(text):
    """`a=1 b=x` 꼴 메시지 → dict. 숫자는 int·float로 바꾼다."""
    out = {}
    for key, value in re.findall(r"(\w+)=(\S+)", text or ""):
        for cast in (int, float):
            try:
                value = cast(value)
                break
            except ValueError:
                pass
        out[key] = value
    return out


def stream_span(signpost_rows, app):
    """앱의 첫 `sse-stream` 구간 → (시작 ns, 끝 ns, 시작 메시지). 없으면 None."""
    spans = sorted((number(r["start"]), number(r["duration"]), label(r.get("start-message"))) for r in signpost_rows
                   if label(r.get("name")) == WINDOW_SIGNPOST and label(r.get("process")).startswith(app)
                   and number(r.get("start")) is not None and number(r.get("duration")) is not None)
    return (spans[0][0], spans[0][0] + spans[0][1], spans[0][2]) if spans else None


def percentile(values, q):
    """선형 보간 백분위(numpy 기본과 같다). 빈 목록이면 None."""
    s = sorted(values)
    if not s:
        return None
    k = (len(s) - 1) * q
    f = math.floor(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


def cadence_hz(frame_starts_ns):
    """서로 다른 프레임 시작 간격(2 ms 초과)의 5 백분위 → 가까운 주사율. 같은 vsync의 여러 surface는 2 ms 안에 몰린다."""
    starts = sorted(frame_starts_ns)
    gaps = sorted(b - a for a, b in zip(starts, starts[1:]) if b - a > 2_000_000)
    if not gaps:
        return None
    measured = 1e9 / gaps[len(gaps) // 20]
    return min(REFRESH_RATES, key=lambda hz: abs(hz - measured))


def circular_phase(times_ns, period_ns):
    """시각들을 period 원 위에서 평균 → (격자 위상 ns, R). R이 1에 가까울수록 한 격자에 모였다. 빈 목록이면 (None, None)."""
    angles = [2 * math.pi * (t % period_ns) / period_ns for t in times_ns]
    if not angles:
        return None, None
    s, c = sum(map(math.sin, angles)), sum(map(math.cos, angles))
    return math.atan2(s, c) / (2 * math.pi) % 1 * period_ns, math.hypot(s, c) / len(angles)


def measured_phase(start_ns, frame_starts_ns, hz):
    """창 시작(첫 청크 전달)의 실측 vsync 위상 ms. 격자는 창 시작 ±PHASE_GRID_MS 안 frame lifetime 시작들의 원형 평균이다.
    실제 주사율이 공칭(60·120 Hz)과 조금 달라 격자가 창 내내 미끄러진다 — 창 전체로 잡으면 iPad 8에서 약 0.9 ms 치우쳤다(실측)."""
    period = 1e9 / hz
    near = [t for t in frame_starts_ns if abs(t - start_ns) <= PHASE_GRID_MS * 1_000_000]
    grid, r = circular_phase(near, period)
    if grid is None:
        return {}
    return {"measured_ms": round((start_ns - grid) % period / 1e6, 3), "grid_r": round(r, 3)}


def late_excess(lifetimes_ns, period_ns, span_s):
    """앱 프레임 수명 → (늦은 프레임 수, 초과 ms/s). 수명이 vsync 2개보다 길게 반올림되면 늦은 프레임이다."""
    late = [d for d in lifetimes_ns if round(d / period_ns) > 2]
    return len(late), sum(d - 2 * period_ns for d in late) / 1e6 / span_s


def device_states(event_rows, app):
    """`device-state` 이벤트 → {"start": {...}, "end": {...}}."""
    out = {}
    for r in event_rows:
        if label(r.get("name")) == "device-state" and label(r.get("subsystem")) == DEMO_SUBSYSTEM \
                and label(r.get("process")).startswith(app):
            state = key_values(label(r.get("message")))
            moment = state.pop("at", None)
            if moment:
                out[moment] = state
    return out


def summarize(tables, app, slack_ms):
    """표 → 요약 dict. 창이 없으면 window만 null인 dict."""
    span = stream_span(tables.get("os-signpost-interval", []), app)
    if span is None:
        return {"window": None}
    start_ns, end_ns, message = span
    lo, hi = start_ns - slack_ms * 1_000_000, end_ns + slack_ms * 1_000_000
    span_s = (end_ns - start_ns) / 1e9

    def inside(element):
        t = number(element)
        return t is not None and lo <= t <= hi

    meta = key_values(message)
    phase = {k: meta[f"phase_{k}"] for k in ("seed", "offset_ms") if f"phase_{k}" in meta}
    if "max_fps" in meta:
        phase["max_fps"] = meta["max_fps"]
    frames = [r for r in tables.get("hitches-frame-lifetimes", []) if inside(r["start"])]
    cadence = cadence_hz(number(r["start"]) for r in frames)
    hz, source = (meta["max_fps"], "signpost") if meta.get("max_fps") else (cadence, "cadence")
    if hz:
        phase.update(measured_phase(start_ns, [number(r["start"]) for r in frames], hz))
    metrics = window_metrics(tables, app, inside, span_s, frames, hz)
    return {"window": {"signpost": WINDOW_SIGNPOST, "ms": [round(start_ns / 1e6, 1), round(end_ns / 1e6, 1)],
                       "s": round(span_s, 3), "slack_ms": slack_ms},
            "vsync": {"hz": hz, "source": source if hz else None, "cadence_hz": cadence},
            "phase": phase or None,
            "device_state": device_states(tables.get("os-signpost", []), app),
            "metrics": {k: round(v, 4) if isinstance(v, float) else v for k, v in metrics.items()}}


def window_metrics(tables, app, inside, span_s, frames, hz):
    """창 안 이벤트 → 지표 dict(머리말의 `metrics`). 표가 없던 지표는 키가 없다."""
    def mine(row):
        return label(row.get("process")).startswith(app)

    metrics = {}
    if "time-profile" in tables:
        metrics["busy_ms_s"] = sum(number(r["weight"]) or 0 for r in tables["time-profile"]
                                   if mine(r) and "Main Thread" in label(r["thread"]) and inside(r["time"])) / 1e6 / span_s
    app_updates = [r for r in tables.get("hitches-updates", [])
                   if mine(r) and (r["containment-level"].text or "").strip() == "0" and number(r["duration"]) is not None]
    if "hitches-updates" in tables:
        update_ms = [number(r["duration"]) / 1e6 for r in app_updates if inside(r["start"])]
        budget_ms = 1000 / hz if hz else None
        metrics.update(upd_n=len(update_ms), upd_s=len(update_ms) / span_s, upd_p50=percentile(update_ms, .5),
                       upd_p90=percentile(update_ms, .9), upd_ms_s=sum(update_ms) / span_s,
                       upd_over=sum(1 for d in update_ms if d > budget_ms) if budget_ms else None, budget_ms=budget_ms)
    if "hitches-frame-lifetimes" in tables:
        metrics.update(frames=len(frames), fps=len(frames) / span_s)
        if hz and "hitches-updates" in tables:
            swaps = {number(r["swap-id"]) for r in app_updates}
            lifetimes = [number(r["duration"]) for r in frames if number(r["swap-id"]) in swaps]
            metrics["app_frames"] = len(lifetimes)
            metrics["late_frames"], metrics["late_excess_ms_s"] = late_excess(lifetimes, 1e9 / hz, span_s)
    if "hitches" in tables:
        hitch_ms = [number(r["duration"]) / 1e6 for r in tables["hitches"]
                    if mine(r) and inside(r["start"]) and number(r["duration"]) is not None]
        metrics.update(hitch_n=len(hitch_ms), hitch_ms_s=sum(hitch_ms) / span_s)
    for category in LIB_CATEGORIES:
        durations = [number(r["duration"]) / 1e6 for r in tables.get("os-signpost-interval", [])
                     if label(r.get("subsystem")) == LIB_SUBSYSTEM and label(r.get("category")) == category
                     and mine(r) and inside(r["start"]) and number(r.get("duration")) is not None]
        metrics.update({f"{category}_n": len(durations), f"{category}_s": len(durations) / span_s,
                        f"{category}_mean": sum(durations) / len(durations) if durations else None,
                        f"{category}_ms_s": sum(durations) / span_s})
    return metrics


def trace_metrics(trace, app, slack_ms):
    tables, device = export_tables(trace)
    name = os.path.basename(trace.rstrip("/"))
    return {"trace": trace, "scenario": name.split(".")[0], "device": device, **summarize(tables, app, slack_ms)}


# ---------- --table ----------

def cliffs_delta(a, b):
    """P(a > b) − P(a < b). +1이면 a가 전부 b보다 크다(뒤 cfg에서 값이 줄었다)."""
    if not a or not b:
        return None
    return sum((x > y) - (x < y) for x in a for y in b) / (len(a) * len(b))


def load_summaries(specs):
    """`cfg=경로` 목록 → [(cfg, 요약)]. 경로가 폴더면 아래의 *.metrics.json 전부."""
    loaded = []
    for spec in specs:
        cfg, _, path = spec.partition("=")
        if not path:
            raise SystemExit(f"--table 인자는 <cfg>=<경로>여야 한다: {spec}")
        files = sorted(glob.glob(os.path.join(path, "**", "*.metrics.json"), recursive=True)) \
            if os.path.isdir(path) else [path]
        loaded += [(cfg, json.load(open(f))) for f in files]
    return loaded


def cell(values):
    if not values:
        return "—"
    return (f"{statistics.median(values):.4g} ({statistics.fmean(values):.4g}, "
            f"{min(values):.4g}–{max(values):.4g}, n={len(values)})")


def table(loaded, metrics):
    """(기기, 시나리오, 지표) 행 × cfg 열. 셀 = 중앙값 (평균, 최소–최대, n). 뒤 열 = cfg 쌍의 Cliff's δ."""
    cfgs = list(dict.fromkeys(cfg for cfg, _ in loaded))
    pairs = [(a, b) for i, a in enumerate(cfgs) for b in cfgs[i + 1:]]
    values = {}
    for cfg, summary in loaded:
        group = ((summary.get("device") or {}).get("model") or "?", summary.get("scenario") or "?")
        for metric in metrics:
            value = (summary.get("metrics") or {}).get(metric)
            if value is not None:
                values.setdefault((*group, metric), {}).setdefault(cfg, []).append(value)
    lines = ["| 기기 | 시나리오 | 지표 | " + " | ".join(cfgs) + " | " + " | ".join(f"δ {a}→{b}" for a, b in pairs) + " |",
             "|---|---|---|" + "---|" * len(cfgs) + "---:|" * len(pairs)]
    for device, scenario, metric in sorted(values, key=lambda k: (k[0], k[1], metrics.index(k[2]))):
        by_cfg = values[(device, scenario, metric)]
        deltas = [cliffs_delta(by_cfg.get(a), by_cfg.get(b)) for a, b in pairs]
        lines.append(f"| {device} | {scenario} | {metric} | " + " | ".join(cell(by_cfg.get(c)) for c in cfgs) + " | "
                     + " | ".join("—" if d is None else f"{d:+.2f}" for d in deltas) + " |")
    return "\n".join(lines)


# ---------- self-test ----------

def self_test():
    assert percentile([1, 2, 3, 4], .5) == 2.5 and percentile([5], .99) == 5 and percentile([], .5) is None
    assert cliffs_delta([3, 4], [1, 2]) == 1 and cliffs_delta([1, 2], [1, 2]) == 0 and cliffs_delta([], [1]) is None
    period = 1e9 / 60
    assert late_excess([2 * period, 3 * period, 4 * period], period, 1.0) == (2, (period + 2 * period) / 1e6)
    # 120 Hz: 두 surface가 번갈아 vsync에 나가면 간격 ~8.3 ms. 같은 vsync의 surface(0.5 ms 간격)는 빼고 본다.
    assert cadence_hz([0, 500_000, 8_333_333, 16_666_667, 17_100_000, 25_000_000]) == 120
    assert cadence_hz([0, 100_000, 16_600_000, 33_400_000, 50_000_000]) == 60 and cadence_hz([0]) is None
    # 격자 0 양옆 ±0.5 ms → 0 근처(산술 평균이면 반 프레임). 한 vsync 안에 고르게 흩어지면 R ≈ 0.
    grid, r = circular_phase([period - 500_000, 2 * period + 500_000], period)
    assert min(grid, period - grid) < 1_000 and r > .98, (grid, r)
    assert circular_phase([0, period / 2], period)[1] < 1e-9 and circular_phase([], period) == (None, None)
    # 실제 주기가 공칭보다 0.05% 길면 900프레임(15 s) 동안 격자가 7.5 ms 미끄러진다. 위상은 창 시작 근처 격자로 잰다.
    drifting = [3_000_000 + k * period * 1.0005 for k in range(900)]
    assert abs(measured_phase(4_000_000, drifting, 60)["measured_ms"] - 1.0) < .2
    assert measured_phase(4_000_000, [], 60) == {}
    assert key_values("swiftui long 20Hz phase_seed=7 phase_offset_ms=4.125 max_fps=120") == \
        {"phase_seed": 7, "phase_offset_ms": 4.125, "max_fps": 120}

    # 두 번째·세 번째 표에는 <schema>가 없고, ref가 첫 표의 process 요소를 가리킨다(실제 export 모양).
    app = '<process id="3" fmt="App (1)"/>'
    update = ("<row><start-time id=\"{id}\">{start}</start-time><duration id=\"{id}1\">{dur}</duration>{proc}"
              "<sentinel/><uint32 id=\"{id}2\">{swap}</uint32><uint32 id=\"{id}3\">1</uint32><sentinel/>"
              "<uint32 id=\"{id}4\">{level}</uint32><sentinel/></row>")
    lifetime = ("<row><start-time id=\"{id}\">{start}</start-time><duration id=\"{id}1\">{dur}</duration><sentinel/>"
                "<uint32 id=\"{id}2\">{swap}</uint32>" + "<sentinel/>" * 4 + "</row>")
    interval = ("<row><start-time id=\"{id}\">{start}</start-time><duration id=\"{id}1\">{dur}</duration><sentinel/>"
                "<string id=\"{id}2\" fmt=\"{name}\">{name}</string><category id=\"{id}3\" fmt=\"{cat}\">{cat}</category>"
                "<subsystem id=\"{id}4\" fmt=\"{sub}\">{sub}</subsystem><sentinel/><process ref=\"3\"/>" + "<sentinel/>" * 3
                + "<os-log-metadata id=\"{id}5\" fmt=\"{msg}\"/>" + "<sentinel/>" * 6 + "</row>")
    event = ("<row><event-time id=\"{id}\">{time}</event-time><sentinel/><process ref=\"3\"/>"
             "<event-type id=\"{id}1\" fmt=\"Event\">Event</event-type>" + "<sentinel/>" * 2
             + "<signpost-name id=\"{id}2\" fmt=\"device-state\">device-state</signpost-name>" + "<sentinel/>" * 2
             + "<subsystem id=\"{id}3\" fmt=\"" + DEMO_SUBSYSTEM + "\"/><sentinel/>"
             "<os-log-metadata id=\"{id}4\" fmt=\"{msg}\"/><sentinel/></row>")
    ms = 1_000_000
    xml_text = ("<?xml version=\"1.0\"?><trace-query-result><node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'>"
                "<schema name=\"hitches-updates\">" + "".join(f"<col><mnemonic>{m}</mnemonic></col>"
                                                              for m, _ in COLUMNS["hitches-updates"]) + "</schema>"
                + update.format(id=10, start=1000 * ms, dur=9 * ms, proc=app, swap=1, level=0)
                + update.format(id=20, start=1100 * ms, dur=4 * ms, proc='<process ref="3"/>', swap=2, level=1)
                + update.format(id=30, start=1200 * ms, dur=20 * ms, proc='<process ref="3"/>', swap=3, level=0)
                + "</node><node xpath='//trace-toc[1]/run[1]/data[1]/table[2]'>"
                + lifetime.format(id=35, start=505 * ms, dur=16 * ms, swap=9)  # 창 시작 근처, 앱 프레임 아님
                + lifetime.format(id=40, start=1010 * ms, dur=50 * ms, swap=1)  # 3 vsync → 늦음, 초과 16.7 ms
                + lifetime.format(id=50, start=1110 * ms, dur=50 * ms, swap=2)  # 앱 커밋(level 0) 아님
                + lifetime.format(id=60, start=1210 * ms, dur=33 * ms, swap=3)
                + "</node><node xpath='//trace-toc[1]/run[1]/data[1]/table[3]'>"
                + interval.format(id=70, start=500 * ms, dur=3000 * ms, name=WINDOW_SIGNPOST, cat="PointsOfInterest",
                                  sub=DEMO_SUBSYSTEM, msg="swiftui short 20Hz phase_seed=7 phase_offset_ms=4.125 max_fps=60")
                + interval.format(id=80, start=1200 * ms, dur=2 * ms, name="parse", cat="parse", sub=LIB_SUBSYSTEM, msg="")
                + interval.format(id=90, start=4000 * ms, dur=2 * ms, name="parse", cat="parse", sub=LIB_SUBSYSTEM, msg="")
                + "</node><node xpath='//trace-toc[1]/run[1]/data[1]/table[4]'>"
                + event.format(id=100, time=500 * ms, msg="at=start thermal=nominal low_power=0")
                + event.format(id=110, time=3500 * ms, msg="at=end thermal=fair low_power=1")
                + "</node></trace-query-result>")
    schemas = {1: "hitches-updates", 2: "hitches-frame-lifetimes", 3: "os-signpost-interval", 4: "os-signpost"}
    summary = summarize(parse_export(xml_text, schemas), "App", 300)
    assert summary["window"] == {"signpost": WINDOW_SIGNPOST, "ms": [500.0, 3500.0], "s": 3.0, "slack_ms": 300}, summary
    assert summary["vsync"] == {"hz": 60, "source": "signpost", "cadence_hz": 60}, summary["vsync"]
    # 창 시작 ±200 ms frame은 505 ms뿐 → 격자 5 ms(R 1). 창 시작 500 ms의 위상 = (500 − 5) mod 16.667 = 11.667 ms.
    assert summary["phase"] == {"seed": 7, "offset_ms": 4.125, "max_fps": 60, "measured_ms": 11.667, "grid_r": 1.0}, \
        summary["phase"]
    assert summary["device_state"] == {"start": {"thermal": "nominal", "low_power": 0},
                                       "end": {"thermal": "fair", "low_power": 1}}, summary["device_state"]
    m = summary["metrics"]
    # containment-level 1 커밋 제외 → 커밋 9·20 ms, 20 ms만 예산(16.7 ms) 초과. 4.0 s parse는 창(+300 ms) 밖.
    assert m["upd_n"] == 2 and m["upd_over"] == 1 and m["upd_p50"] == 14.5 and m["frames"] == 4, m
    assert m["app_frames"] == 2 and m["late_frames"] == 1 and m["late_excess_ms_s"] == round((50 - 2000 / 60) / 3, 4), m
    assert m["parse_n"] == 1 and m["parse_mean"] == 2.0 and "busy_ms_s" not in m, m
    try:
        parse_export(xml_text.replace('<uint32 id="102">1</uint32>', '<string id="102">1</string>'), schemas)
        raise AssertionError("열 태그 불일치를 잡아야 한다")
    except ValueError:
        pass
    assert summarize({}, "App", 300) == {"window": None}

    loaded = [(cfg, {"device": {"model": "iPad"}, "scenario": "sse-swiftui-auto", "metrics": {"busy_ms_s": v}})
              for cfg, vs in (("m0", [10, 11, 12]), ("m2", [5, 6, 7])) for v in vs]
    rows = table(loaded, ["busy_ms_s", "fps"]).splitlines()
    assert rows[0] == "| 기기 | 시나리오 | 지표 | m0 | m2 | δ m0→m2 |" and len(rows) == 3, rows
    assert rows[2] == "| iPad | sse-swiftui-auto | busy_ms_s | 11 (11, 10–12, n=3) | 6 (6, 5–7, n=3) | +1.00 |", rows[2]
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("trace", nargs="*", help="트레이스 1개, 또는 --table이면 <cfg>=<요약 JSON 또는 폴더> 여러 개")
    parser.add_argument("--app", default="RichMarkdownDemo")
    parser.add_argument("--slack-ms", type=int, default=WINDOW_SLACK_MS)
    parser.add_argument("--table", action="store_true", help="요약 JSON을 cfg별 Markdown 표로 묶는다")
    parser.add_argument("--metric", action="append", help=f"--table 지표(기본 {' '.join(TABLE_METRICS)})")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.table:
        return print(table(load_summaries(args.trace), args.metric or TABLE_METRICS))
    if len(args.trace) != 1:
        parser.error("트레이스 1개가 필요하다")
    json.dump(trace_metrics(args.trace[0], args.app, args.slack_ms), sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
