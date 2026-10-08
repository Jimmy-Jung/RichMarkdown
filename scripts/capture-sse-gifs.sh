#!/bin/bash
# README용 데모 GIF 캡처.
#   sse(기본)     → Docs/screenshots/07-sse-swiftui.gif, 08-sse-uikit.gif
#   block-editor → Docs/screenshots/13-block-editor.gif
#
# 사용법: scripts/capture-sse-gifs.sh [sse|block-editor] [simulator-udid]
# 요구: ffmpeg (brew install ffmpeg), python3, iPhone 16 Pro / iOS 18.6 시뮬레이터.
#
# 원리: 촬영 모드 UI 테스트가 남긴 스크린샷 첨부(sse-frame-*, block-editor-frame-*)를
# xcresult에서 추출하고, 실제 촬영 간격을 유지한 원본 해상도 4fps GIF로 합친다.
# block-editor는 UI 동작 대기로 멈춘 간격만 프레임당 0.5초로 줄인다.
# CoreSimulator의 외장 파일 저장 권한에 의존하지 않고 XCTest 첨부를 사용한다.
set -euo pipefail
cd "$(dirname "$0")/.."

target="sse"
case "${1:-}" in
    sse|block-editor) target="$1"; shift ;;
esac

volume="/Volumes/990EVO-1TB"
diskutil info -plist "$volume" | python3 -c '
import plistlib, sys
info = plistlib.loads(sys.stdin.buffer.read())
expected = {"MountPoint": sys.argv[1], "VolumeUUID": "85D9ECCC-1754-48CD-856D-C41DC3D56220",
            "Internal": False, "WritableVolume": True}
if any(type(info.get(key)) is not type(value) or info.get(key) != value
       for key, value in expected.items()):
    sys.exit("외장 SSD 확인 실패: 빌드를 중단한다")
' "$volume"

root="$(pwd -P)"
key="$(basename "$root")-$(printf %s "$root" | shasum -a 256 | cut -c1-12)"
agent_build_dir="$volume/Developer/AgentBuilds/$key"
derived_data="$HOME/Library/Developer/Xcode/DerivedData"
test -L "$derived_data" && test -d "$derived_data" && test -w "$derived_data" \
    || { echo "기존 외장 DerivedData 연결을 사용할 수 없다: $derived_data"; exit 1; }
python3 - "$volume" "$agent_build_dir" "$agent_build_dir/tmp" "$derived_data" <<'PY'
import os, sys
for path in sys.argv[2:]:
    if not os.path.realpath(path).startswith(sys.argv[1] + os.sep):
        sys.exit("외장 볼륨 밖의 작업 경로: " + path)
PY
mkdir -p "$agent_build_dir/tmp"
work=$(mktemp -d "$agent_build_dir/$target-gifs.XXXXXX")
echo "작업 디렉터리: $work"

runner=""
publishing=()
cleanup() {
    if [ -n "$runner" ]; then
        kill "$runner" 2>/dev/null || true
        wait "$runner" 2>/dev/null || true
    fi
    for path in ${publishing[@]+"${publishing[@]}"}; do
        rm -f "$path"
    done
    xcrun simctl shutdown all
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_xcodebuild() {
    local status=0
    pgrep -lx xcodebuild || status=$?
    echo "pgrep exit=$status"
    test "$status" -eq 1 \
        || { echo "다른 Xcode 빌드가 실행 중이거나 프로세스 확인에 실패했다"; return 1; }
}

udid="${1:-$(xcrun simctl list devices "iOS 18.6" \
    | grep "iPhone 16 Pro (" | grep -v Max | grep -oE '[0-9A-F-]{36}' | head -1)}"
test -n "$udid" || { echo "iPhone 16 Pro (iOS 18.6) 시뮬레이터를 찾지 못했다"; exit 1; }
xcrun simctl bootstatus "$udid" -b > /dev/null

echo "build-for-testing…"
check_xcodebuild
build_log="$agent_build_dir/$target-build.log"
TMPDIR="$agent_build_dir/tmp/" xcodebuild build-for-testing \
    -project Examples/RichMarkdownDemo/RichMarkdownDemo.xcodeproj \
    -scheme RichMarkdownDemo \
    -destination "platform=iOS Simulator,id=$udid" \
    > "$build_log" 2>&1 \
    || { echo "build-for-testing 실패 — 로그: $build_log"; exit 1; }

capture() {
    local test_name="$1"
    local gif_name="$2"
    local frame_prefix="$3"
    # 프레임 사이 최대 간격(초). 생략하면 촬영 간격을 그대로 쓴다.
    local max_gap="${4:-inf}"
    local frames="$work/$gif_name"
    local log="$agent_build_dir/$gif_name.log"
    local export_log="$agent_build_dir/$gif_name-export.log"
    mkdir -p "$frames"

    check_xcodebuild
    TEST_RUNNER_RICHMARKDOWN_CAPTURE_GIFS=1 TMPDIR="$agent_build_dir/tmp/" \
        xcodebuild test-without-building \
        -project Examples/RichMarkdownDemo/RichMarkdownDemo.xcodeproj \
        -scheme RichMarkdownDemo \
        -destination "platform=iOS Simulator,id=$udid" \
        -parallel-testing-enabled NO \
        -resultBundlePath "$work/$gif_name.xcresult" \
        -only-testing:"RichMarkdownDemoUITests/$test_name" \
        > "$log" 2>&1 &
    runner=$!

    local status=0
    wait "$runner" || status=$?
    runner=""
    if [ "$status" -ne 0 ]; then
        echo "$test_name 실패 — 로그: $log"
        exit 1
    fi

    xcrun xcresulttool export attachments --path "$work/$gif_name.xcresult" \
        --output-path "$frames" > "$export_log" 2>&1 \
        || { echo "스크린샷 첨부 추출 실패 — 로그: $export_log"; exit 1; }
    local dimensions
    dimensions=$(python3 - "$frames" "$frame_prefix" "$max_gap" <<'PY'
import json, math, struct, sys
from pathlib import Path
folder = Path(sys.argv[1])
with (folder / "manifest.json").open() as file:
    manifest = json.load(file)
frames = []
for test in manifest:
    for attachment in test["attachments"]:
        if not attachment["suggestedHumanReadableName"].startswith(sys.argv[2]):
            continue
        name = attachment["exportedFileName"]
        if Path(name).suffix.lower() != ".png":
            continue
        if Path(name).name != name:
            sys.exit("첨부 파일 경로가 프레임 폴더를 벗어난다")
        timestamp = attachment.get("timestamp")
        if not isinstance(timestamp, (int, float)) or not math.isfinite(timestamp):
            sys.exit("촬영 timestamp가 없거나 유효하지 않다")
        frames.append((timestamp, name))
frames.sort()
if len(frames) < 2:
    sys.exit(sys.argv[2] + "* PNG 첨부가 2장 이상 필요하다")
dimensions = None
for _, name in frames:
    with (folder / name).open("rb") as file:
        header = file.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("PNG 파일 형식 오류: " + name)
    size = struct.unpack(">II", header[16:24])
    if min(size) < 1000 or (dimensions is not None and size != dimensions):
        sys.exit("프레임은 동일한 원본 고해상도여야 한다: " + name)
    dimensions = size
with (folder / "frames.concat").open("w") as file:
    for index, (timestamp, name) in enumerate(frames):
        duration = frames[index + 1][0] - timestamp if index + 1 < len(frames) else 1.0
        if duration <= 0:
            sys.exit("촬영 timestamp가 증가하지 않는다")
        if index + 1 < len(frames):
            duration = min(duration, float(sys.argv[3]))
        escaped = name.replace("'", "'\\''")
        file.write(f"file '{escaped}'\nduration {duration:.6f}\n")
    file.write(f"file '{escaped}'\n")
print(f"{dimensions[0]}x{dimensions[1]}")
PY
    )
    local staged_gif="$work/$gif_name.gif"
    ffmpeg -v error -y -f concat -safe 0 -i "$frames/frames.concat" \
        -filter_complex "[0:v]fps=4,split[a][b];[a]palettegen=reserve_transparent=0[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
        "$staged_gif"
    # 축소 없이 원본 픽셀 크기를 유지한 GIF만 기존 이미지와 교체한다.
    python3 - "$staged_gif" "$dimensions" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as file:
    gif = file.read(10)
if len(gif) != 10 or gif[:6] not in (b"GIF87a", b"GIF89a"):
    sys.exit("GIF 파일 형식 오류")
if struct.unpack("<HH", gif[6:10]) != tuple(map(int, sys.argv[2].split("x"))):
    sys.exit("GIF 해상도가 원본과 다르다")
PY
}

if [ "$target" = "block-editor" ]; then
    gif_names=(13-block-editor)
    # UI 동작 대기(탭·입력 동기화) 동안 멈춘 화면은 0.5초로 줄인다.
    capture BlockEditorDemoUITests/testBlockEditorGifFrames 13-block-editor block-editor-frame- 0.5
else
    gif_names=(07-sse-swiftui 08-sse-uikit)
    capture RichMarkdownDemoUITests/testSSEDemoRendersWhileStreaming 07-sse-swiftui sse-frame-
    capture RichMarkdownDemoUITests/testUIKitSSEDemoRendersWhileStreaming 08-sse-uikit sse-frame-
fi

# 대상의 모든 테스트와 GIF 검증이 성공한 뒤에 README 자산을 교체한다.
for gif_name in "${gif_names[@]}"; do
    publishing+=("$(mktemp "Docs/screenshots/.$gif_name.XXXXXX")")
    cp "$work/$gif_name.gif" "${publishing[${#publishing[@]} - 1]}"
done
chmod 644 "${publishing[@]}"
for index in "${!gif_names[@]}"; do
    mv -f "${publishing[$index]}" "Docs/screenshots/${gif_names[$index]}.gif"
done
for gif_name in "${gif_names[@]}"; do
    echo "saved Docs/screenshots/$gif_name.gif ($(du -h "Docs/screenshots/$gif_name.gif" | cut -f1))"
done

echo "프레임 원본과 촬영 timestamp: $work"
