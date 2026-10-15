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
#                     sse-swiftui-auto sse-uikit-auto sse-long-swiftui-auto sse-long-uikit-auto
# `launch-metrics`는 xctrace 없이 LaunchPerformanceTests(XCTApplicationLaunchMetric 등 5회)만 돌린다.
# `*-auto`는 UI 테스트 없이 xctrace가 `--launch -- <번들> -sseAutoplay … -sseFixture …`로 앱을 띄운다(앱 접근성 꺼짐).
# 앱이 녹화 시작 알림 1초 뒤 스스로 20Hz 스트림을 시작한다(알림을 놓치면 8초 뒤). 창은 앱의 `sse-stream` signpost다.
# 기존 sse-swiftui·sse-uikit은 XCUITest가 구동하는 "접근성 켜짐" 변형으로 남고, 요약에 두 창을 함께 낸다
# (`hitches` = PERF_WINDOW 창, `hitches_stream` = signpost 창).
# 시나리오마다 녹화를 나눈다 — CPU Profiler는 Hitches·Activity Monitor와 한 문서에 둘 수 없다
# ("Remove Instruments recording CPU Counters", 실측).
#   hitches: Time Profiler + Hitches   → hitch 통계, 메인 스레드 앱 프레임 (trace_summary.py)
#   cpu:     CPU Profiler              → xcprof analyze JSON
#   memory:  Activity Monitor (SSE만)  → 최대 physical footprint
#   alloc:   Allocations (SSE만)       → Instruments에서 여는 원본 (xctrace export로 읽을 수 없다)
#
# 선택 환경 변수: SKIP_BUILD=1, KINDS="hitches cpu", XCPROF=<xcprof 경로>, RICHMARKDOWN_CC=<xcodebuild CC 덮어쓰기>,
#   SIGNPOST_INSTRUMENT=<SSE 녹화에 더할 signpost 계측기, 기본 os_signpost — 가벼운 `Points of Interest`로 바꿀 수 있다>,
#   CPU_SIGNPOST=0 (CPU Profiler 녹화에 signpost 계측기를 더하지 않는다 — 그러면 자동 재생 cpu 창은 트레이스 전체)
# 빌드 뒤 `$OUT_DIR/build/`에 dSYM 사본과 provenance.txt(git SHA·dirty, 앱·dSYM UUID)를 남기고 분석은 그 dSYM을 쓴다.
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
readonly PRODUCTS="$DERIVED/Build/Products/Release-iphoneos"
# 분석은 빌드 직후 복사해 둔 dSYM을 쓴다. 같은 슬롯을 다시 빌드해도 이 결과 폴더의 트레이스와 맞는 짝이 남는다.
readonly DSYM="$OUT_DIR/build/$APP.app.dSYM"
readonly SIGNPOST=sse-stream
SIGNPOST_INSTRUMENT="${SIGNPOST_INSTRUMENT:-os_signpost}"
XCPROF="${XCPROF:-xcprof}"
mkdir -p "$OUT_DIR/failed" "$OUT_DIR/build" "$SLOT_DIR/tmp"

# bash 3.2(/bin/bash)는 `set -u`에서 빈 배열 "${a[@]}"를 unbound로 끝낸다. 비어 있을 수 있는 배열은 ${a[@]+…}로 펼친다.
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

# 자동 재생 시나리오의 앱 launch argument. UI 테스트 프로세스가 없다.
scenario_autoplay() {
    case "$1" in
        sse-swiftui-auto) echo "-sseAutoplay swiftui -sseFixture short" ;;
        sse-uikit-auto) echo "-sseAutoplay uikit -sseFixture short" ;;
        sse-long-swiftui-auto) echo "-sseAutoplay swiftui -sseFixture long" ;;
        sse-long-uikit-auto) echo "-sseAutoplay uikit -sseFixture long" ;;
        *) return 1 ;;
    esac
}

# 자동 재생: 런치 ~2초 + 알림 + 1초 안정화 + 스트림(short 약 7초, long 약 15초). 알림을 놓쳐 8초 대기로 가도 들어간다.
scenario_seconds() {
    case "$1" in
        chat-scroll-*) echo 60 ;;
        sse-long-*) echo 35 ;;
        sse-*-auto) echo 25 ;;
        sse-*) echo 20 ;;
        cold-launch-chat) echo 15 ;;
        mermaid-entry) echo 25 ;;
    esac
}

scenario_kinds() {
    case "$1" in
        sse-*-auto) echo "hitches cpu memory" ;;
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

# SSE 시나리오는 signpost 계측기를 더해 앱의 `sse-stream` 구간을 창으로 쓴다. 다른 시나리오는 이전 구성 그대로다.
kind_instruments() {  # <종류> <시나리오>
    local signpost=""
    case "$2" in sse-*) signpost="|$SIGNPOST_INSTRUMENT" ;; esac
    case "$1" in
        hitches) echo "Time Profiler|Hitches$signpost" ;;
        cpu) [ "${CPU_SIGNPOST:-1}" = 1 ] && echo "CPU Profiler$signpost" || echo "CPU Profiler" ;;
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

# xctrace가 기기 앱 런치에서 멈추면 스스로 끝나지 않는다(2026-10-15 iPad 8에서 69분 정지 실측). 제한 시간이 지나면
# SIGTERM으로 끝내고(스크립트의 백그라운드 작업은 SIGINT를 무시한다), 그래도 남아 있으면 강제 종료한다.
wait_or_kill() {  # <pid> <초>
    local i
    for ((i = 0; i < $2; i++)); do
        kill -0 "$1" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$1" 2>/dev/null; then
        kill -TERM "$1" 2>/dev/null
        for ((i = 0; i < 20; i++)); do kill -0 "$1" 2>/dev/null || break; sleep 1; done
        kill -9 "$1" 2>/dev/null
    fi
    wait "$1"
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
        "${sign_args[@]}" ${xcb_extra[@]+"${xcb_extra[@]}"} > "$OUT_DIR/build-for-testing.log" 2>&1
}

# 이 결과 폴더의 트레이스가 어떤 빌드에서 나왔는지 남기고 dSYM을 복사한다. 앱 바이너리와 dSYM UUID가 같아야 한다.
# PATH의 dwarfdump는 Homebrew libdwarf일 수 있어(--uuid 없음, 실측) xcrun으로 부른다.
record_provenance() {
    local file="$OUT_DIR/build/provenance.txt" dirty=clean
    [ -n "$(git status --porcelain)" ] && dirty=dirty
    rm -rf "$DSYM" && cp -R "$PRODUCTS/$APP.app.dSYM" "$DSYM" || return 1
    {
        echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "git_sha=$(git rev-parse HEAD) ($dirty)"
        echo "git_subject=$(git log -1 --format=%s)"
        echo "app_uuid=$(xcrun dwarfdump --uuid "$PRODUCTS/$APP.app/$APP" | awk '{print $2, $3}')"
        echo "dsym_uuid=$(xcrun dwarfdump --uuid "$DSYM" | awk '{print $2, $3}')"
    } > "$file"
    cat "$file"
}

# 자동 재생 시나리오는 xcodebuild test가 앱을 설치해 주지 않는다. 방금 빌드한 앱을 직접 설치한다.
install_app() {
    xcrun devicectl device install app --device "$DEVICE" "$PRODUCTS/$APP.app" > "$OUT_DIR/install-app.log" 2>&1
}

start_ui_test() {  # <시나리오> <초> <로그> <xcresult>
    TMPDIR="$SLOT_DIR/tmp/" TEST_RUNNER_RICHMARKDOWN_PERF=1 TEST_RUNNER_RICHMARKDOWN_PERF_TRACE_SECONDS="$2" \
        xcodebuild test-without-building \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
        -only-testing:"RichMarkdownDemoUITests/PerfScenarioUITests/$(scenario_test "$1")" \
        -resultBundlePath "$4" ${xcb_extra[@]+"${xcb_extra[@]}"} > "$3" 2>&1 &
    UI_PID=$!
}

# 녹화. 기기 연결이 잠들어 있으면 xctrace가 "Timed out waiting for device to boot"로 끝난다(실측) —
# devicectl 호출로 깨운 뒤 최대 3번 시도한다. 실패한 트레이스 파일은 지우지 않고 failed/로 옮긴다.
record_trace() {  # <시나리오> <종류> <트레이스> <로그>
    local seconds instruments=() names target=(--attach "$APP") attempt rc=1 autoplay notify_delay=0
    seconds=$(scenario_seconds "$1")
    IFS='|' read -ra names <<< "$(kind_instruments "$2" "$1")"
    for name in "${names[@]}"; do instruments+=(--instrument "$name"); done
    [ "$1" = cold-launch-chat ] && target=(--launch -- "$BUNDLE_ID")
    if autoplay=$(scenario_autoplay "$1"); then
        # shellcheck disable=SC2206 # launch argument는 공백으로 나뉜 고정 토큰이다.
        target=(--launch -- "$BUNDLE_ID" $autoplay)
        # "Ctrl-C to stop" 시점에 앱이 아직 알림 관찰을 걸지 못했을 수 있다. 런치를 기다렸다가 보낸다.
        notify_delay=2
    fi

    for attempt in 1 2 3; do
        xcrun devicectl device info lockState --device "$DEVICE" >/dev/null 2>&1
        xcrun xctrace record --device "$UDID" "${instruments[@]}" --time-limit "${seconds}s" \
            --no-prompt --output "$3" "${target[@]}" > "$4" 2>&1 &
        local xctrace_pid=$!
        if wait_for_line "Ctrl-C to stop" "$4" 90; then
            sleep "$notify_delay"
            xcrun devicectl device notification post --device "$DEVICE" --name "$NOTIFICATION" >/dev/null 2>&1
            wait_or_kill "$xctrace_pid" $((seconds + 120))
            rc=$?
            grep -q "Output file saved" "$4" && return "$rc"
        else
            wait_or_kill "$xctrace_pid" 0
            rc=$?
        fi
        echo "  xctrace 시도 $attempt 실패(rc=$rc): $(tail -1 "$4")"
        [ -e "$3" ] && mv "$3" "$OUT_DIR/failed/$(basename "$3" .trace).attempt$attempt.trace"
        sleep 5
    done
    return "$rc"
}

xcprof_window() {  # <트레이스> <출력 접두사> <trace_summary 창 인자...>
    local trace=$1 out=$2 range
    shift 2
    range=$(python3 scripts/bench/trace_summary.py "$trace" "$@" --window-only)
    # xctrace export가 심볼 정리 중 segfault로 자주 끝난다(실측: 트레이스에 따라 시도의 절반 이상,
    # 크래시 스택 SymbolOwner.deinit) — 통과할 때까지 최대 10번 시도한다.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # shellcheck disable=SC2086
        XCPROF_TRACE_ROOT="$OUT_DIR" "$XCPROF" analyze "$trace" --json --dsym "$DSYM" $range \
            > "$out.xcprof.json" 2> "$out.xcprof.err" && break
    done
}

# 창: UI 테스트 시나리오는 PERF_WINDOW 줄(이전 방식), SSE 시나리오는 `sse-stream` signpost도 함께 쓴다.
# CPU는 창마다 xcprof를 따로 돌린다 — UI 로그 창은 `<창>.xcprof.json`(이전 이름), signpost 창은
# `<창>.stream.xcprof.json`. UI 로그가 없는 자동 재생은 signpost 창이 곧 `<창>.xcprof.json`이다.
analyze() {  # <시나리오> <종류> <트레이스> <UI 로그(자동 재생이면 빈 값)>
    local base="${3%.trace}" window log_args signpost_args stream_suffix
    for window in $(scenario_windows "$1"); do
        log_args=()
        signpost_args=()
        stream_suffix=""
        [ -n "$4" ] && log_args=(--ui-log "$4" --window "$window") && stream_suffix=.stream
        case "$1" in sse-*) signpost_args=(--window-signpost "$SIGNPOST") ;; esac
        case "$2" in
            hitches|memory)
                python3 scripts/bench/trace_summary.py "$3" --app "$APP" \
                    ${log_args[@]+"${log_args[@]}"} ${signpost_args[@]+"${signpost_args[@]}"} > "$base.$window.summary.json"
                ;;
            cpu)
                [ ${#log_args[@]} -gt 0 ] && xcprof_window "$3" "$base.$window" "${log_args[@]}"
                [ ${#signpost_args[@]} -gt 0 ] && xcprof_window "$3" "$base.$window$stream_suffix" "${signpost_args[@]}"
                ;;
        esac
    done
}

run_scenario_kind() {  # <시나리오> <종류>
    local base="$OUT_DIR/$1.$2"
    if [ -e "$base.trace" ]; then
        echo "건너뜀(이미 있음): $base.trace"
        return 0
    fi
    echo "▶ $1 / $2"
    if scenario_autoplay "$1" >/dev/null; then
        record_trace "$1" "$2" "$base.trace" "$base.xctrace.log"
        echo "  xctrace rc=$? (자동 재생)"
        [ -e "$base.trace" ] && analyze "$1" "$2" "$base.trace" ""
        return 0
    fi
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
        -resultBundlePath "$base.xcresult" ${xcb_extra[@]+"${xcb_extra[@]}"} > "$base.log" 2>&1
    echo "launch-metrics rc=$? ($base.log)"
    python3 scripts/bench/collect.py "$base.xcresult" --out "$base.json" --table
}

main() {
    UDID=$(device_udid) || { echo "기기를 찾지 못했다: $DEVICE"; exit 1; }
    install_scheme
    if [ "${SKIP_BUILD:-0}" != 1 ]; then
        build_for_testing || { echo "빌드 실패: $OUT_DIR/build-for-testing.log"; exit 1; }
        record_provenance || { echo "dSYM을 찾지 못했다: $PRODUCTS/$APP.app.dSYM"; exit 1; }
    fi
    [ -d "$DSYM" ] || echo "경고: $DSYM 이 없다(SKIP_BUILD) — cpu 분석의 심볼이 비거나 다른 빌드와 섞일 수 있다"
    local scenarios=("$@") scenario kind installed=0
    [ ${#scenarios[@]} -eq 0 ] && scenarios=(chat-scroll-swiftui chat-scroll-uikit sse-swiftui sse-uikit cold-launch-chat mermaid-entry
        sse-swiftui-auto sse-uikit-auto sse-long-swiftui-auto sse-long-uikit-auto)
    for scenario in "${scenarios[@]}"; do
        [ "$scenario" = launch-metrics ] && { launch_metrics; continue; }
        if scenario_autoplay "$scenario" >/dev/null; then
            if [ "$installed" = 0 ]; then
                install_app || { echo "앱 설치 실패: $OUT_DIR/install-app.log"; exit 1; }
                installed=1
            fi
        else
            scenario_test "$scenario" >/dev/null || { echo "모르는 시나리오: $scenario"; continue; }
        fi
        for kind in ${KINDS:-$(scenario_kinds "$scenario")}; do
            case " $(scenario_kinds "$scenario") " in *" $kind "*) run_scenario_kind "$scenario" "$kind" ;; esac
        done
    done
}

main "$@"
