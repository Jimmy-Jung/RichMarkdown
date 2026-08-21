import Foundation
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

/// UIKit 네이티브 렌더러의 블록 구성과 인라인 수식 attachment 계약.
@MainActor
@Suite struct LatexMarkdownUIViewTests {

    private func waitFor(
        _ view: LatexMarkdownUIView,
        timeout: TimeInterval = 10,
        until condition: (LatexMarkdownUIView) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(view) {
            #expect(Date() < deadline, "조건이 제한 시간 안에 충족되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            view.layoutIfNeeded()
        }
    }

    private func waitForRender(_ view: LatexMarkdownUIView, timeout: TimeInterval = 10) async throws {
        try await waitFor(view, timeout: timeout) {
            !$0.model.hasOutstandingWork && !$0.hasPendingRebuild
        }
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

    private func renderedText(in view: UIView) -> String {
        textViews(in: view).compactMap(\.text).joined()
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

    @Test func showsFallbackImmediatelyWhenCreated() {
        let view = LatexMarkdownUIView(markdown: "처음 원문 fallback")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()

        #expect(renderedText(in: view) == view.model.fallbackMarkdown)
    }

    @Test func replacesPreviousDocumentWithLatestFallbackAfterCoalescedRebuild() async throws {
        let view = LatexMarkdownUIView(markdown: "이전 본문")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        try await waitForRender(view)
        #expect(renderedText(in: view).contains("이전 본문"))

        view.markdown = "최신 원문 fallback"
        #expect(view.model.fallbackMarkdown == "최신 원문 fallback")

        try await waitFor(view) {
            !$0.model.hasOutstandingWork
                && !$0.hasPendingRebuild
                && !renderedText(in: $0).contains("이전 본문")
        }
        #expect(renderedText(in: view).contains("최신 원문 fallback"))
    }

    @MainActor
    final class CallbackCounter {
        private(set) var count = 0
        private(set) var wasCalledDuringSetter = false
        var isInSetter = false

        func increment() {
            if isInSetter { wasCalledDuringSetter = true }
            count += 1
        }
    }

    @Test func markdownSetterDefersContentSizeCallback() async throws {
        let view = LatexMarkdownUIView(markdown: "이전 본문")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        try await waitForRender(view)

        let counter = CallbackCounter()
        view.onContentSizeChange = { counter.increment() }

        counter.isInSetter = true
        view.markdown = "최신 본문"
        counter.isInSetter = false

        #expect(!counter.wasCalledDuringSetter, "setter stack 안에서 self-sizing callback을 호출하면 안 된다")
        try await waitForRender(view)
        #expect(counter.count > 0, "coalesced rebuild 뒤에는 size callback이 와야 한다")
    }

    /// 같은 값 재대입은 재파싱을 만들지 않는다 (중복 파싱 방지 계약).
    ///
    /// 소비자가 `onContentSizeChange`에만 의존해 셀 상태를 복구하면, 같은 메시지로
    /// 재사용된 셀에서 콜백이 영구히 오지 않는다. 데모의 빈 버블 결함이 그 경로였다.
    @Test func reassigningSameValuesDoesNotNotify() async throws {
        let view = LatexMarkdownUIView(markdown: "본문 글자")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        try await waitForRender(view)

        let counter = CallbackCounter()
        view.onContentSizeChange = { counter.increment() }

        view.markdown = "본문 글자"
        view.parsesDollarMath = false
        view.theme = .default
        await Task.yield()
        #expect(counter.count == 0, "값이 그대로면 재파싱도 콜백도 없어야 한다")

        view.markdown = "다른 본문"
        try await waitForRender(view)
        #expect(counter.count > 0, "값이 바뀌면 콜백이 와야 한다")
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
        try await waitFor(view) {
            !$0.model.hasOutstandingWork
                && !$0.hasPendingRebuild
                && (firstTextViewFont(in: $0)?.pointSize ?? 0) > before
        }
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
        let text = renderedText(in: view)
        #expect(text.contains(#"\(\frac{\)"#), "실패 노드는 원래 구분자를 포함한 원문을 유지한다")
    }

    // MARK: - 블록 뷰 증분 재사용

    @Test func reusesBlockViewsWhenResubmittingSameValues() async throws {
        let view = LatexMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let before = view.blockStack.arrangedSubviews
        #expect(before.count == 2)

        view.markdown = "첫 문단\n\n둘째 문단"
        view.theme = .default
        try await waitForRender(view)

        let after = view.blockStack.arrangedSubviews
        #expect(after.count == 2)
        #expect(zip(after, before).allSatisfy { $0 === $1 }, "값이 그대로면 블록 뷰도 그대로여야 한다")
    }

    /// 스트리밍 append 경로. markdown이 바뀌면 model이 `document = nil`을 먼저 게시하므로
    /// 원문 fallback 단계를 반드시 거친다. 그 단계에서 뷰 인스턴스를 버리면 재사용이 없다.
    @Test func keepsLeadingBlockViewsWhenAppendingParagraph() async throws {
        let view = LatexMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let before = view.blockStack.arrangedSubviews
        #expect(before.count == 2)

        view.markdown = "첫 문단\n\n둘째 문단\n\n셋째 문단"
        try await waitForRender(view)

        let after = view.blockStack.arrangedSubviews
        #expect(after.count == 3, "새 블록만 늘어야 한다")
        #expect(after[0] === before[0], "앞 블록은 뷰를 재사용해야 한다")
        #expect(after[1] === before[1], "앞 블록은 뷰를 재사용해야 한다")
    }

    @Test func rebuildsEveryBlockWhenAppearanceChanges() async throws {
        let view = LatexMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let before = view.blockStack.arrangedSubviews
        #expect(before.count == 2)

        var theme = LatexTheme.default
        theme.textColor = .red
        view.theme = theme
        try await waitForRender(view)

        let after = view.blockStack.arrangedSubviews
        #expect(after.count == before.count)
        #expect(zip(after, before).allSatisfy { $0 !== $1 }, "겉모습이 바뀌면 전 블록을 새로 만든다")
    }

    /// 수식 이미지 hydration은 같은 문서를 두 번 게시한다(원문 → 이미지).
    /// 수식이 없는 블록은 그 두 게시 모두에서 뷰를 다시 만들지 않아야 한다.
    @Test func keepsPlainBlockViewAcrossMathHydration() async throws {
        let view = LatexMarkdownUIView(markdown: #"안정 문단\#n\#n수식 \(x_{4517}+1\) 끝"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(view.blockStack.arrangedSubviews.count == 2)
        #expect(attachmentCount(in: view) == 1)
        let plainBefore = view.blockStack.arrangedSubviews[0]
        let mathBefore = view.blockStack.arrangedSubviews[1]

        // 처음 보는 latex라 raster 캐시가 비어 있다 — 2단계 게시를 결정적으로 강제한다.
        view.markdown = #"안정 문단\#n\#n수식 \(x_{4519}+1\) 끝"#
        try await waitFor(view) {
            !$0.model.hasOutstandingWork
                && !$0.hasPendingRebuild
                && attachmentCount(in: $0) == 1
        }

        #expect(
            view.blockStack.arrangedSubviews[0] === plainBefore,
            "수식 없는 블록은 fallback·parse·hydration 게시에서 모두 재사용된다"
        )
        #expect(view.blockStack.arrangedSubviews[1] !== mathBefore, "수식이 바뀐 블록은 새로 만든다")
    }
}
