#!/bin/bash
# Author: JunyoungJung
# Date: 2026-10-14
#
# iOS 마이크로 벤치마크(RichMarkdownBenchmarks)를 Release로 실기기·시뮬레이터에서 돌리고 results.json을 만든다.
#
#   DEVICE=<CoreDevice 식별자 또는 시뮬레이터 UDID> OUT_DIR=<결과> SLOT_DIR=<빌드 슬롯> DEVELOPMENT_TEAM=<팀> \
#     [LABEL="iPad Pro M5"] scripts/bench/ios-micro.sh
#   CROSS_CHECK=1 ...  50 KiB 파싱만 50회, Time Profiler + os_signpost 녹화 아래에서 돌린다(XCTClockMetric ↔ xctrace 교차 확인).
#
# 시뮬레이터(SIMULATOR=1): 패키지 테스트 타깃을 그대로 쓴다. `RichMarkdown-Package` scheme은 `@testable`을 쓰는
#   다른 테스트 타깃까지 빌드해 Release에서 실패하므로 scripts/bench/RichMarkdownBenchmarks.xcscheme을
#   .swiftpm/xcode/xcshareddata/xcschemes/(gitignore)에 복사해 쓴다.
# 실기기: SwiftPM 테스트 타깃은 기기에서 돌 수 없다("Tool-hosted testing is unavailable on device destinations").
#   scripts/bench/ios-host/project.yml로 빈 호스트 앱 + 같은 소스의 테스트 번들 프로젝트를 슬롯에 생성해 쓴다(xcodegen 필요).
# 선택: RICHMARKDOWN_CC=<xcodebuild CC 덮어쓰기>
set -uo pipefail
cd "$(dirname "$0")/../.."

: "${DEVICE:?DEVICE가 필요하다}"
: "${OUT_DIR:?OUT_DIR가 필요하다}"
: "${SLOT_DIR:?SLOT_DIR가 필요하다}"
readonly NOTIFICATION=dev.richmarkdown.perf.tracing-started
readonly DERIVED="$SLOT_DIR/DerivedData"
LABEL="${LABEL:-$DEVICE}"
# xcodegen은 --project 대상 폴더가 없으면 임시 폴더에서 옮기다 실패한다(2026-10-15 새 슬롯에서 실측).
mkdir -p "$OUT_DIR" "$SLOT_DIR/tmp" "$SLOT_DIR/BenchHost" .swiftpm/xcode/xcshareddata/xcschemes
cp scripts/bench/RichMarkdownBenchmarks.xcscheme .swiftpm/xcode/xcshareddata/xcschemes/

extra=()
[ -n "${RICHMARKDOWN_CC:-}" ] && extra+=("CC=$RICHMARKDOWN_CC")
[ "${SIMULATOR:-0}" != 1 ] && extra+=(-allowProvisioningUpdates ${DEVELOPMENT_TEAM:+"DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"})

container=(-scheme RichMarkdownBenchmarks)
test_target=RichMarkdownBenchmarks
if [ "${SIMULATOR:-0}" != 1 ]; then
    RICHMARKDOWN_ROOT="$(pwd -P)" xcodegen generate --quiet --spec scripts/bench/ios-host/project.yml \
        --project "$SLOT_DIR/BenchHost" || { echo "xcodegen 실패"; exit 1; }
    container=(-project "$SLOT_DIR/BenchHost/RichMarkdownBenchmarkHost.xcodeproj" -scheme RichMarkdownDeviceBenchmarks)
    test_target=RichMarkdownDeviceBenchmarks
fi

run_tests() {  # <xcresult> <로그> [추가 인자...]
    local result="$1" log="$2"
    shift 2
    TMPDIR="$SLOT_DIR/tmp/" xcodebuild test "${container[@]}" -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -resultBundlePath "$result" \
        "$@" "${extra[@]}" > "$log" 2>&1
}

wait_for_line() {  # <정규식> <파일> <초>
    local i
    for ((i = 0; i < $3; i++)); do
        grep -q "$1" "$2" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# 실기기에서는 호스트 앱(RichMarkdownBenchmarkHost) 프로세스 안에서 테스트가 돈다. 가장 최근(pid 최대) 것을 고른다.
runner_process() {
    local json="$SLOT_DIR/tmp/processes-$DEVICE.json"
    xcrun devicectl device info processes --device "$DEVICE" -j "$json" >/dev/null 2>&1 || return 1
    python3 - "$json" <<'PY'
import json, sys, urllib.parse
procs = json.load(open(sys.argv[1]))["result"]["runningProcesses"]
runners = [p for p in procs if "RichMarkdownBenchmarkHost.app/" in p.get("executable", "")]
best = max(runners, key=lambda p: p["processIdentifier"])
print(best["processIdentifier"], urllib.parse.unquote(best["executable"]).rstrip("/").rsplit("/", 1)[-1])
PY
}

device_udid() {
    local json="$SLOT_DIR/tmp/device-$DEVICE.json"
    xcrun devicectl device info details --device "$DEVICE" -j "$json" >/dev/null 2>&1 || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["hardwareProperties"]["udid"])' "$json"
}

micro() {
    local stamp result
    stamp=$(date +%Y%m%d-%H%M%S)
    result="$OUT_DIR/micro-$stamp.xcresult"
    run_tests "$result" "$OUT_DIR/micro-$stamp.log"
    echo "xcodebuild rc=$? ($OUT_DIR/micro-$stamp.log)"
    python3 scripts/bench/collect.py "$OUT_DIR/micro-$stamp.log" --label "$LABEL" \
        --out "$OUT_DIR/results.json" --table | tee "$OUT_DIR/results.md"
}

cross_check() {
    local name=core.parse.50KiB.dollarOff log="$OUT_DIR/crosscheck.ui.log" trace="$OUT_DIR/crosscheck-parse50KiB.trace"
    local udid process pid
    udid=$(device_udid) || { echo "기기 UDID를 읽지 못했다"; return 1; }
    TEST_RUNNER_RICHMARKDOWN_BENCH_TRACE=1 TEST_RUNNER_RICHMARKDOWN_BENCH_ITERATIONS=50 \
        run_tests "$OUT_DIR/crosscheck.xcresult" "$log" \
        -only-testing:"$test_target/CoreBenchmarks/testParse50KiB" &
    local test_pid=$!
    wait_for_line "^PERF_READY" "$log" 600 || { echo "러너가 준비되지 않았다"; kill "$test_pid"; return 1; }
    read -r pid process <<< "$(runner_process)"
    echo "러너: $process ($pid)"
    xcrun xctrace record --device "$udid" --instrument 'Time Profiler' --instrument os_signpost \
        --time-limit 20s --no-prompt --output "$trace" --attach "$pid" > "$OUT_DIR/crosscheck.xctrace.log" 2>&1 &
    local xctrace_pid=$!
    wait_for_line "Ctrl-C to stop" "$OUT_DIR/crosscheck.xctrace.log" 90 \
        && xcrun devicectl device notification post --device "$DEVICE" --name "$NOTIFICATION" >/dev/null 2>&1
    wait "$xctrace_pid"
    wait "$test_pid"
    python3 scripts/bench/collect.py "$log" --label "$LABEL cross-check" --out "$OUT_DIR/crosscheck-results.json" --table
    python3 scripts/bench/trace_summary.py "$trace" --app "$process" --ui-log "$log" --window "$name" \
        --frame "RichMarkdownParser.parse" --signpost parse > "$OUT_DIR/crosscheck-trace.json"
    cat "$OUT_DIR/crosscheck-trace.json"
}

if [ "${CROSS_CHECK:-0}" = 1 ]; then cross_check; else micro; fi
