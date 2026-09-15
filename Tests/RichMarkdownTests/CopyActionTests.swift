import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// 복사 동작 검증 (DEVELOPMENT.md §8 렌더/UI 테스트 — 복사 버튼).
/// 앱 프로세스 안에서 확인한다. XCUITest 러너에서 pasteboard를 읽으면
/// 시스템 권한 프롬프트가 뜨고 "wait for app to idle"이 풀리지 않는다.
@MainActor
@Suite struct CopyActionTests {

    @Test func copyPutsMathSourceWithDelimitersOnPasteboard() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        let source = #"\[ \int_0^\infty e^{-x^2} \, dx = \frac{\sqrt{\pi}}{2} \]"#
        CopyButton.copy(source, to: pasteboard)
        #expect(pasteboard.string == source)
    }

    @Test func copyPutsCodeBlockBodyOnPasteboard() {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        let document = RichMarkdownParser.parse(
            markdown: "```swift\nlet x = 42\nprint(x)\n```",
            parsesDollarMath: false
        )
        var copiedCode: String?
        for block in document.blocks {
            if case .codeBlock(_, let code) = block { copiedCode = code }
        }
        let code = try? #require(copiedCode)
        CopyButton.copy(code ?? "", to: pasteboard)
        // 코드 블록은 trailing newline 없이 본문만 복사한다.
        #expect(pasteboard.string == "let x = 42\nprint(x)")
    }
}
