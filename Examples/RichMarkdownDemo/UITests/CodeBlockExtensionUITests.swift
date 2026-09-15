import XCTest

/// 코드 블록 확장의 실제 화면 동작.
///
/// 단위 테스트는 `MermaidWebRenderer`를 직접 만든 `UIWindow`에 붙여 검증한다. 이 테스트는
/// **실제 앱 경로**를 본다 — Markdown 렌더러 → 코드 블록 → 다이어그램 뷰가 스크롤 뷰 안에서
/// window에 들어가 렌더까지 끝나는지. WKWebView가 window 밖에서 로드되지 않는 문제와
/// 호스트가 다이어그램 높이를 못 따라가 뷰가 접히는 문제는 여기서만 드러난다.
final class CodeBlockExtensionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchCodeBlockScreen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 20))
        app.buttons["코드 블록 확장 (Mermaid · Prism)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["코드 블록 확장"].waitForExistence(timeout: 20))
        return app
    }

    /// Mermaid 원문이 텍스트로 보이면 다이어그램이 아니라 코드 블록으로 표시된 것이다.
    private func mermaidSourceText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "flowchart TD"))
            .firstMatch
    }

    private func failureText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label BEGINSWITH %@", "Mermaid 다이어그램을 표시하지 못했습니다"))
            .firstMatch
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 다이어그램이 실제로 그려졌는지. 화면 캡처를 결과 번들에 남겨 눈으로도 확인한다.
    private func assertDiagramRendered(
        _ app: XCUIApplication,
        named name: String,
        timeout: TimeInterval = 60
    ) {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: timeout), "다이어그램 WebView가 화면에 없다")

        // 렌더 전에는 안내 문구가 뜬다. 끝나면 사라지고, 실패하면 오류 문구로 바뀐다.
        let loading = app.staticTexts["Mermaid 다이어그램을 그리는 중입니다."]
        if loading.exists {
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            wait(for: [gone], timeout: timeout)
        }

        attachScreenshot(app, named: name)

        XCTAssertFalse(failureText(app).exists, "다이어그램이 오류 fallback으로 떨어졌다")
        XCTAssertFalse(mermaidSourceText(app).exists, "Mermaid 원문이 코드 블록 그대로 보인다")
        // 접힌 WebView는 "존재"만 하고 아무것도 보여 주지 않는다. 높이로 걸러 낸다.
        XCTAssertGreaterThan(webView.frame.height, 40, "다이어그램 높이가 확정되지 않았다")
    }

    @MainActor
    func testSwiftUIRendererDrawsMermaidDiagram() throws {
        let app = launchCodeBlockScreen()
        assertDiagramRendered(app, named: "swiftui-mermaid")

        // 다이어그램으로 바뀐 블록에서도 원문 복사 버튼은 남아 있어야 한다.
        XCTAssertTrue(app.buttons["코드 복사"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testUIKitRendererDrawsMermaidDiagram() throws {
        let app = launchCodeBlockScreen()
        app.buttons["UIKit"].firstMatch.tap()
        assertDiagramRendered(app, named: "uikit-mermaid")
    }

    /// 확장을 끄면 라이브러리 기본 동작(원문 코드 블록)으로 돌아간다.
    @MainActor
    func testTurningDiagramsOffShowsMermaidSource() throws {
        let app = launchCodeBlockScreen()
        assertDiagramRendered(app, named: "before-toggle-off")

        app.buttons["설정"].firstMatch.tap()
        // SwiftUI `Menu` 안의 `Toggle`은 스위치가 아니라 메뉴 버튼으로 노출된다.
        let toggle = app.buttons["Mermaid 다이어그램"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Mermaid 토글 메뉴 항목이 없다")
        toggle.tap()

        XCTAssertTrue(
            mermaidSourceText(app).waitForExistence(timeout: 20),
            "다이어그램을 끄면 Mermaid 원문이 보여야 한다"
        )
        attachScreenshot(app, named: "after-toggle-off")
    }

    /// 하이라이팅이 걸린 코드 블록이 실제로 그려지는지. 색 자체는 단위 테스트가 확인하고,
    /// 여기서는 원문이 손상 없이 화면에 남는지와 화면 캡처를 남긴다.
    @MainActor
    func testHighlightedCodeBlocksKeepTheirSource() throws {
        let app = launchCodeBlockScreen()
        assertDiagramRendered(app, named: "highlight-before-scroll")

        let swiftCode = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "func rerank"))
            .firstMatch
        XCTAssertTrue(swiftCode.waitForExistence(timeout: 20), "Swift 코드 블록을 찾지 못했다")

        // `exists`는 화면 밖 요소에도 true다. 실제로 보이는 상태까지 스크롤한다.
        for _ in 0..<12 where !swiftCode.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(swiftCode.isHittable, "Swift 코드 블록까지 스크롤하지 못했다")
        attachScreenshot(app, named: "highlighted-code")
    }
}
