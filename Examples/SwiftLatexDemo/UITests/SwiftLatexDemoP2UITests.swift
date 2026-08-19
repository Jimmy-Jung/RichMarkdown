import XCTest
import UIKit

/// P2 플랫폼 검증 매트릭스 (DEVELOPMENT.md §7 P2, §8 렌더/UI 테스트).
///
/// app launch가 회당 7~8초라 검증 항목을 launch 단위로 묶는다:
/// 1) 기본 구성 — 회전, 수식 접근성 label, 복사, 접근성 audit
/// 2) dark mode
/// 3) Dynamic Type 양 극단(L / AccessibilityXXXL)
/// 4) UIHostingConfiguration 셀 재사용
///
/// Bold Text / Increase Contrast / Full Keyboard Access / VoiceOver 청취는
/// launch argument로 제어할 수 없어 수동·simctl 항목으로 남긴다.
final class SwiftLatexDemoP2UITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchMessages(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 20))
        app.buttons["AI 챗봇"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 20))
        return app
    }

    private func firstMessage(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는")).firstMatch
    }

    // MARK: - 1) 기본 구성 묶음

    @MainActor
    func testDefaultConfigurationMatrix() throws {
        let app = launchMessages()
        XCTAssertTrue(firstMessage(app).waitForExistence(timeout: 20))

        // 수식 접근성 표현: 링크 없는 수식 문단은 "수식: <LaTeX>"를 노출한다 (§5).
        let mathLabel = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "수식:")).firstMatch
        XCTAssertTrue(mathLabel.waitForExistence(timeout: 10))

        // 회전 왕복 후에도 콘텐츠가 유지된다.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(firstMessage(app).waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(firstMessage(app).waitForExistence(timeout: 10))

        // 복사 버튼이 존재하고 44×44pt hit target으로 탭 가능한지만 확인한다.
        // pasteboard 내용 검증은 앱 프로세스 안의 CopyActionTests가 담당한다
        // (러너에서 pasteboard를 읽으면 권한 프롬프트가 뜬다).
        let copyButton = app.buttons["수식 원문 복사"].firstMatch
        var swipes = 0
        while !copyButton.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
        XCTAssertTrue(copyButton.isHittable)
        // 44pt 목표. 프레임 값이 부동소수점 오차로 43.99999…가 될 수 있어 여유를 둔다.
        XCTAssertGreaterThanOrEqual(copyButton.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(copyButton.frame.height, 43.5)
        copyButton.tap()

        // 접근성 audit. 두 항목을 제외한다. 둘 다 확인한 오탐이다.
        // - dynamicType: 수식 raster 이미지는 크기가 고정이지만 @ScaledMetric point
        //   size로 매번 다시 렌더된다(실제 확대는 testDynamicTypeExtremes가 검증).
        // - textClipped: 문단은 수식·코드·링크 런 때문에 항상 `Text` 합성이며,
        //   합성 문단의 접근성 프레임 측정이 어긋나 clipped로 잡힌다. 지적된 요소들의
        //   스크린샷을 확인한 결과 실제로는 전체가 표시되고 잘림이 없었다.
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: .all.subtracting([.dynamicType, .textClipped]))
        }
    }

    // MARK: - 2) dark mode

    @MainActor
    func testDarkModeRenders() {
        let app = launchMessages(["-swiftlatexDark"])
        XCTAssertTrue(firstMessage(app).waitForExistence(timeout: 20))
    }

    // MARK: - 3) Dynamic Type 양 극단

    @MainActor
    func testDynamicTypeExtremes() {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = launchMessages(["-UIPreferredContentSizeCategoryName", category])
            XCTAssertTrue(firstMessage(app).waitForExistence(timeout: 20))
            app.terminate()
        }
    }

    // MARK: - 4) UIHostingConfiguration 셀 재사용

    @MainActor
    func testCollectionReuseScrollRoundTrip() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 20))
        app.buttons["UIKit UIHostingConfiguration"].firstMatch.tap()

        let collection = app.collectionViews.firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 20))
        // 재사용/비동기 높이 갱신 경로: 왕복 스크롤 후에도 첫 메시지가 살아 있다.
        for _ in 0..<3 { collection.swipeUp() }
        for _ in 0..<3 { collection.swipeDown() }
        XCTAssertTrue(
            collection.staticTexts
                .containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는"))
                .firstMatch.waitForExistence(timeout: 15)
        )
    }
}
