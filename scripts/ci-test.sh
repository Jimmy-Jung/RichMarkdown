#!/bin/bash
# CI 테스트 파이프라인 (DEVELOPMENT.md §8, P0에서 실제 실행해 이름/옵션 고정).
#
# 확정된 사실:
# - 테스트 액션을 가진 package scheme은 `RichMarkdown-Package`다. 같은 이름의 `RichMarkdown`
#   scheme도 있지만 그쪽은 library product 빌드 전용이라 test action이 없다 (product가
#   4개로 늘어난 뒤 실측: "Scheme RichMarkdown is not currently configured for the test action").
# - Swift 6 language mode + complete concurrency는 tools 6.0 manifest가 우리 target에 적용한다.
#   전역 SWIFT_VERSION=6 / SWIFT_TREAT_WARNINGS_AS_ERRORS=YES override는 의존성(SwiftMath 등)까지
#   재컴파일 대상으로 만들므로 사용하지 않는다.
set -uo pipefail
cd "$(dirname "$0")/.."

destination='platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'
richmarkdown_results_dir=$(mktemp -d /tmp/richmarkdown-results.XXXXXX)

# 0) Foundation-only Core를 host에서 우선 검증한다.
richmarkdown_core_status=0
swift build --target RichMarkdownCore \
    > /tmp/richmarkdown-core-build.log 2>&1 || richmarkdown_core_status=$?

# 1) Core 포함 전체 unit test는 iOS Simulator의 package scheme에서 실행한다.
richmarkdown_package_status=0
xcodebuild test \
    -scheme RichMarkdown-Package \
    -destination "$destination" \
    -resultBundlePath "$richmarkdown_results_dir/package.xcresult" \
    -enableCodeCoverage YES \
    > /tmp/richmarkdown-package-tests.log 2>&1 || richmarkdown_package_status=$?

# 2) UIKit lifecycle/UI test는 demo 프로젝트의 shared scheme/test plan으로 실행한다.
richmarkdown_demo_status=0
xcodebuild test \
    -project Examples/RichMarkdownDemo/RichMarkdownDemo.xcodeproj \
    -scheme RichMarkdownDemo \
    -testPlan RichMarkdownDemo \
    -destination "$destination" \
    -resultBundlePath "$richmarkdown_results_dir/demo.xcresult" \
    -enableCodeCoverage YES \
    > /tmp/richmarkdown-demo-tests.log 2>&1 || richmarkdown_demo_status=$?

# 3) Core line coverage 80% gate.
richmarkdown_coverage_status=0
xcrun xccov view --report --json \
    "$richmarkdown_results_dir/package.xcresult" \
    > "$richmarkdown_results_dir/package-coverage.json" || richmarkdown_coverage_status=$?
if [ "$richmarkdown_coverage_status" -eq 0 ]; then
    scripts/check-core-coverage.sh "$richmarkdown_results_dir/package-coverage.json" 0.80 \
        || richmarkdown_coverage_status=$?
fi

xcrun simctl shutdown all

echo "core build:   $richmarkdown_core_status"
echo "package test: $richmarkdown_package_status"
echo "demo test:    $richmarkdown_demo_status"
echo "coverage:     $richmarkdown_coverage_status"
echo "results:      $richmarkdown_results_dir"

test "$richmarkdown_core_status" -eq 0 \
    && test "$richmarkdown_package_status" -eq 0 \
    && test "$richmarkdown_demo_status" -eq 0 \
    && test "$richmarkdown_coverage_status" -eq 0
