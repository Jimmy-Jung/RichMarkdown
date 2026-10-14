// Author: JunyoungJung
// Date: 2026-10-14

import XCTest

/// 루트에서 들어가는 데모 전 화면의 접근성 audit (DEVELOPMENT.md §5 접근성, §8 렌더/UI 테스트).
///
/// launch가 회당 7~8초라 구성(라이트·다크·최대 접근성 글자)마다 한 번 띄우고 모든 화면을
/// 돈다. SSE 화면은 로컬 시뮬레이션 스트림이 끝난 뒤의 최종 화면을 검사한다.
///
/// 제외 기준은 `RichMarkdownDemoP2UITests.testDefaultConfigurationMatrix`와 같다.
/// - `dynamicType`: 수식 raster 이미지는 고정 크기 bitmap이지만 Dynamic Type 크기로 다시
///   렌더된다. 실제 확대는 P2의 `testDynamicTypeExtremes`가 검증한다.
/// - `textClipped`: 수식·코드·링크 런이 섞인 합성 문단의 접근성 프레임 측정이 어긋나 잡히는
///   오탐(P2에서 스크린샷으로 잘림 없음 확인).
/// 그 밖의 예외는 `knownIssueReason`에 audit 문구 그대로 적는다.
final class AccessibilityAuditUITests: XCTestCase {

    private struct Screen {
        /// 루트 목록의 행 제목.
        let row: String
        let navigationTitle: String
        /// 화면이 검사할 상태가 될 때까지 기다린다.
        let prepare: @MainActor (XCUIApplication) -> Void
    }

    override func setUp() {
        // 한 화면의 audit 실패가 나머지 화면 검사를 막지 않게 한다. 이동 실패는 XCTUnwrap·guard로 끊는다.
        continueAfterFailure = true
    }

    @MainActor
    func testAuditEveryScreenInLightMode() throws {
        try auditEveryScreen(launchArguments: [])
    }

    @MainActor
    func testAuditEveryScreenInDarkMode() throws {
        try auditEveryScreen(launchArguments: ["-richmarkdownDark"])
    }

    @MainActor
    func testAuditEveryScreenAtLargestAccessibilitySize() throws {
        try auditEveryScreen(launchArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
    }

    // MARK: - 화면 목록

    @MainActor private static let screens: [Screen] = [
        Screen(row: "AI 챗봇 (SwiftUI)", navigationTitle: "AI 챗봇") { app in
            XCTAssertTrue(firstChatMessage(app).waitForExistence(timeout: 20))
        },
        Screen(row: "AI 챗봇 (UIKit)", navigationTitle: "UIKit 네이티브") { app in
            // UIKit 렌더러의 문단은 UITextView라 staticTexts가 아니다.
            let message = app.textViews.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는")).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 20))
        },
        Screen(row: "SSE 실시간 렌더링 (SwiftUI)", navigationTitle: "SSE 실시간 렌더링") { app in
            streamToEnd(app, identifierPrefix: "sseDemo")
        },
        Screen(row: "SSE 실시간 렌더링 (UIKit)", navigationTitle: "SSE 실시간 렌더링 (UIKit)") { app in
            streamToEnd(app, identifierPrefix: "uikitSseDemo")
        },
        Screen(row: "라이브 편집 (분할 미리보기)", navigationTitle: "라이브 편집") { _ in },
        Screen(row: "블록 편집 (Notion 스타일)", navigationTitle: "블록 편집") { app in
            XCTAssertTrue(app.textViews["blockDocumentTextView"].waitForExistence(timeout: 15))
        },
        Screen(row: "코드 블록 확장 (Mermaid · Prism)", navigationTitle: "코드 블록 확장") { app in
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 60), "다이어그램 WebView가 없다")
            let loading = app.staticTexts["Mermaid 다이어그램을 그리는 중입니다."]
            XCTAssertTrue(loading.waitForNonExistence(timeout: 60), "다이어그램 렌더가 끝나지 않았다")
        },
        Screen(row: "수식 Attachment (읽기 전용)", navigationTitle: "수식 Attachment") { app in
            XCTAssertTrue(app.textViews["attachmentDemoTextView"].waitForExistence(timeout: 15))
        },
        Screen(row: "UIKit UIHostingConfiguration", navigationTitle: "UIKit 셀") { app in
            XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 20))
        },
    ]

    @MainActor
    private static func firstChatMessage(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는")).firstMatch
    }

    /// 가장 빠른 전송 속도로 로컬 시뮬레이션을 돌리고, 청크를 받은 뒤 버튼이 다시 "시작"이 될
    /// 때까지 기다린다. 60Hz 스트림은 짧아 "중지" 상태를 관찰하지 못할 수 있으므로 청크 수로 판정한다.
    @MainActor
    private static func streamToEnd(_ app: XCUIApplication, identifierPrefix: String) {
        let rate = app.descendants(matching: .any)["\(identifierPrefix).rate"]
        if rate.waitForExistence(timeout: 10) {
            rate.buttons["60Hz"].firstMatch.tap()
        }
        let startStop = app.buttons["\(identifierPrefix).startStop"]
        let status = app.descendants(matching: .any)["\(identifierPrefix).status"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 10))
        startStop.tap()
        let ended = NSPredicate { _, _ in
            startStop.label == "시작" && status.exists && !status.label.hasPrefix("0 청크")
        }
        let expectation = XCTNSPredicateExpectation(predicate: ended, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 120), .completed, "스트림이 끝나지 않았다")
    }

    // MARK: - 실행

    @MainActor
    private func auditEveryScreen(launchArguments: [String]) throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("performAccessibilityAudit는 iOS 17부터다")
        }
        let app = XCUIApplication()
        app.launchArguments += launchArguments
        app.launch()
        let root = app.navigationBars["RichMarkdown Demo"]
        XCTAssertTrue(root.waitForExistence(timeout: 30))

        try XCTContext.runActivity(named: "루트 목록") { _ in
            try audit(app, screen: "루트 목록")
        }
        for screen in Self.screens {
            try XCTContext.runActivity(named: screen.row) { _ in
                let row = app.buttons[screen.row].firstMatch
                reveal(row, in: app)
                row.tap()
                let bar = app.navigationBars[screen.navigationTitle]
                guard bar.waitForExistence(timeout: 30) else {
                    XCTFail("\(screen.row) 화면으로 이동하지 못했다")
                    return
                }
                screen.prepare(app)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "audit-\(screen.row)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                try audit(app, screen: screen.row)

                XCTAssertTrue(goBack(from: bar, to: root), "\(screen.row)에서 루트로 돌아오지 못했다")
            }
        }
    }

    /// 뒤로 가기. 최대 접근성 글자의 코드 블록 화면에서 첫 탭이 무시된 적이 있어(다이어그램 렌더 직후)
    /// 루트가 보일 때까지 최대 세 번 누른다.
    @MainActor
    private func goBack(from bar: XCUIElement, to root: XCUIElement) -> Bool {
        for _ in 0..<3 where bar.exists {
            let back = bar.buttons["BackButton"]
            (back.exists ? back : bar.buttons.firstMatch).tap()
            if root.waitForExistence(timeout: 10) { return true }
        }
        return root.exists
    }

    /// 최대 접근성 글자에서는 루트 행이 화면 밖으로 밀린다. 행 중심이 화면 안쪽(위아래 여백 제외)에 올 때까지
    /// 위·아래로 찾는다. `isHittable`만 보면 화면 맨 아래에 몇 pt만 걸친 행도 참이 되어, 탭이 홈 제스처
    /// 영역에 들어가 화면 이동이 일어나지 않았다(2026-10-14 iPhone 16 Pro 18.6, 행 높이 209pt 중 6pt 노출).
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let safe = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        func centered() -> Bool {
            element.isHittable && safe.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }
        for _ in 0..<8 where !centered() { app.swipeUp() }
        for _ in 0..<16 where !centered() { app.swipeDown() }
        XCTAssertTrue(centered(), "\(element) 행을 화면 안쪽으로 가져오지 못했다")
    }

    @available(iOS 17.0, *)
    @MainActor
    private func audit(_ app: XCUIApplication, screen: String) throws {
        try app.performAccessibilityAudit(for: .all.subtracting([.dynamicType, .textClipped])) { issue in
            if let reason = Self.knownIssueReason(issue, screen: screen, app: app) {
                XCTContext.runActivity(named: "제외: \(reason)") { _ in }
                return true
            }
            let element = issue.element
            let details = [
                "screen: \(screen)",
                "type: \(issue.auditType)",
                "compact: \(issue.compactDescription)",
                "detailed: \(issue.detailedDescription)",
                "element: \(element?.debugDescription ?? "nil")",
                "frame: \(element?.frame.debugDescription ?? "nil")",
                "navigationBar: \(app.navigationBars.firstMatch.frame.debugDescription)",
            ].joined(separator: "\n")
            let attachment = XCTAttachment(string: details)
            attachment.name = "accessibility-audit-issue"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "\(screen): \(issue.compactDescription)") { activity in
                activity.add(attachment)
            }
            return false
        }
    }

    /// 확인한 예외. 없으면 nil(실패로 보고). 각 항목은 audit 문구(compactDescription) 그대로 고른다.
    @available(iOS 17.0, *)
    @MainActor
    private static func knownIssueReason(
        _ issue: XCUIAccessibilityAuditIssue,
        screen: String,
        app: XCUIApplication
    ) -> String? {
        guard let element = issue.element else { return nil }
        let frame = element.frame
        let label = element.label

        // "Contrast failed" / "Contrast nearly passed": 스크롤로 내비게이션 바 아래에 걸친 요소는
        // 반투명 바 재질을 배경으로 측정된다(SSE 자동 스크롤 직후 표 헤더 '구간·확률·비고', 최대
        // 글자에서 화면 위로 반쯤 밀린 목록 번호 '3.'). 바 밖의 같은 요소는 통과한다.
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        if issue.auditType == .contrast, frame.minY < barBottom {
            return "내비게이션 바 아래에 걸친 요소의 대비 측정(\(issue.compactDescription)): '\(label)'"
        }

        // "Contrast failed": 다크 모드 SSE(SwiftUI) 화면의 표 헤더 셀 '구간·확률·비고'. 글자는 #FFFFFF,
        // 헤더 배경은 #2C2C2E(약 13:1)다. 스크린샷 실측에서 셀 안의 0.5pt 테두리(#676768) 픽셀이 짧은
        // 헤더 글자의 순백 픽셀보다 많아(407 대 387) audit이 테두리를 전경색으로 잡는다.
        if issue.auditType == .contrast,
           issue.compactDescription == "Contrast failed",
           screen == "SSE 실시간 렌더링 (SwiftUI)",
           ["구간", "확률", "비고"].contains(label) {
            return "표 헤더 셀 테두리를 전경으로 잡은 대비 측정(Contrast failed): '\(label)'"
        }

        // "Label not human-readable": SwiftUI 표 셀의 label은 화면 글자 그대로('68.27%' 등)다.
        // 숫자+퍼센트를 식별자처럼 보는 audit 휴리스틱 오탐이며 VoiceOver는 정상 낭독한다.
        if issue.auditType == .sufficientElementDescription,
           issue.compactDescription == "Label not human-readable",
           label.range(of: #"^[0-9]+(\.[0-9]+)?%$"#, options: .regularExpression) != nil {
            return "숫자 표 셀 label 오탐(Label not human-readable): '\(label)'"
        }

        // "Contrast nearly passed": 데모 SSE 화면의 시스템 `.borderedProminent` 버튼(기본 tint 위 흰
        // 글자). 라이브러리 밖 데모 크롬이며 시스템 기본 스타일 그대로다.
        if issue.auditType == .contrast,
           issue.compactDescription == "Contrast nearly passed",
           element.identifier == "sseDemo.startStop" {
            return "데모 시스템 버튼 대비(Contrast nearly passed): sseDemo.startStop"
        }
        return nil
    }
}
