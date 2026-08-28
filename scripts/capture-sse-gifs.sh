#!/bin/bash
# README용 SSE 데모 GIF 캡처 (Docs/screenshots/07-sse-swiftui.gif, 08-sse-uikit.gif).
#
# 사용법: scripts/capture-sse-gifs.sh [simulator-udid]
# 요구: ffmpeg (brew install ffmpeg), iPhone 16 Pro / iOS 18.6 시뮬레이터.
#
# 원리: 스트리밍 UI 테스트(5Hz 로컬 시뮬레이션)가 화면을 구동하는 동안 0.25초 간격으로
# `simctl screenshot`을 모아 4fps GIF로 합친다.
# - `simctl recordVideo`는 테스트 러너의 앱 재설치 시점에 세션이 조용히 끊긴다(실측) —
#   쓰지 않는다.
# - 빌드가 프레임에 섞이지 않도록 `build-for-testing`을 먼저 하고, 각 캡처는 테스트
#   시작 로그를 확인한 뒤에야 스크린샷 루프를 돌린다.
set -euo pipefail
cd "$(dirname "$0")/.."

udid="${1:-$(xcrun simctl list devices "iOS 18.6" \
    | grep "iPhone 16 Pro (" | grep -v Max | grep -oE '[0-9A-F-]{36}' | head -1)}"
test -n "$udid" || { echo "iPhone 16 Pro (iOS 18.6) 시뮬레이터를 찾지 못했다"; exit 1; }
xcrun simctl bootstatus "$udid" -b > /dev/null

work=$(mktemp -d /tmp/sse-gifs.XXXXXX)
echo "작업 디렉터리: $work"

echo "build-for-testing…"
xcodebuild build-for-testing \
    -project Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj \
    -scheme SwiftLatexDemo \
    -destination "platform=iOS Simulator,id=$udid" \
    > "$work/build.log" 2>&1

capture() {
    local test_name="$1"
    local gif_name="$2"
    local frames="$work/$gif_name"
    local log="$work/$gif_name.log"
    mkdir -p "$frames"

    xcodebuild test-without-building \
        -project Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj \
        -scheme SwiftLatexDemo \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:"SwiftLatexDemoUITests/SwiftLatexDemoUITests/$test_name" \
        > "$log" 2>&1 &
    local runner=$!

    # 러너 부팅을 프레임에 담지 않는다 — 테스트 케이스 시작 로그를 기다린다.
    until grep -q "Test Case .*$test_name.* started" "$log" 2>/dev/null; do
        kill -0 "$runner" 2>/dev/null || { echo "$test_name 러너 조기 종료 — $log"; exit 1; }
        sleep 0.2
    done

    ( i=0; while true; do
        xcrun simctl io "$udid" screenshot --type=png \
            "$frames/f_$(printf %04d "$i").png" > /dev/null 2>&1 || true
        i=$((i + 1)); sleep 0.25
      done ) &
    local snap=$!

    local status=0
    wait "$runner" || status=$?
    kill "$snap" 2>/dev/null || true
    if [ "$status" -ne 0 ]; then
        echo "$test_name 실패 — 로그: $log"
        exit 1
    fi

    # 앞쪽 앱 런치·화면 전환 프레임을 잘라낸다 (~2.5초).
    ffmpeg -v error -y -framerate 4 -pattern_type glob -i "$frames/f_*.png" \
        -filter_complex "[0:v]select=gte(n\,10),setpts=N/4/TB,scale=276:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
        "Docs/screenshots/$gif_name.gif"
    echo "saved Docs/screenshots/$gif_name.gif ($(du -h "Docs/screenshots/$gif_name.gif" | cut -f1))"
}

capture testSSEDemoRendersWhileStreaming 07-sse-swiftui
capture testUIKitSSEDemoRendersWhileStreaming 08-sse-uikit

echo "프레임 원본: $work (트림을 바꾸려면 select=gte(n\\,N)을 조정해 재실행)"
