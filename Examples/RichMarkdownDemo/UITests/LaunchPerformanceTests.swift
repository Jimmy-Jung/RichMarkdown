// Author: JunyoungJung
// Date: 2026-10-14

import XCTest

/// 런치 성능. 데모 test plan(CI)에서는 건너뛰고 `TEST_RUNNER_RICHMARKDOWN_PERF=1`일 때만 돈다.
///
/// - 콜드 런치: `XCTApplicationLaunchMetric` 5회. `launch()`가 이전 프로세스를 끝내므로 매 반복 새 프로세스다
///   (dyld·페이지 캐시는 데워진 상태).
/// - 첫 챗 화면: 앱은 "첫 챗 화면 표시" signpost를 내지 않는다(라이브러리 signpost는 parse·raster·rebuild뿐).
///   그래서 `XCTClockMetric`으로 launch → 챗 진입 탭 → 첫 답변 텍스트 등장까지를 잰다. XCUITest의 유휴 대기와
///   접근성 조회 시간이 포함된 상한값이다.
final class LaunchPerformanceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        try PerfHarness.skipUnlessEnabled()
    }

    @MainActor
    func testColdLaunch() {
        measure(metrics: [XCTApplicationLaunchMetric()], options: Self.fiveIterations) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testLaunchToFirstSwiftUIChatBubble() {
        let app = XCUIApplication()
        measure(metrics: [XCTClockMetric()], options: Self.fiveIterations) {
            app.launch()
            app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
            XCTAssertTrue(PerfHarness.firstSwiftUIBubble(app).waitForExistence(timeout: 30))
        }
    }

    private static var fiveIterations: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }
}
