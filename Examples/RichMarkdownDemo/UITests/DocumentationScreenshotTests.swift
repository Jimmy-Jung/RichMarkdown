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
        captureCodeBlockExtension(app)
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
    private func captureCodeBlockExtension(_ app: XCUIApplication) {
        app.buttons["코드 블록 확장 (Mermaid · Prism)"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["코드 블록 확장"].waitForExistence(timeout: 30))

        // Mermaid는 WKWebView에서 그려진다. 렌더가 끝나면 안내 문구가 사라진다.
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60), "다이어그램 WebView가 없다")
        let loading = app.staticTexts["Mermaid 다이어그램을 그리는 중입니다."]
        if loading.exists {
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: loading)
            wait(for: [gone], timeout: 60)
        }

        // flowchart는 높이 699pt라 본문 영역(727pt)에 딱 들어간다. 언어 라벨을 본문 맨 위에
        // 세우면 헤더·복사 버튼부터 마지막 노드까지 한 화면에 담긴다.
        let top = contentTop(app)
        let mermaidLabel = app.staticTexts
            .matching(NSPredicate(format: "label == %@", "mermaid"))
            .element(boundBy: 0)
        align(app, mermaidLabel, toY: top)
        capture(named: "09-mermaid")

        // Prism이 색을 입힌 코드 블록으로 내려간다. swift 라벨을 맨 위에 세우면 swift·bash·
        // json·python 네 블록이 한 화면에 들어온다.
        let swiftCode = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "func rerank"))
            .firstMatch
        XCTAssertTrue(swiftCode.waitForExistence(timeout: 30), "Swift 코드 블록을 찾지 못했다")
        scroll(app, until: swiftCode)
        align(app, app.staticTexts["swift"].firstMatch, toY: top)
        capture(named: "10-highlight")

        app.navigationBars["코드 블록 확장"].buttons.firstMatch.tap()
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

    /// 세그먼트 컨트롤 아래, 실제 본문이 시작하는 y.
    ///
    /// 컨트롤 프레임 자체보다 조금 낮춰 잡는다 — 컨트롤을 감싼 배경이 프레임보다 아래까지
    /// 내려와 언어 라벨 윗부분을 덮는다. 더 낮추면 699pt짜리 flowchart 아래가 화면 밖으로 밀린다.
    @MainActor
    private func contentTop(_ app: XCUIApplication) -> CGFloat {
        app.segmentedControls.firstMatch.frame.maxY + 12
    }

    /// `element`의 상단이 `targetY`에 오도록 스크롤한다.
    ///
    /// `swipeUp()`은 관성 때문에 멈추는 위치를 정할 수 없어 다이어그램·코드 블록이 반쯤 잘린
    /// 채로 찍힌다. 프레임을 읽어 모자란 만큼만 끌어당기는 보정 루프를 쓴다. 실측 두 가지를
    /// 지킨다 — 드래그 끝에서 손가락을 붙잡아 fling을 죽이고(85pt 요청 → 75pt 이동),
    /// 화면 오른쪽 끝은 피한다(스크롤 인디케이터를 직접 잡아 방향이 뒤집힌다).
    @MainActor
    private func align(
        _ app: XCUIApplication,
        _ element: XCUIElement,
        toY targetY: CGFloat,
        tolerance: CGFloat = 8
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "정렬할 요소가 없다")
        for _ in 0..<8 {
            let delta = element.frame.minY - targetY
            guard abs(delta) > tolerance else { return }
            // 손가락이 처음 10pt 정도는 touch slop으로 먹힌다. 그만큼 더 끈다.
            let step = min(max(delta + (delta > 0 ? 10 : -10), -380), 380)
            let start = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: step > 0 ? 0.80 : 0.30)
            )
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: -step)),
                withVelocity: .slow,
                thenHoldForDuration: 0.5
            )
        }
        XCTAssertLessThanOrEqual(
            abs(element.frame.minY - targetY), tolerance * 2, "정렬이 수렴하지 않았다"
        )
    }

    @MainActor
    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
