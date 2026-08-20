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
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 10))
        // 비동기 parse/render 뒤 텍스트 블록이 나타난다.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는"))
                .firstMatch.waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testChatRenderOptionsMenuIncludesThemePresets() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 10))
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 10))

        let renderOptions = app.buttons["렌더 옵션"]
        XCTAssertTrue(renderOptions.waitForExistence(timeout: 10))
        renderOptions.tap()
        XCTAssertTrue(app.buttons["큰 글자"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Serif"].exists)
        XCTAssertTrue(app.buttons["색 강조"].exists)
    }

    /// UIKit 네이티브 렌더러 화면. 재사용 셀에서 렌더가 유지되는지와 테마 프리셋별
    /// 렌더를 스크린샷으로 남긴다.
    @MainActor
    func testUIKitNativeCellsRender() {
        let bodyPredicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "원의 넓이는", "원의 넓이는"
        )

        for preset in ["기본", "Serif"] {
            let app = XCUIApplication()
            app.launchArguments = ["-swiftlatexPreset", preset]
            app.launch()

            XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 10))
            app.buttons["AI 챗봇 (UIKit)"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["UIKit 네이티브"].waitForExistence(timeout: 10))

        let list = app.collectionViews["uikitChatList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertNotEqual(list.value as? String, "preparing")
        XCTAssertTrue(
            app.textViews.matching(bodyPredicate).firstMatch.waitForExistence(timeout: 10),
                "\(preset): 첫 답변이 렌더되어야 한다"
            )

            let firstShot = XCTAttachment(screenshot: app.screenshot())
            firstShot.name = "uikit-native-\(preset)-top"
            firstShot.lifetime = .keepAlways
            add(firstShot)

            // 셀 재사용: 왕복 스크롤 뒤에도 첫 답변이 살아 있어야 한다.
            for _ in 0..<4 { list.swipeUp() }
            let bottomShot = XCTAttachment(screenshot: app.screenshot())
            bottomShot.name = "uikit-native-\(preset)-bottom"
            bottomShot.lifetime = .keepAlways
            add(bottomShot)

            // 셀 높이가 hydration 뒤 재측정되므로 스와이프 횟수를 고정하지 않는다.
            var returnedToTop = false
            for _ in 0..<20 {
                if app.textViews.matching(bodyPredicate).firstMatch.exists {
                    returnedToTop = true
                    break
                }
                list.swipeDown()
            }
            XCTAssertTrue(returnedToTop, "\(preset): 재사용 후에도 첫 답변이 남아야 한다")

            // 같은 메시지로 재사용된 셀이 빈 버블이 되던 회귀를 잡는다.
            let midPredicate = NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", "구분선 아래", "구분선 아래"
            )
            var foundMid = false
            for _ in 0..<20 {
                if app.textViews.matching(midPredicate).firstMatch.exists {
                    foundMid = true
                    break
                }
                list.swipeUp()
            }
            XCTAssertTrue(foundMid, "\(preset): 중간 답변이 재사용 후에도 렌더되어야 한다")

            // 같은 완성 메시지를 두 번째로 다시 붙이는 경로도 비어 있지 않아야 한다.
            // 고정 횟수 대신 실제 첫 답변의 재등장으로 완료를 판정한다.
            var returnedToTopAgain = false
            for _ in 0..<20 {
                if app.textViews.matching(bodyPredicate).firstMatch.exists {
                    returnedToTopAgain = true
                    break
                }
                list.swipeDown()
            }
            XCTAssertTrue(returnedToTopAgain, "\(preset): 두 번째 재방문에도 첫 답변이 유지되어야 한다")

            app.terminate()
        }
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
