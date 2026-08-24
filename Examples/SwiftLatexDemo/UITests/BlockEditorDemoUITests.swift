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

    @MainActor
    private func launchBlockEditor() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["SwiftLatex Demo"].waitForExistence(timeout: 15))
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
