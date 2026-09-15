#!/bin/bash
# CI 테스트 파이프라인 (DEVELOPMENT.md §8, P0에서 실제 실행해 이름/옵션 고정).
#
# 확정된 사실:
# - 테스트 액션을 가진 package scheme은 `SwiftLatex-Package`다. 같은 이름의 `SwiftLatex`
#   scheme도 있지만 그쪽은 library product 빌드 전용이라 test action이 없다 (product가
#   4개로 늘어난 뒤 실측: "Scheme SwiftLatex is not currently configured for the test action").
# - Swift 6 language mode + complete concurrency는 tools 6.0 manifest가 우리 target에 적용한다.
#   전역 SWIFT_VERSION=6 / SWIFT_TREAT_WARNINGS_AS_ERRORS=YES override는 의존성(SwiftMath 등)까지
#   재컴파일 대상으로 만들므로 사용하지 않는다.
set -uo pipefail
cd "$(dirname "$0")/.."

destination='platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'
swiftlatex_results_dir=$(mktemp -d /tmp/swiftlatex-results.XXXXXX)

# 0) Foundation-only Core를 host에서 우선 검증한다.
swiftlatex_core_status=0
swift build --target SwiftLatexCore \
    > /tmp/swiftlatex-core-build.log 2>&1 || swiftlatex_core_status=$?

# 1) Core 포함 전체 unit test는 iOS Simulator의 package scheme에서 실행한다.
swiftlatex_package_status=0
xcodebuild test \
    -scheme SwiftLatex-Package \
    -destination "$destination" \
    -resultBundlePath "$swiftlatex_results_dir/package.xcresult" \
    -enableCodeCoverage YES \
    > /tmp/swiftlatex-package-tests.log 2>&1 || swiftlatex_package_status=$?

# 2) UIKit lifecycle/UI test는 demo 프로젝트의 shared scheme/test plan으로 실행한다.
swiftlatex_demo_status=0
xcodebuild test \
    -project Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj \
    -scheme SwiftLatexDemo \
    -testPlan SwiftLatexDemo \
    -destination "$destination" \
    -resultBundlePath "$swiftlatex_results_dir/demo.xcresult" \
    -enableCodeCoverage YES \
    > /tmp/swiftlatex-demo-tests.log 2>&1 || swiftlatex_demo_status=$?

# 3) Core line coverage 80% gate.
swiftlatex_coverage_status=0
xcrun xccov view --report --json \
    "$swiftlatex_results_dir/package.xcresult" \
    > "$swiftlatex_results_dir/package-coverage.json" || swiftlatex_coverage_status=$?
if [ "$swiftlatex_coverage_status" -eq 0 ]; then
    scripts/check-core-coverage.sh "$swiftlatex_results_dir/package-coverage.json" 0.80 \
        || swiftlatex_coverage_status=$?
fi

xcrun simctl shutdown all

echo "core build:   $swiftlatex_core_status"
echo "package test: $swiftlatex_package_status"
echo "demo test:    $swiftlatex_demo_status"
echo "coverage:     $swiftlatex_coverage_status"
echo "results:      $swiftlatex_results_dir"

test "$swiftlatex_core_status" -eq 0 \
    && test "$swiftlatex_package_status" -eq 0 \
    && test "$swiftlatex_demo_status" -eq 0 \
    && test "$swiftlatex_coverage_status" -eq 0
