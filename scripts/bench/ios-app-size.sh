#!/bin/bash
# Author: JunyoungJung
# Date: 2026-10-14
#
# 데모 앱 크기: Release archive(링크 맵 포함) → App Thinning export → 모듈별 바이너리·리소스 번들 크기.
#
#   OUT_DIR=<결과> SLOT_DIR=<빌드 슬롯> DEVELOPMENT_TEAM=<팀> scripts/bench/ios-app-size.sh
#
# archive는 xctrace 시나리오와 동시에 돌 수 있도록 별도 DerivedData(`$SLOT_DIR/DerivedData-archive`)를 쓰고,
# 패키지 체크아웃은 `$SLOT_DIR/DerivedData/SourcePackages`를 재사용한다. 선택: RICHMARKDOWN_CC
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${OUT_DIR:?}" "${SLOT_DIR:?}"
archive="$OUT_DIR/RichMarkdownDemo.xcarchive"
linkmap="$OUT_DIR/RichMarkdownDemo-linkmap.txt"
mkdir -p "$OUT_DIR" "$SLOT_DIR/tmp"
extra=()
[ -n "${RICHMARKDOWN_CC:-}" ] && extra+=("CC=$RICHMARKDOWN_CC")

TMPDIR="$SLOT_DIR/tmp/" xcodebuild archive \
    -project Examples/RichMarkdownDemo/RichMarkdownDemo.xcodeproj -scheme RichMarkdownDemo -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -derivedDataPath "$SLOT_DIR/DerivedData-archive" -clonedSourcePackagesDirPath "$SLOT_DIR/DerivedData/SourcePackages" \
    -allowProvisioningUpdates ${DEVELOPMENT_TEAM:+"DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"} "${extra[@]}" \
    "OTHER_LDFLAGS=\$(inherited) -Xlinker -map -Xlinker $linkmap" > "$OUT_DIR/archive.log" 2>&1 \
    || { echo "archive 실패: $OUT_DIR/archive.log"; exit 1; }

# export 서명이 실패하면 archive 안의 .app(비압축)만 보고한다.
TMPDIR="$SLOT_DIR/tmp/" xcodebuild -exportArchive -archivePath "$archive" -exportPath "$OUT_DIR/export" \
    -exportOptionsPlist scripts/bench/ExportOptions-thinning.plist \
    -allowProvisioningUpdates ${DEVELOPMENT_TEAM:+"DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"} > "$OUT_DIR/export.log" 2>&1 \
    && grep -E "^Variant|App size" "$OUT_DIR/export/App Thinning Size Report.txt" | sort -u \
    || echo "export 실패 — archive의 .app 비압축 크기만 아래에 있다: $OUT_DIR/export.log"

app="$archive/Products/Applications/RichMarkdownDemo.app"
echo "## .app 구성 (비압축 KiB, du)"
du -sk "$app" "$app"/* | sed "s#$app/##"
LC_ALL=C python3 scripts/bench/linkmap_summary.py "$linkmap" --json "$OUT_DIR/linkmap-summary.json"
