import XCTest

/// UI 자동화는 XCUITest 전용이다 (Swift Testing은 UI 테스트를 지원하지 않는다).
final class RichMarkdownDemoUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChatMessagesRender() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 10))
        // 비동기 parse/render 뒤 텍스트 블록이 나타난다.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는"))
                .firstMatch.waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testSwiftUITableRendersCells() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 10))

        let tableCase = app.staticTexts["GFM 표 · 정렬 · 인라인 콘텐츠"]
        for _ in 0..<20 where !tableCase.exists { app.swipeUp() }

        XCTAssertTrue(tableCase.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["항목"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["하나"].exists)
        XCTAssertTrue(app.staticTexts["완료"].exists)
    }

    @MainActor
    func testChatRenderOptionsMenuIncludesThemePresets() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
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
            app.launchArguments = ["-richmarkdownPreset", preset]
            app.launch()

            XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
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

    /// SSE 데모: 로컬 시뮬레이션이 프레임을 흘리고 도착한 조각이 실제로 렌더되며,
    /// 중지하면 누적이 멈추고 지금까지 받은 답변은 남는다.
    @MainActor
    func testSSEDemoStreamsAndStops() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["SSE 실시간 렌더링 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["SSE 실시간 렌더링"].waitForExistence(timeout: 10))

        let status = app.staticTexts["sseDemo.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "0 청크 · 0자", "시작 전에는 받은 조각이 없다")

        // 5Hz면 fixture 전체가 약 28초라, 중지 시점이 확실히 스트림 중간이다.
        app.buttons["5Hz"].tap()

        let startStop = app.buttons["sseDemo.startStop"]
        startStop.tap()

        // 누적 문자열이 자라면서 헤딩이 완성되어 렌더된다.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "정규분포"))
                .firstMatch.waitForExistence(timeout: 20),
            "도착한 markdown이 렌더되어야 한다"
        )

        startStop.tap()
        XCTAssertEqual(startStop.label, "시작", "중지하면 버튼이 시작으로 돌아온다")

        // 스트림이 아직 끝나지 않았음을 확인한다. 이게 없으면 아래 «청크가 늘지 않는다»가
        // 취소 때문인지 자연 종료 때문인지 구분되지 않는다.
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "오차함수"))
                .firstMatch.exists,
            "fixture 마지막 문단이 이미 도착했다면 중지 검증이 무의미하다"
        )

        // 중지 뒤 2초 동안 청크 수가 그대로면 스트림 Task가 실제로 취소된 것이다.
        let stopped = status.label
        let keepsGrowing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", stopped),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keepsGrowing], timeout: 2), .timedOut,
            "중지 후에도 청크가 늘면 스트림이 취소되지 않은 것이다"
        )
        XCTAssertNotEqual(stopped, "0 청크 · 0자", "중지 시점까지 받은 답변은 남는다")
    }

    /// 스트리밍 **중에** 렌더가 착지하는지 확인한다.
    ///
    /// 회귀 방지: 매 청크 상태 갱신 + `scrollTo`로 스크롤 레이아웃을 20Hz로 강제하면
    /// 메인 스레드가 포화되어 게시가 매번 stale 판정을 받고, 스트림이 끝날 때까지 화면이
    /// 원문 markdown 한 덩어리에 고착한다(실측). 그 상태에서는 표 셀이 개별 텍스트가 아니다.
    @MainActor
    func testSSEDemoRendersWhileStreaming() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["SSE 실시간 렌더링 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["SSE 실시간 렌더링"].waitForExistence(timeout: 10))

        app.buttons["5Hz"].tap()
        app.buttons["sseDemo.startStop"].tap()

        // 표가 도착하는 지점(약 500자)을 지나면 셀이 개별 텍스트로 렌더되어야 한다.
        XCTAssertTrue(
            app.staticTexts["68.27%"].waitForExistence(timeout: 40),
            "스트리밍 중에도 렌더가 착지해야 한다"
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "| 구간"))
                .firstMatch.exists,
            "표가 렌더되면 원문 파이프 표가 남아 있으면 안 된다"
        )

        app.buttons["sseDemo.startStop"].tap()
    }

    /// UIKit SSE 데모: 같은 스트림이 `RichMarkdownUIView`로 렌더된다.
    /// UIKit 렌더러 본문은 `UITextView`라 staticTexts가 아닌 textViews로 조회한다.
    @MainActor
    func testUIKitSSEDemoRendersWhileStreaming() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["SSE 실시간 렌더링 (UIKit)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["SSE 실시간 렌더링 (UIKit)"].waitForExistence(timeout: 10))

        app.buttons["5Hz"].tap()

        let startStop = app.buttons["uikitSseDemo.startStop"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 5))
        startStop.tap()

        let heading = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "정규분포", "정규분포"
        )
        XCTAssertTrue(
            app.textViews.matching(heading).firstMatch.waitForExistence(timeout: 40),
            "UIKit 렌더러로 스트리밍 마크다운이 렌더되어야 한다"
        )

        // 표가 도착하는 지점(약 500자)까지 진행을 확인한다. UIKit 표 셀의 element
        // 종류에 기대지 않도록 아무 요소나 잡는다. GIF 캡처(scripts/capture-sse-gifs.sh)도
        // 이 대기 덕에 표 렌더 장면까지 담는다.
        let tableCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "68.27%", "68.27%"))
            .firstMatch
        XCTAssertTrue(tableCell.waitForExistence(timeout: 40), "스트리밍 중 표가 렌더되어야 한다")

        startStop.tap()
        XCTAssertEqual(startStop.label, "시작", "중지하면 버튼이 시작으로 돌아온다")
        let status = app.staticTexts["uikitSseDemo.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertNotEqual(status.label, "0 청크 · 0자", "중지 시점까지 받은 답변은 남는다")
    }

    @MainActor
    func testHostingConfigurationCellsRender() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 10))
        app.buttons["UIKit UIHostingConfiguration"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["UIKit 셀"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
    }
}
