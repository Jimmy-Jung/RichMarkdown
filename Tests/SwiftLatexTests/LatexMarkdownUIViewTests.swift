import Foundation
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

/// UIKit 네이티브 렌더러의 블록 구성과 인라인 수식 attachment 계약.
@MainActor
@Suite struct LatexMarkdownUIViewTests {

    private func waitForRender(_ view: LatexMarkdownUIView, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while view.model.hasOutstandingWork {
            #expect(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 게시 hop + rebuild hop 여유.
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutIfNeeded()
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let textView = view as? UITextView { found.append(textView) }
        for subview in view.subviews { found.append(contentsOf: textViews(in: subview)) }
        return found
    }

    private func attachmentCount(in view: UIView) -> Int {
        textViews(in: view).reduce(0) { total, textView in
            guard let attributed = textView.attributedText else { return total }
            var count = 0
            attributed.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if value is NSTextAttachment { count += 1 }
            }
            return total + count
        }
    }

    @Test func rendersBlocksAndHydratesInlineMathAsAttachment() async throws {
        let view = LatexMarkdownUIView(markdown: #"# 제목\#n\#n인라인 \(a+b\) 수식"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(view.blockStack.arrangedSubviews.count == 2, "heading + paragraph = 2 블록")
        #expect(attachmentCount(in: view) == 1, "수식 1개가 attachment로 hydration되어야 한다")

        let spoken = textViews(in: view).compactMap { ($0 as? LatexTextView)?.spokenOverride }
        #expect(spoken.contains { $0.contains("수식: a+b") }, "수식 문단에 합성 접근성 label이 있어야 한다")
    }

    private func firstTextViewFont(in view: UIView) -> UIFont? {
        for textView in textViews(in: view) {
            guard let attributed = textView.attributedText, attributed.length > 0 else { continue }
            if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                return font
            }
        }
        return nil
    }

    /// 폰트를 앰비언트 trait으로 해석하면 뷰에 건 `traitOverrides`가 글자 크기에 닿지 않는다.
    @Test func fontsFollowViewTraitOverrides() async throws {
        guard #available(iOS 17.0, *) else { return }

        let view = LatexMarkdownUIView(markdown: "본문 글자")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        // traitOverrides는 window 계층에 붙은 뒤에만 traitCollection에 반영된다(실측).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()

        try await waitForRender(view)
        let before = try #require(firstTextViewFont(in: view)?.pointSize)

        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(nanoseconds: 50_000_000)
        try await waitForRender(view)
        let after = try #require(firstTextViewFont(in: view)?.pointSize)

        #expect(after > before, "뷰 trait override가 글자 크기를 움직여야 한다")
        let expected = UIFont
            .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
            .pointSize
        #expect(after == expected, "본문 폰트는 뷰의 traitCollection으로 해석되어야 한다")
    }

    @Test func keepsSourceTextWhenMathRenderFails() async throws {
        let view = LatexMarkdownUIView(markdown: #"고장 \(\frac{\) 수식"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(attachmentCount(in: view) == 0, "렌더 실패 수식은 attachment가 없다")
        let text = textViews(in: view).map(\.text).compactMap { $0 }.joined()
        #expect(text.contains(#"\(\frac{\)"#), "실패 노드는 원래 구분자를 포함한 원문을 유지한다")
    }
}
