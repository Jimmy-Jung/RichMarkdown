#!/bin/bash
# Author: JunyoungJung
# Date: 2026-10-14
#
# iOS 실기기 xctrace 시나리오 (P2 성능 하네스, DEVELOPMENT.md §7 2026-09-15 표와 같은 시나리오).
#
#   DEVICE=<CoreDevice 식별자> OUT_DIR=<결과 폴더> SLOT_DIR=<빌드 슬롯> DEVELOPMENT_TEAM=<팀> \
#     scripts/bench/ios-trace-scenarios.sh [시나리오...]
#
# 시나리오(기본 전체): chat-scroll-swiftui chat-scroll-uikit sse-swiftui sse-uikit cold-launch-chat mermaid-entry
# `launch-metrics`는 xctrace 없이 LaunchPerformanceTests(XCTApplicationLaunchMetric 등 5회)만 돌린다.
# 시나리오마다 녹화를 나눈다 — CPU Profiler는 Hitches·Activity Monitor와 한 문서에 둘 수 없다
# ("Remove Instruments recording CPU Counters", 실측).
#   hitches: Time Profiler + Hitches   → hitch 통계, 메인 스레드 앱 프레임 (trace_summary.py)
#   cpu:     CPU Profiler              → xcprof analyze JSON
#   memory:  Activity Monitor (SSE만)  → 최대 physical footprint
#   alloc:   Allocations (SSE만)       → Instruments에서 여는 원본 (xctrace export로 읽을 수 없다)
#
# 선택 환경 변수: SKIP_BUILD=1, KINDS="hitches cpu", XCPROF=<xcprof 경로>, RICHMARKDOWN_CC=<xcodebuild CC 덮어쓰기>
# UI 조작은 PerfScenarioUITests가 한다. 녹화가 시작되면 이 스크립트가 Darwin 알림을 보내고, 테스트는 그때부터
# 시나리오를 실행한 뒤 xctrace가 --time-limit으로 스스로 끝날 때까지 앱을 살려 둔다.
set -uo pipefail
cd "$(dirname "$0")/../.."

: "${DEVICE:?DEVICE(CoreDevice 식별자, xcrun devicectl list devices)가 필요하다}"
: "${OUT_DIR:?OUT_DIR가 필요하다}"
: "${SLOT_DIR:?SLOT_DIR(빌드 슬롯)가 필요하다}"

readonly APP=RichMarkdownDemo
readonly BUNDLE_ID=dev.richmarkdown.RichMarkdownDemo
readonly NOTIFICATION=dev.richmarkdown.perf.tracing-started
readonly PROJECT=Examples/RichMarkdownDemo/RichMarkdownDemo.xcodeproj
readonly SCHEME=RichMarkdownDemoPerf
readonly DERIVED="$SLOT_DIR/DerivedData"
readonly DSYM="$DERIVED/Build/Products/Release-iphoneos/$APP.app.dSYM"
XCPROF="${XCPROF:-xcprof}"
mkdir -p "$OUT_DIR/failed" "$SLOT_DIR/tmp"

xcb_extra=()
[ -n "${RICHMARKDOWN_CC:-}" ] && xcb_extra+=("CC=$RICHMARKDOWN_CC")
sign_args=(-allowProvisioningUpdates)
[ -n "${DEVELOPMENT_TEAM:-}" ] && sign_args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")

scenario_test() {
    case "$1" in
        chat-scroll-swiftui) echo testChatScrollSwiftUI ;;
        chat-scroll-uikit) echo testChatScrollUIKit ;;
        sse-swiftui) echo testSSESwiftUI ;;
        sse-uikit) echo testSSEUIKit ;;
        cold-launch-chat) echo testColdLaunchToSwiftUIChat ;;
        mermaid-entry) echo testMermaidEntry ;;
        *) return 1 ;;
    esac
}

scenario_seconds() {
    case "$1" in
        chat-scroll-*) echo 60 ;;
        sse-*) echo 20 ;;
        cold-launch-chat) echo 15 ;;
        mermaid-entry) echo 25 ;;
    esac
}

scenario_kinds() {
    case "$1" in
        sse-*) echo "hitches cpu memory alloc" ;;
        *) echo "hitches cpu" ;;
    esac
}

scenario_windows() {
    case "$1" in
        cold-launch-chat) echo "cold-launch-chat.launch cold-launch-chat.entry" ;;
        *) echo "$1" ;;
    esac
}

kind_instruments() {
    case "$1" in
        hitches) echo "Time Profiler|Hitches" ;;
        cpu) echo "CPU Profiler" ;;
        memory) echo "Activity Monitor" ;;
        alloc) echo "Allocations" ;;
    esac
}

install_scheme() {
    local dir="$PROJECT/xcuserdata/$(id -un).xcuserdatad/xcschemes"
    mkdir -p "$dir" && cp scripts/bench/RichMarkdownDemoPerf.xcscheme "$dir/"
}

# xctrace는 CoreDevice 식별자가 아니라 하드웨어 UDID로 기기를 찾는다.
device_udid() {
    local json="$SLOT_DIR/tmp/device-$DEVICE.json"
    xcrun devicectl device info details --device "$DEVICE" -j "$json" >/dev/null 2>&1 || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["hardwareProperties"]["udid"])' "$json"
}

wait_for_line() {  # <정규식> <파일> <초>
    local i
    for ((i = 0; i < $3; i++)); do
        grep -q "$1" "$2" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

build_for_testing() {
    TMPDIR="$SLOT_DIR/tmp/" xcodebuild build-for-testing \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
        "${sign_args[@]}" "${xcb_extra[@]}" > "$OUT_DIR/build-for-testing.log" 2>&1
}

start_ui_test() {  # <시나리오> <초> <로그> <xcresult>
    TMPDIR="$SLOT_DIR/tmp/" TEST_RUNNER_RICHMARKDOWN_PERF=1 TEST_RUNNER_RICHMARKDOWN_PERF_TRACE_SECONDS="$2" \
        xcodebuild test-without-building \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
        -only-testing:"RichMarkdownDemoUITests/PerfScenarioUITests/$(scenario_test "$1")" \
        -resultBundlePath "$4" "${xcb_extra[@]}" > "$3" 2>&1 &
    UI_PID=$!
}

# 녹화. 기기 연결이 잠들어 있으면 xctrace가 "Timed out waiting for device to boot"로 끝난다(실측) —
# devicectl 호출로 깨운 뒤 최대 3번 시도한다. 실패한 트레이스 파일은 지우지 않고 failed/로 옮긴다.
record_trace() {  # <시나리오> <종류> <트레이스> <로그>
    local seconds instruments=() names target=(--attach "$APP") attempt rc=1
    seconds=$(scenario_seconds "$1")
    IFS='|' read -ra names <<< "$(kind_instruments "$2")"
    for name in "${names[@]}"; do instruments+=(--instrument "$name"); done
    [ "$1" = cold-launch-chat ] && target=(--launch -- "$BUNDLE_ID")

    for attempt in 1 2 3; do
        xcrun devicectl device info lockState --device "$DEVICE" >/dev/null 2>&1
        xcrun xctrace record --device "$UDID" "${instruments[@]}" --time-limit "${seconds}s" \
            --no-prompt --output "$3" "${target[@]}" > "$4" 2>&1 &
        local xctrace_pid=$!
        if wait_for_line "Ctrl-C to stop" "$4" 90; then
            xcrun devicectl device notification post --device "$DEVICE" --name "$NOTIFICATION" >/dev/null 2>&1
            wait "$xctrace_pid"
            rc=$?
            grep -q "Output file saved" "$4" && return "$rc"
        else
            wait "$xctrace_pid"
            rc=$?
        fi
        echo "  xctrace 시도 $attempt 실패(rc=$rc): $(tail -1 "$4")"
        [ -e "$3" ] && mv "$3" "$OUT_DIR/failed/$(basename "$3" .trace).attempt$attempt.trace"
        sleep 5
    done
    return "$rc"
}

analyze() {  # <시나리오> <종류> <트레이스> <UI 로그>
    local base="${3%.trace}" window range
    case "$2" in
        hitches|memory)
            for window in $(scenario_windows "$1"); do
                python3 scripts/bench/trace_summary.py "$3" --app "$APP" --ui-log "$4" --window "$window" \
                    > "$base.$window.summary.json"
            done
            ;;
        cpu)
            for window in $(scenario_windows "$1"); do
                range=$(python3 scripts/bench/trace_summary.py "$3" --ui-log "$4" --window "$window" --window-only)
                # xctrace export가 심볼 정리 중 segfault로 자주 끝난다(실측: 트레이스에 따라 시도의 절반 이상,
                # 크래시 스택 SymbolOwner.deinit) — 통과할 때까지 최대 10번 시도한다.
                for _ in 1 2 3 4 5 6 7 8 9 10; do
                    # shellcheck disable=SC2086
                    XCPROF_TRACE_ROOT="$OUT_DIR" "$XCPROF" analyze "$3" --json --dsym "$DSYM" $range \
                        > "$base.$window.xcprof.json" 2> "$base.$window.xcprof.err" && break
                done
            done
            ;;
    esac
}

run_scenario_kind() {  # <시나리오> <종류>
    local base="$OUT_DIR/$1.$2"
    if [ -e "$base.trace" ]; then
        echo "건너뜀(이미 있음): $base.trace"
        return 0
    fi
    echo "▶ $1 / $2"
    start_ui_test "$1" "$(scenario_seconds "$1")" "$base.ui.log" "$base.xcresult"
    if ! wait_for_line "^PERF_READY" "$base.ui.log" 300; then
        echo "  UI 테스트가 준비되지 않았다: $(grep -m1 -E 'error|Failing' "$base.ui.log")"
        kill "$UI_PID" 2>/dev/null
        wait "$UI_PID"
        return 1
    fi
    record_trace "$1" "$2" "$base.trace" "$base.xctrace.log"
    local rc=$?
    wait "$UI_PID"
    echo "  xctrace rc=$rc, UI 테스트 rc=$? ($(grep -m1 -oE "Test Case .* (passed|failed|skipped)" "$base.ui.log"))"
    [ -e "$base.trace" ] && analyze "$1" "$2" "$base.trace" "$base.ui.log"
}

launch_metrics() {
    local base="$OUT_DIR/launch-metrics-$(date +%Y%m%d-%H%M%S)"
    TMPDIR="$SLOT_DIR/tmp/" TEST_RUNNER_RICHMARKDOWN_PERF=1 xcodebuild test-without-building \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
        -only-testing:RichMarkdownDemoUITests/LaunchPerformanceTests \
        -resultBundlePath "$base.xcresult" "${xcb_extra[@]}" > "$base.log" 2>&1
    echo "launch-metrics rc=$? ($base.log)"
    python3 scripts/bench/collect.py "$base.xcresult" --out "$base.json" --table
}

main() {
    UDID=$(device_udid) || { echo "기기를 찾지 못했다: $DEVICE"; exit 1; }
    install_scheme
    if [ "${SKIP_BUILD:-0}" != 1 ]; then
        build_for_testing || { echo "빌드 실패: $OUT_DIR/build-for-testing.log"; exit 1; }
    fi
    local scenarios=("$@") scenario kind
    [ ${#scenarios[@]} -eq 0 ] && scenarios=(chat-scroll-swiftui chat-scroll-uikit sse-swiftui sse-uikit cold-launch-chat mermaid-entry)
    for scenario in "${scenarios[@]}"; do
        [ "$scenario" = launch-metrics ] && { launch_metrics; continue; }
        scenario_test "$scenario" >/dev/null || { echo "모르는 시나리오: $scenario"; continue; }
        for kind in ${KINDS:-$(scenario_kinds "$scenario")}; do
            case " $(scenario_kinds "$scenario") " in *" $kind "*) run_scenario_kind "$scenario" "$kind" ;; esac
        done
    done
}

main "$@"
