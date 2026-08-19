import XCTest

/// UI 자동화는 XCUITest 전용이다 (Swift Testing은 UI 테스트를 지원하지 않는다).
final class SwiftLatexDemoUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChatMessagesRender() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 10))
        app.buttons["AI 챗봇"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 10))
        // 비동기 parse/render 뒤 텍스트 블록이 나타난다.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는"))
                .firstMatch.waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testHostingConfigurationCellsRender() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 10))
        app.buttons["UIKit UIHostingConfiguration"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["UIKit 셀"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
    }
}
