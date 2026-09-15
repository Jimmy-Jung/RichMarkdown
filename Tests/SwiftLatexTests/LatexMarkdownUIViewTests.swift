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

    /// 스트리밍 append 경로. model이 이전 문서를 유지한 채 새 parse를 게시하므로
    /// 앞쪽 블록의 뷰 인스턴스를 그대로 재사용해야 한다.
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

    // MARK: - 블록 수식 벡터 렌더

    @Test func standaloneEquationViewRendersAndFallsBackWithoutMarkdownChrome() {
        let rendered = LatexEquationUIView(latex: "E = mc^2")
        #expect(rendered.intrinsicContentSize.width > 0)
        #expect(rendered.intrinsicContentSize.height > 0)
        #expect(rendered.accessibilityLabel == "수식: E = mc^2")
        #expect(!(rendered.subviews.first is UILabel))
        #expect(rendered.subviews.contains { $0 is UIButton } == false)

        let fallback = LatexEquationUIView(latex: #"\frac{"#)
        let label = fallback.subviews.first as? UILabel
        #expect(label?.text == #"\frac{"#)
        #expect(fallback.intrinsicContentSize.height > 0)
    }

    @Test func inlineMathScannerUsesCanonicalRulesAndPreservesUTF16Ranges() throws {
        let source = #"\(x\) `$code$` $y$ \$escaped\$ $5 and $10 [\(link\)](https://example.com) ![\(image\)](https://example.com/i.png) 한글😀"#
        let code = try #require(source.range(of: "$code$"))
        let excluded = NSRange(code, in: source)

        let optOut = LatexInlineMathScanner.scan(
            source,
            parsesDollarMath: false,
            excluding: [excluded]
        )
        #expect(optOut.map(\.source) == [#"\(x\)"#])

        let optIn = LatexInlineMathScanner.scan(
            source,
            parsesDollarMath: true,
            excluding: [excluded]
        )
        #expect(optIn.map(\.source) == [#"\(x\)"#, "$y$"])
        for span in optIn {
            #expect((source as NSString).substring(with: span.range) == span.source)
        }
    }

    @Test func inlineEquationViewUsesTextModePointSizeAndOriginalSourceFallback() {
        let fallback = LatexEquationUIView(
            latex: #"\frac{"#,
            source: #"\(\frac{\)"#,
            isDisplay: false,
            pointSize: 31
        )

        #expect(fallback.rendersDisplayStyle == false)
        #expect(fallback.renderPointSize == 31)
        #expect((fallback.subviews.first as? UILabel)?.text == #"\(\frac{\)"#)

        fallback.latex = #"\sqrt{"#
        #expect((fallback.subviews.first as? UILabel)?.text == #"\sqrt{"#)
    }

    /// 블록 수식의 벡터 뷰. SwiftMath 타입을 테스트 타깃으로 끌어오지 않기 위해 구조로
    /// 판정한다 — 수식 접근성 label을 갖고, 원문 fallback(`UITextView`)도
    /// raster(`UIImageView`)도 아닌 뷰.
    private func blockMathVectorViews(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        if view.isAccessibilityElement,
           view.accessibilityLabel?.hasPrefix("수식: ") == true,
           !(view is UITextView),
           !(view is UIImageView) {
            found.append(view)
        }
        for subview in view.subviews { found.append(contentsOf: blockMathVectorViews(in: subview)) }
        return found
    }

    @Test func rendersBlockMathAsVectorViewWithSynchronousSize() async throws {
        let view = LatexMarkdownUIView(markdown: #"본문\#n\#n\[E = mc^2\]\#n\#n다음"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let vectors = blockMathVectorViews(in: view)
        #expect(vectors.count == 1, "블록 수식은 벡터 뷰 하나로 렌더된다")
        let vector = try #require(vectors.first)
        #expect(vector.intrinsicContentSize.width > 0)
        #expect(vector.intrinsicContentSize.height > 0, "동기 typeset으로 크기가 확정돼야 한다")
        #expect(vector.accessibilityLabel == "수식: E = mc^2")
        #expect(attachmentCount(in: view) == 0, "블록 수식은 text attachment를 쓰지 않는다")
        #expect(
            !renderedText(in: view).contains(#"\[E = mc^2\]"#),
            "벡터 렌더가 성공하면 원문 fallback을 보이지 않는다"
        )
    }

    @Test func keepsBlockMathSourceWhenLatexIsInvalid() async throws {
        let view = LatexMarkdownUIView(markdown: #"\[\frac{\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(blockMathVectorViews(in: view).isEmpty, "parse 실패 수식은 벡터 뷰를 만들지 않는다")
        #expect(
            renderedText(in: view).contains(#"\[\frac{\]"#),
            "실패 노드는 원래 구분자를 포함한 원문을 유지한다"
        )
    }

    /// preflight 상한을 넘는 수식은 동기 typeset을 시작하지도 않는다.
    /// raster와 같은 상한(`MathRenderService.preflightAllows`)을 지난다.
    @Test func keepsBlockMathSourceWhenPreflightRejects() async throws {
        let latex = String(repeating: "x+", count: 300) + "1"
        let view = LatexMarkdownUIView(markdown: #"\["# + latex + #"\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(blockMathVectorViews(in: view).isEmpty, "상한 초과 수식은 벡터 뷰를 만들지 않는다")
        #expect(renderedText(in: view).contains(latex), "상한 초과 수식은 원문으로 남는다")
    }

    /// UIKit 렌더러는 블록 수식 raster를 요청하지 않는다.
    @Test func doesNotRasterBlockMath() async throws {
        let unique = UUID().uuidString.prefix(8)
        let view = LatexMarkdownUIView(markdown: #"\[w_{\#(unique)}+9\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(blockMathVectorViews(in: view).count == 1, "블록 수식은 벡터 뷰로 렌더된다")
        #expect(view.model.mathImages.isEmpty, "블록 수식만 있는 문서는 raster 이미지가 없어야 한다")
        #expect(view.model.imageRequest != nil, "빈 이미지 사전으로도 완결 게시가 온다")
    }

    /// 스트리밍 append는 **fallback 프레임 없이** 이전 렌더를 유지한다.
    ///
    /// model이 append에서 document를 유지하므로(스트리밍 append 계약) 새 parse가 게시되기
    /// 전의 rebuild는 기존 블록 뷰를 그대로 되돌려 놓는다 — 원문 텍스트로 되돌아가는
    /// 프레임이 없다. 그 프레임이 있으면 스트리밍 화면 전체가 원문 ↔ 렌더를 오가며
    /// 출렁인다(데모 실측).
    @Test func keepsRenderedBlocksWithoutFallbackFrameAcrossStreamingAppend() async throws {
        let view = LatexMarkdownUIView(markdown: "첫 원문")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        try await waitForRender(view)
        let renderedBlock = try #require(view.blockStack.arrangedSubviews.first)

        view.markdown = "첫 원문\n\n둘째 문단"
        await Task.yield()

        #expect(
            view.blockStack.arrangedSubviews.first === renderedBlock,
            "append 중에는 이전 렌더 블록이 그대로 보인다 — 원문 fallback 프레임이 없다"
        )
        #expect(renderedText(in: view).contains("첫 원문"))

        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 2, "parse 후에는 새 블록이 추가된다")
        #expect(renderedText(in: view).contains("둘째 문단"))
        #expect(
            view.blockStack.arrangedSubviews.first === renderedBlock,
            "append 전 블록 뷰는 parse 후에도 재사용된다"
        )
    }

    /// 데모(UIKitChatDemo)의 뷰 캐시 안무 재현 — 버그 리포트: 화면 재진입 후 스크롤
    /// 왕복 중 "실패 시 원문 표시 (fail-open)" 버블이 비어 보인다.
    ///
    /// Entry처럼 detached + 빈 markdown으로 생성 → Auto Layout으로 셀 버블에 부착 →
    /// markdown 주입 → 렌더 → 셀 재사용으로 detach → 다른 버블에 재부착 + 같은 값
    /// 재대입(dedupe) → 내용이 계속 보여야 한다.
    @Test func demoLikeWindowCyclesKeepFailOpenContent() async throws {
        let failOpen = #"""
        미완성: \(x + y 는 닫히지 않았습니다.

        빈 수식: \(\) 도 원문 그대로입니다.

        중첩: \(a \(b\) c\)

        렌더 불가한 LaTeX: \(\frac{\) 와 \(\unknowncommand{x}\)

        문단 전체가 아닌 위치의 display 구분자: 이건 \[x+y\] 인라인 위치입니다.
        """#

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        // 데모 Entry와 동일: detached + 빈 markdown으로 생성.
        let view = LatexMarkdownUIView()
        view.translatesAutoresizingMaskIntoConstraints = false

        for cycle in 0..<3 {
            let bubble = UIView()
            bubble.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(bubble)
            bubble.addSubview(view)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: window.topAnchor, constant: 8),
                bubble.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: 16),
                bubble.widthAnchor.constraint(equalToConstant: 320),
                view.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
                view.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
                view.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
                view.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -14),
            ])

            // 데모 configure 순서: attach → apply(theme/parsesDollarMath 재대입) → markdown.
            view.theme = .default
            view.parsesDollarMath = false
            view.markdown = failOpen
            window.layoutIfNeeded()
            try await waitForRender(view)

            let text = renderedText(in: view)
            #expect(text.contains("미완성"), "cycle \(cycle): fail-open 원문이 보여야 한다")
            #expect(text.contains(#"\(\frac{\)"#), "cycle \(cycle): 실패 수식 원문 유지")
            #expect(view.blockStack.arrangedSubviews.count == 5, "cycle \(cycle): 문단 5개")
            #expect(view.bounds.height > 0, "cycle \(cycle): Auto Layout 높이가 0이면 안 된다")

            // 셀 재사용: prepareForReuse → detachMessageView와 동일.
            view.removeFromSuperview()
            bubble.removeFromSuperview()
        }
    }

    @Test func inlineCodeCarriesChipAttributeAndAccentColor() async throws {
        let view = LatexMarkdownUIView(markdown: "앞 `code` 뒤")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let textView = try #require(textViews(in: view).first)
        let attributed = try #require(textView.attributedText)
        var chipRange = NSRange(location: NSNotFound, length: 0)
        let chip = attributed.attribute(.inlineCodeChip, at: 2, effectiveRange: &chipRange)
        #expect(chip is InlineCodeChipStyle)
        #expect(chipRange == NSRange(location: 2, length: 4))
        // 사각형만 그리는 `.backgroundColor`는 더 이상 쓰지 않는다 — 칩 밑판이 대신 그린다.
        #expect(attributed.attribute(.backgroundColor, at: 2, effectiveRange: nil) == nil)
        let bodyColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let codeColor = attributed.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? UIColor
        #expect(codeColor != nil)
        #expect(codeColor != bodyColor)
        #expect((textView as? LatexTextView)?.inlineCodeDecoration != nil)
    }

    @Test func inlineCodeDecorationDrawsChipPathAfterLayout() async throws {
        let view = LatexMarkdownUIView(markdown: "앞 `code` 뒤")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let textView = try #require(textViews(in: view).compactMap { $0 as? LatexTextView }.first)
        textView.layoutIfNeeded()
        let decoration = try #require(textView.inlineCodeDecoration)
        decoration.refresh()
        let path = try #require((decoration.layer as? CAShapeLayer)?.path)
        #expect(!path.boundingBox.isEmpty)
        #expect(path.boundingBox.width > 0)
    }

    @Test func rendersTableAsScrollableGridWithAlignmentAndInlineMath() async throws {
        let view = LatexMarkdownUIView(markdown: #"""
        | 항목 | 수식 | 상태 |
        | :--- | :---: | ---: |
        | 하나 | \(x+1\) | [완료](https://example.com) |
        """#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let table = try #require(view.blockStack.arrangedSubviews.first as? UIScrollView)
        let cells = textViews(in: table)
        #expect(view.blockStack.arrangedSubviews.count == 1)
        #expect(cells.count == 6, "헤더 3칸과 본문 3칸을 각각 렌더해야 한다")
        #expect(cells.map(\.textAlignment) == [.left, .center, .right, .left, .center, .right])
        #expect(cells.prefix(3).allSatisfy { $0.accessibilityTraits.contains(.header) })
        #expect(cells.map(\.accessibilityHint) == [
            "열 1, 헤더",
            "열 2, 헤더",
            "열 3, 헤더",
            "행 1, 열 1, 헤더 항목",
            "행 1, 열 2, 헤더 수식",
            "행 1, 열 3, 헤더 상태",
        ])
        #expect((cells[4] as? LatexTextView)?.spokenOverride == "수식: x+1")
        #expect((cells[5] as? LatexTextView)?.spokenOverride == nil, "셀 hint가 링크 label을 덮으면 안 된다")
        #expect(
            cells[5].attributedText.attribute(.link, at: 0, effectiveRange: nil) as? URL
                == URL(string: "https://example.com")
        )
        #expect(cells.allSatisfy { $0.layer.borderWidth > 0 })
        let border = UIColor(cgColor: try #require(cells[0].layer.borderColor))
        let expectedBorder = UIColor(LatexTheme.default.textColor)
            .resolvedColor(with: view.traitCollection)
            .withAlphaComponent(0.2)
        #expect(border.rgbaValue == expectedBorder.rgbaValue)
        #expect(attachmentCount(in: table) == 1, "표 셀의 인라인 수식도 hydration되어야 한다")
        #expect(!renderedText(in: table).contains("|"), "Markdown 표 원문을 그대로 표시하면 안 된다")
    }

    // MARK: - 스트리밍 tail

    private func foregroundAlpha(in textView: UITextView, at location: Int) -> CGFloat {
        guard let attributed = textView.attributedText, attributed.length > location else { return -1 }
        let color = attributed.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
        return color?.cgColor.alpha ?? -1
    }

    @Test func streamingTailFadesTrailingGraphemes() async throws {
        let view = LatexMarkdownUIView(markdown: "앞 문단\n\n꼬리 문단은 열두 글자보다 충분히 길어서 앞부분은 원래 색을 유지한다")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let views = textViews(in: view)
        #expect(views.count == 2)
        #expect(foregroundAlpha(in: views[0], at: 0) == 1, "tail이 아닌 블록은 페이드하지 않는다")
        #expect(foregroundAlpha(in: views[1], at: 0) == 1, "tail 앞부분은 원래 색이다")
        let lastAlpha = foregroundAlpha(in: views[1], at: views[1].attributedText.length - 1)
        #expect(lastAlpha > 0 && lastAlpha < 1, "마지막 grapheme은 옅어진다")

        view.streaming = nil
        try await waitForRender(view)
        let tail = textViews(in: view)[1]
        #expect(foregroundAlpha(in: tail, at: tail.attributedText.length - 1) == 1, "스트림이 끝나면 원래 색으로 돌아온다")
    }

    @Test func streamingTailHidesUnclosedStrongUntilStreamingEnds() async throws {
        let view = LatexMarkdownUIView(markdown: "앞\n\n**굵게")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(!renderedText(in: view).contains("**"), "스트리밍 중 미닫힌 opener는 숨긴다")
        #expect(renderedText(in: view).contains("굵게"))

        view.streaming = nil
        try await waitForRender(view)
        #expect(renderedText(in: view).contains("**"), "스트림이 끝나면 원문대로 보인다")
    }

    @Test func streamingUpdatesTailTextViewInPlace() async throws {
        let view = LatexMarkdownUIView(markdown: "첫 문단\n\n꼬리")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 2)
        let tailBefore = view.blockStack.arrangedSubviews[1]

        view.markdown = "첫 문단\n\n꼬리 문단이 더 길어졌다"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[1] === tailBefore, "스트리밍 중 tail 문단은 같은 뷰의 내용만 바꾼다")
        #expect(renderedText(in: view).contains("길어졌다"))

        view.markdown = "첫 문단\n\n꼬리 문단이 더 길어졌다\n\n세 번째"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 3)
        #expect(
            view.blockStack.arrangedSubviews[1] === tailBefore,
            "tail에서 벗어난 문단도 새로 만들지 않고 페이드만 걷어낸다"
        )
        let formerTail = try #require(view.blockStack.arrangedSubviews[1] as? UITextView)
        #expect(foregroundAlpha(in: formerTail, at: formerTail.attributedText.length - 1) == 1)
    }

    @Test func streamingInstallsChipDecorationWhenInlineCodeCloses() async throws {
        let view = LatexMarkdownUIView(markdown: "a `co")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let textView = try #require(textViews(in: view).first as? LatexTextView)
        #expect(textView.inlineCodeDecoration == nil)
        #expect(!renderedText(in: view).contains("`"), "미닫힌 백틱은 숨긴다")

        view.markdown = "a `code` b"
        try await waitForRender(view)
        #expect(textViews(in: view).first === textView, "같은 뷰를 유지한다")
        #expect(textView.inlineCodeDecoration != nil, "백틱이 닫히면 칩 장식을 그 자리에서 설치한다")
    }
}
