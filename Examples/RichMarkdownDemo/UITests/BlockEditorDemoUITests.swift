// Created by JunyoungJung on 2026-08-21.

import XCTest

final class BlockEditorDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDocumentUsesOneContinuousTextViewWithoutDragHandles() {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]

        XCTAssertTrue(document.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textViews.matching(identifier: "blockDocumentTextView").count, 1)
        XCTAssertTrue((document.value as? String)?.contains("회의 노트") == true)
        XCTAssertTrue((document.value as? String)?.contains("할 일 둘") == true)
        XCTAssertFalse(app.otherElements["blockDragHandle"].exists)

        document.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["blockDragHandle"].exists)
    }

    @MainActor
    func testSelectAllCopiesReplacesAndRestoresTheWholeDocument() throws {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        let original = try XCTUnwrap(document.value as? String)

        document.tap()
        try selectAll(in: document, app: app)
        try tapEditMenuItem(["Copy", "복사"], in: app)
        document.typeText("새 문서")
        XCTAssertTrue(
            waitForValue("새 문서\n", in: document),
            "실제 문서: \(String(describing: document.value))"
        )

        try selectAll(in: document, app: app)
        try tapEditMenuItem(["Paste", "붙여넣기"], in: app)
        XCTAssertTrue(waitForValue(original, in: document))
    }

    @MainActor
    func testEnterUpdatesTheContinuousDocument() throws {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))

        document.tap()
        try selectAll(in: document, app: app)
        document.typeText("첫 줄\n둘째")

        XCTAssertTrue(
            waitForValue("첫 줄\n둘째\n", in: document),
            "실제 문서: \(String(describing: document.value))"
        )
        XCTAssertEqual(app.textViews.matching(identifier: "blockDocumentTextView").count, 1)
    }

    @MainActor
    func testKeyboardToolbarAddOpensBlockMenuAndInsertsSelectedKind() throws {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        let original = try XCTUnwrap(document.value as? String)
        document.tap()

        let addButton = app.buttons["blockToolbar.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let bulletedList = app.buttons["글머리 기호 목록"]
        XCTAssertTrue(bulletedList.waitForExistence(timeout: 5))
        bulletedList.tap()
        XCTAssertTrue(waitForValueDifferent(from: original, in: document))

        let undoButton = app.buttons["blockToolbar.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.isEnabled)
        undoButton.tap()
        XCTAssertTrue(waitForValue(original, in: document))
    }

    @MainActor
    func testTopBarMenuIncludesRenderOptions() {
        let app = launchBlockEditor()
        XCTAssertTrue(app.textViews["blockDocumentTextView"].waitForExistence(timeout: 15))

        let optionsButton = app.buttons["blockEditor.options"]
        XCTAssertTrue(optionsButton.waitForExistence(timeout: 5))
        optionsButton.tap()

        XCTAssertTrue(app.buttons["$ 수식 파싱 (opt-in)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["기본"].exists)
        XCTAssertTrue(app.buttons["큰 글자"].exists)
        XCTAssertTrue(app.buttons["Serif"].exists)
        XCTAssertTrue(app.buttons["색 강조"].exists)
    }

    @MainActor
    func testKeyboardToolbarKeepsFloatingSurfaceAndAccessibleHitTargets() {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        document.tap()

        let toolbar = app.otherElements["blockKeyboardToolbar"]
        let addButton = app.buttons["blockToolbar.add"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(toolbar.frame.height, 63.5)
        XCTAssertGreaterThanOrEqual(addButton.frame.minY - toolbar.frame.minY, 9.5)

        assertToolbarButtons([
            "blockToolbar.add",
            "blockToolbar.format",
            "blockToolbar.outdent",
            "blockToolbar.indent",
        ], in: app)

        XCTAssertFalse(app.buttons["blockToolbar.bold"].exists)
        app.buttons["blockToolbar.format"].tap()
        assertToolbarButtons([
            "blockToolbar.bold",
            "blockToolbar.italic",
            "blockToolbar.strike",
            "blockToolbar.code",
        ], in: app)

        let undoButton = app.buttons["blockToolbar.undo"]
        XCTAssertFalse(undoButton.isEnabled)
        let indentButton = app.buttons["blockToolbar.indent"]
        XCTAssertTrue(indentButton.waitForExistence(timeout: 5))
        indentButton.tap()
        XCTAssertTrue(waitForEnabled(undoButton))

        let toolbarScroll = app.scrollViews["blockKeyboardToolbarScroll"]
        XCTAssertTrue(toolbarScroll.waitForExistence(timeout: 5))
        toolbarScroll.swipeLeft()
        assertToolbarButtons([
            "blockToolbar.indent",
            "blockToolbar.undo",
            "blockToolbar.redo",
            "blockToolbar.more",
            "blockToolbar.done",
        ], in: app)

        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "block-editor-liquid-glass-toolbar"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testEditorAccessibilityLabelAndAudit() throws {
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        XCTAssertFalse(document.label.isEmpty)
        XCTAssertFalse(app.otherElements["blockDragHandle"].exists)
        document.tap()

        let toolbar = app.otherElements["blockKeyboardToolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))

        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(
                for: .all.subtracting([
                    .dynamicType,
                    .textClipped,
                    .sufficientElementDescription,
                ])
            ) { issue in
                let element = issue.element
                if issue.auditType == .contrast,
                   let element,
                   !element.isHittable,
                   element.frame.intersects(toolbar.frame) {
                    return true
                }

                let details = [
                    issue.compactDescription,
                    issue.detailedDescription,
                    "element: \(element?.debugDescription ?? "nil")",
                    "frame: \(element?.frame.debugDescription ?? "nil")",
                    "hittable: \(element?.isHittable.description ?? "nil")",
                ].joined(separator: "\n")
                let attachment = XCTAttachment(string: details)
                attachment.name = "accessibility-audit-issue"
                attachment.lifetime = .keepAlways
                XCTContext.runActivity(named: issue.compactDescription) { activity in
                    activity.add(attachment)
                }
                return false
            }
        }
    }

    /// README 블록 편집 GIF(`Docs/screenshots/13-block-editor.gif`)용 프레임을 남긴다.
    /// `scripts/capture-sse-gifs.sh block-editor`가 켜는 촬영 모드에서만 실행한다.
    @MainActor
    func testBlockEditorGifFrames() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RICHMARKDOWN_CAPTURE_GIFS"] == "1",
            "README GIF 촬영 모드(TEST_RUNNER_RICHMARKDOWN_CAPTURE_GIFS=1)에서만 실행한다"
        )
        let app = launchBlockEditor()
        let document = app.textViews["blockDocumentTextView"]
        XCTAssertTrue(document.waitForExistence(timeout: 15))
        recordGifFrames(for: 1)

        // 인용 줄은 행 내 수식으로 끝나므로 그 수식 요소의 높이에서 오른쪽 빈 곳을 눌러
        // 줄 끝에 커서를 둔다. 제목(H1)은 기본 글꼴이 굵어 굵게가 화면에 드러나지 않는다.
        // 하드웨어 키(typeKey)는 소프트웨어 키보드를 숨겨 툴바가 움직이므로 쓰지 않는다(실측).
        // 키보드는 typeText에서 올라오므로 입력이 끝난 화면부터 다시 촬영한다.
        let quoteEquation = document.otherElements
            .matching(NSPredicate(format: "label CONTAINS %@", "\\frac{1}{n}"))
            .firstMatch
        XCTAssertTrue(quoteEquation.waitForExistence(timeout: 5))
        let quoteLineEnd = quoteEquation
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: document.frame.maxX - 40 - quoteEquation.frame.midX, dy: 0))
        quoteLineEnd.tap()
        XCTAssertTrue(app.otherElements["blockKeyboardToolbar"].waitForExistence(timeout: 5))
        document.typeText(" 데모")
        XCTAssertTrue(waitForValue(containing: " 데모", in: document))
        recordGifFrames(for: 1)

        // 방금 입력한 단어를 편집 메뉴의 선택으로 고르고 굵게 바꾼 뒤 서식 도구를 닫는다.
        quoteLineEnd.press(forDuration: 1)
        try tapEditMenuItem(["Select", "선택"], in: app)
        recordGifFrames(for: 0.75)
        let formatButton = app.buttons["blockToolbar.format"]
        formatButton.tap()
        let boldButton = app.buttons["blockToolbar.bold"]
        XCTAssertTrue(boldButton.waitForExistence(timeout: 5))
        recordGifFrames(for: 0.75)
        boldButton.tap()
        recordGifFrames(for: 1)
        formatButton.tap()
        recordGifFrames(for: 0.5)

        // 실행 취소·다시 실행으로 굵게를 되돌렸다가 다시 적용한다.
        let undoButton = app.buttons["blockToolbar.undo"]
        XCTAssertTrue(waitForEnabled(undoButton))
        undoButton.tap()
        recordGifFrames(for: 1)
        app.buttons["blockToolbar.redo"].tap()
        recordGifFrames(for: 1)

        // 블록 추가 메뉴로 제목 아래에 할 일 블록을 넣고 내용을 입력한다.
        let original = try XCTUnwrap(document.value as? String)
        app.buttons["blockToolbar.add"].tap()
        let toDoItem = app.buttons["할 일"]
        XCTAssertTrue(toDoItem.waitForExistence(timeout: 5))
        recordGifFrames(for: 1)
        toDoItem.tap()
        XCTAssertTrue(waitForValueDifferent(from: original, in: document))
        document.typeText("README GIF 촬영")
        XCTAssertTrue(waitForValue(containing: "README GIF 촬영", in: document))
        recordGifFrames(for: 1.5)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "입력 이후 마지막 프레임까지 소프트웨어 키보드가 보여야 한다")
    }

    private var gifFrameIndex = 0

    /// 약 4Hz로 화면을 첨부한다. 스크립트가 첨부 timestamp로 프레임 간격을 복원한다.
    @MainActor
    private func recordGifFrames(for duration: TimeInterval) {
        let start = Date()
        var tick = 0.0
        repeat {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = String(format: "block-editor-frame-%03d", gifFrameIndex)
            attachment.lifetime = .keepAlways
            add(attachment)
            gifFrameIndex += 1
            tick += 0.25
            Thread.sleep(until: start.addingTimeInterval(tick))
        } while Date().timeIntervalSince(start) < duration
    }

    private func waitForValue(containing text: String, in element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func launchBlockEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 15))
        app.buttons["블록 편집 (Notion 스타일)"].tap()
        XCTAssertTrue(app.navigationBars["블록 편집"].waitForExistence(timeout: 10))
        return app
    }

    private func waitForValue(_ value: String, in element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitForValueDifferent(from value: String, in element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func selectAll(in element: XCUIElement, app: XCUIApplication) throws {
        let textCoordinate = element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.2, dy: 0.05)
        )
        textCoordinate.tap()
        textCoordinate.press(forDuration: 1)
        try tapEditMenuItem(["Select All", "전체 선택"], in: app)
    }

    private func tapEditMenuItem(_ labels: [String], in app: XCUIApplication) throws {
        let item = app.menuItems.matching(
            NSPredicate(format: "label IN %@", labels)
        ).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), labels.joined(separator: " / "))
        item.tap()
    }

    private func assertToolbarButtons(
        _ identifiers: [String],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in identifiers {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), identifier, file: file, line: line)
            XCTAssertFalse(button.label.isEmpty, identifier, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 43.5, identifier, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, identifier, file: file, line: line)
        }
    }
}
