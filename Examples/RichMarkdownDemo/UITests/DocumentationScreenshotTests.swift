import XCTest

/// README `## 스크린샷` 표에 넣을 이미지를 캡처한다.
///
/// 문서 갱신 때만 수동으로 돌린다 — CI에서는 환경 변수가 없어 skip된다.
/// 러너 프로세스에는 `TEST_RUNNER_` 접두사가 붙은 변수만 전달된다(접두사는 벗겨진다).
///
/// ```bash
/// TEST_RUNNER_RICHMARKDOWN_CAPTURE_DOCS=1 xcodebuild test \
///   -project RichMarkdownDemo.xcodeproj -scheme RichMarkdownDemo \
///   -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
///   -only-testing:RichMarkdownDemoUITests/DocumentationScreenshotTests \
///   -resultBundlePath /tmp/docs.xcresult
/// xcrun xcresulttool export attachments --path /tmp/docs.xcresult --output-path /tmp/shots
/// # manifest.json의 suggestedHumanReadableName으로 파일명을 되돌린 뒤
/// # sips --resampleWidth 276 으로 줄여 Docs/screenshots/에 넣는다.
/// ```
final class DocumentationScreenshotTests: XCTestCase {
    private var capturesDocumentation: Bool {
        ProcessInfo.processInfo.environment["RICHMARKDOWN_CAPTURE_DOCS"] == "1"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureReadmeScreenshots() throws {
        try XCTSkipUnless(capturesDocumentation, "문서 갱신 전용 — RICHMARKDOWN_CAPTURE_DOCS=1")

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 30))

        captureChatScreens(app)
        captureBlockEditor(app)
        // SSE 화면은 정지컷 대신 GIF를 쓴다 — scripts/capture-sse-gifs.sh 참고.
        captureAttachmentDemo(app)
    }

    // MARK: - 화면별 캡처

    @MainActor
    private func captureChatScreens(_ app: XCUIApplication) {
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AI 챗봇"].waitForExistence(timeout: 30))
        // 첫 화면(인라인 + 블록 수식)이 렌더될 때까지 기다린다.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는"))
                .firstMatch.waitForExistence(timeout: 30)
        )
        capture(named: "01-math")

        // 케이스 라벨이 보이는 시점에는 본문이 화면 아래라 한 번 더 올린다.
        scroll(app, until: app.staticTexts["헤딩 · 리스트 · 인용 · 구분선 · 링크"], extraSwipes: 1)
        capture(named: "02-markdown")

        scroll(app, until: app.staticTexts["GFM 표 · 정렬 · 인라인 콘텐츠"])
        capture(named: "03-table")

        app.navigationBars["AI 챗봇"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func captureBlockEditor(_ app: XCUIApplication) {
        app.buttons["블록 편집 (Notion 스타일)"].firstMatch.tap()
        XCTAssertTrue(app.textViews["blockDocumentTextView"].waitForExistence(timeout: 30))
        capture(named: "04-block-editor")

        app.navigationBars["블록 편집"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 30))
    }

    @MainActor
    private func captureAttachmentDemo(_ app: XCUIApplication) {
        app.buttons["수식 Attachment (읽기 전용)"].firstMatch.tap()
        let document = app.textViews["attachmentDemoTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 30))
        capture(named: "05-attachment-hand-built")

        // MarkdownStyler 모드 — 인용 바·체크박스·칩이 함께 보인다.
        // 본문이 하나의 UITextView라 개별 줄을 element로 찾을 수 없어 고정 횟수로 스크롤한다.
        app.buttons["MarkdownStyler"].firstMatch.tap()
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        for _ in 0..<4 { document.swipeUp() }
        capture(named: "06-attachment-styler")
    }

    // MARK: - 헬퍼

    /// `exists`는 화면 밖 요소도 참이다 (LazyVStack이 a11y tree에 올린다).
    /// 스크린샷은 눈에 보여야 하므로 `isHittable`을 기준으로 스크롤한다.
    @MainActor
    private func scroll(
        _ app: XCUIApplication,
        until element: XCUIElement,
        extraSwipes: Int = 0
    ) {
        for _ in 0..<25 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "스크롤 후에도 화면에 보이지 않는다")
        for _ in 0..<extraSwipes { app.swipeUp() }
    }

    @MainActor
    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
