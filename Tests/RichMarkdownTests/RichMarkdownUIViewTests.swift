import Foundation
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// UIKit 네이티브 렌더러의 블록 구성과 인라인 수식 attachment 계약.
@MainActor
@Suite struct RichMarkdownUIViewTests {

    private func waitFor(
        _ view: RichMarkdownUIView,
        timeout: TimeInterval = 10,
        until condition: (RichMarkdownUIView) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(view) {
            #expect(Date() < deadline, "조건이 제한 시간 안에 충족되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            view.layoutIfNeeded()
        }
    }

    private func waitForRender(_ view: RichMarkdownUIView, timeout: TimeInterval = 10) async throws {
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

    private func copyButtons(in view: UIView) -> [RichMarkdownCopyButton] {
        var found: [RichMarkdownCopyButton] = []
        if let button = view as? RichMarkdownCopyButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: copyButtons(in: subview)) }
        return found
    }

    @Test func rendersBlocksAndHydratesInlineMathAsAttachment() async throws {
        let view = RichMarkdownUIView(markdown: #"# 제목\#n\#n인라인 \(a+b\) 수식"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(view.blockStack.arrangedSubviews.count == 2, "heading + paragraph = 2 블록")
        #expect(attachmentCount(in: view) == 1, "수식 1개가 attachment로 hydration되어야 한다")

        let spoken = textViews(in: view).compactMap { ($0 as? RichMarkdownTextView)?.spokenOverride }
        #expect(spoken.contains { $0.contains("수식: a+b") }, "수식 문단에 합성 접근성 label이 있어야 한다")
    }

    @Test func showsFallbackImmediatelyWhenCreated() {
        let view = RichMarkdownUIView(markdown: "처음 원문 fallback")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        view.layoutIfNeeded()

        #expect(renderedText(in: view) == view.model.fallbackMarkdown)
    }

    @Test func replacesPreviousDocumentWithLatestFallbackAfterCoalescedRebuild() async throws {
        let view = RichMarkdownUIView(markdown: "이전 본문")
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

    /// append 제출은 rebuild를 예약하지 않고, 교체 제출은 parse 전에 최신 fallback을 그린다.
    ///
    /// append 중에는 문서를 유지하므로 model이 게시하지 않는다. 교체는 `document = nil`
    /// 게시로 rebuild를 예약하고, 그 rebuild가 `fallbackMarkdown`을 읽는다.
    @Test func streamingAppendSkipsRebuildButReplacementShowsFallback() async throws {
        let view = RichMarkdownUIView(markdown: "첫 원문")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        try await waitForRender(view)

        view.markdown = "첫 원문 이어짐"
        #expect(!view.hasPendingRebuild, "append 제출만으로는 rebuild를 예약하지 않는다")
        try await waitForRender(view)
        #expect(renderedText(in: view).contains("첫 원문 이어짐"), "parse 게시 뒤에는 새 문서를 그린다")

        view.markdown = "교체 원문"
        #expect(view.hasPendingRebuild, "교체 제출은 fallback rebuild를 예약한다")
        // 예약된 rebuild는 worker 게시보다 먼저 같은 MainActor 큐에서 실행된다.
        await Task.yield()
        #expect(view.model.document == nil, "아직 parse 게시 전이다")
        #expect(renderedText(in: view).contains("교체 원문"), "parse 전에도 최신 fallback이 보인다")
        #expect(!renderedText(in: view).contains("첫 원문"))
        try await waitForRender(view)
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
        let view = RichMarkdownUIView(markdown: "이전 본문")
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
        let view = RichMarkdownUIView(markdown: "본문 글자")
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

    /// 보이는 것이 그대로인 재게시(스트리밍 append의 원문 게시, 끝 공백만 붙은 parse)는 높이 무효화와
    /// `onContentSizeChange`를 건너뛴다. 소비자가 tick마다 강제 레이아웃하지 않게 한다.
    @Test func skipsContentSizeCallbackWhenRepublishedDocumentIsUnchanged() async throws {
        let view = RichMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let counter = CallbackCounter()
        view.onContentSizeChange = { counter.increment() }

        view.markdown = "첫 문단\n\n둘째 문단 "
        try await waitForRender(view)
        #expect(counter.count == 0, "보이는 것이 그대로면 크기 콜백이 없어야 한다")

        view.markdown = "첫 문단\n\n둘째 문단 셋"
        try await waitForRender(view)
        #expect(counter.count > 0, "실제로 바뀌면 콜백이 와야 한다")
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

        let view = RichMarkdownUIView(markdown: "본문 글자")
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
        let view = RichMarkdownUIView(markdown: #"고장 \(\frac{\) 수식"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(attachmentCount(in: view) == 0, "렌더 실패 수식은 attachment가 없다")
        let text = renderedText(in: view)
        #expect(text.contains(#"\(\frac{\)"#), "실패 노드는 원래 구분자를 포함한 원문을 유지한다")
    }

    // MARK: - 블록 뷰 증분 재사용

    @Test func reusesBlockViewsWhenResubmittingSameValues() async throws {
        let view = RichMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
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
        let view = RichMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
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
        let view = RichMarkdownUIView(markdown: "첫 문단\n\n둘째 문단")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let before = view.blockStack.arrangedSubviews
        #expect(before.count == 2)

        var theme = RichMarkdownTheme.default
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
        let view = RichMarkdownUIView(markdown: #"안정 문단\#n\#n수식 \(x_{4517}+1\) 끝"#)
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

    /// 접근성 audit 회귀(2026-10-14, 수식 Attachment 데모): trait이 없으면 인라인 크기의 수식 뷰가
    /// 상호작용 요소로 취급돼 "Hit area is too small"로 잡힌다. 누를 수 없는 수식 텍스트다.
    @Test func standaloneEquationViewIsNonInteractiveStaticText() {
        let view = LatexEquationUIView(latex: #"\frac{a}{b}"#, isDisplay: false)
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityTraits == .staticText)
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

    /// 블록 수식의 벡터 뷰. 수식 엔진 타입을 테스트 타깃으로 끌어오지 않기 위해 구조로
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
        let view = RichMarkdownUIView(markdown: #"본문\#n\#n\[E = mc^2\]\#n\#n다음"#)
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
        let view = RichMarkdownUIView(markdown: #"\[\frac{\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(blockMathVectorViews(in: view).isEmpty, "parse 실패 수식은 벡터 뷰를 만들지 않는다")
        #expect(
            renderedText(in: view).contains(#"\[\frac{\]"#),
            "실패 노드는 원래 구분자를 포함한 원문을 유지한다"
        )
    }

    @Test func rendersComplexBlockMathWithAccessibilityAndCopy() async throws {
        let latex = #"\underbrace{\begin{array}{c}a+b\\c+d\end{array}}_{q}"#
        let view = RichMarkdownUIView(markdown: #"## 복합 수식\#n\#n\["# + latex + #"\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let vector = try #require(blockMathVectorViews(in: view).first)
        #expect(vector.accessibilityLabel == "수식: \(latex)")
        #expect(!renderedText(in: view).contains(latex), "성공한 복합 수식은 원문 fallback을 남기지 않는다")
        #expect(view.model.mathImages.isEmpty, "UIKit 복합 블록도 raster를 요청하지 않는다")
        #expect(copyButtons(in: view).count == 1, "기존 수식 복사 버튼을 유지한다")
    }

    /// preflight 상한을 넘는 수식은 동기 typeset을 시작하지도 않는다.
    /// raster와 같은 상한(`MathRenderService.preflightAllows`)을 지난다.
    @Test func keepsBlockMathSourceWhenPreflightRejects() async throws {
        let latex = String(repeating: "x+", count: 300) + "1"
        let view = RichMarkdownUIView(markdown: #"\["# + latex + #"\]"#)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(blockMathVectorViews(in: view).isEmpty, "상한 초과 수식은 벡터 뷰를 만들지 않는다")
        #expect(renderedText(in: view).contains(latex), "상한 초과 수식은 원문으로 남는다")
    }

    /// UIKit 렌더러는 블록 수식 raster를 요청하지 않는다.
    @Test func doesNotRasterBlockMath() async throws {
        let unique = UUID().uuidString.prefix(8)
        let view = RichMarkdownUIView(markdown: #"\[w_{\#(unique)}+9\]"#)
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
        let view = RichMarkdownUIView(markdown: "첫 원문")
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
        let view = RichMarkdownUIView()
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
        let view = RichMarkdownUIView(markdown: "앞 `code` 뒤")
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
        #expect((textView as? RichMarkdownTextView)?.inlineCodeDecoration != nil)
    }

    @Test func inlineCodeDecorationDrawsChipPathAfterLayout() async throws {
        let view = RichMarkdownUIView(markdown: "앞 `code` 뒤")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let textView = try #require(textViews(in: view).compactMap { $0 as? RichMarkdownTextView }.first)
        textView.layoutIfNeeded()
        let decoration = try #require(textView.inlineCodeDecoration)
        decoration.refresh()
        let path = try #require((decoration.layer as? CAShapeLayer)?.path)
        #expect(!path.boundingBox.isEmpty)
        #expect(path.boundingBox.width > 0)
    }

    @Test func rendersTableAsScrollableGridWithAlignmentAndInlineMath() async throws {
        let view = RichMarkdownUIView(markdown: #"""
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
        #expect((cells[4] as? RichMarkdownTextView)?.spokenOverride == "수식: x+1")
        #expect((cells[5] as? RichMarkdownTextView)?.spokenOverride == nil, "셀 hint가 링크 label을 덮으면 안 된다")
        #expect(
            cells[5].attributedText.attribute(.link, at: 0, effectiveRange: nil) as? URL
                == URL(string: "https://example.com")
        )
        #expect(cells.allSatisfy { $0.layer.borderWidth > 0 })
        let border = UIColor(cgColor: try #require(cells[0].layer.borderColor))
        let expectedBorder = UIColor(RichMarkdownTheme.default.textColor)
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
        let view = RichMarkdownUIView(markdown: "앞 문단\n\n꼬리 문단은 열두 글자보다 충분히 길어서 앞부분은 원래 색을 유지한다")
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
        let view = RichMarkdownUIView(markdown: "앞\n\n**굵게")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(!renderedText(in: view).contains("**"), "스트리밍 중 미닫힌 opener는 숨긴다")
        #expect(renderedText(in: view).contains("굵게"))

        view.streaming = nil
        try await waitForRender(view)
        #expect(renderedText(in: view).contains("**"), "스트림이 끝나면 원문대로 보인다")
    }

    /// 스트림이 끝나 tail 옵션만 사라진 마지막 블록은 다시 만들지 않는다. 같은 뷰에서 페이드를 걷고
    /// 숨긴 마크를 되살린다. tail을 쓰지 않는 블록(구분선·블록 수식)은 그대로 둔다.
    @Test(arguments: ["앞 문단\n\n**굵게 꼬리", "앞 문단\n\n---", #"앞 문단\#n\#n\[E = mc^2\]"#])
    func keepsTailBlockViewWhenStreamingEnds(_ markdown: String) async throws {
        let view = RichMarkdownUIView(markdown: markdown)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 2)
        let tail = view.blockStack.arrangedSubviews[1]

        view.streaming = nil
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[1] === tail, "스트림 종료는 tail 블록 뷰를 다시 만들지 않는다")

        let reference = RichMarkdownUIView(markdown: markdown)
        reference.frame = view.frame
        try await waitForRender(reference)
        #expect(
            StreamingRenderEquivalenceTests.describe(view.blockStack)
                == StreamingRenderEquivalenceTests.describe(reference.blockStack),
            "스트림이 끝난 뒤의 표시는 한 번에 그린 결과와 같다"
        )
    }

    /// 마지막 flush와 스트림 종료가 같은 turn에 오면 끝 글자를 담은 문서는 `streaming = nil` 뒤에 도착한다.
    /// 그 문서도 마지막 블록을 자리에서 갱신한다 — 표가 길수록 종료 tick hitch가 커진다(행 수 비례).
    @Test(arguments: zip(
        [
            "앞 문단\n\n| 항목 | 값 |\n| --- | --- |\n| 하나 | 1 |\n| 둘 | 2",
            "앞 문단\n\n꼬리",
            "앞 문단\n\n- 하나\n- 둘",
            "앞 문단\n\n> 하나\n>\n> 둘",
        ],
        ["0", " 끝", " 끝", " 끝"]
    ))
    func keepsTailBlockViewWhenFinalChunkArrivesWithStreamEnd(_ prefix: String, _ finalChunk: String) async throws {
        let view = RichMarkdownUIView(markdown: prefix)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 2)
        let tail = view.blockStack.arrangedSubviews[1]

        view.markdown = prefix + finalChunk
        view.streaming = nil
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[1] === tail, "스트림 종료와 함께 온 마지막 청크도 tail 블록 뷰를 다시 만들지 않는다")

        let reference = RichMarkdownUIView(markdown: prefix + finalChunk)
        reference.frame = view.frame
        try await waitForRender(reference)
        #expect(
            StreamingRenderEquivalenceTests.describe(view.blockStack)
                == StreamingRenderEquivalenceTests.describe(reference.blockStack),
            "스트림이 끝난 뒤의 표시는 한 번에 그린 결과와 같다"
        )
    }

    @Test func streamingUpdatesTailTextViewInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "첫 문단\n\n꼬리")
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

    // MARK: - 스트리밍 in-place: 구조 블록 (2026-09-15 iPad Pro 실측 — 표 스트리밍 구간 hitch 집중)

    /// 같은 언어의 코드 블록은 tick마다 UITextView·복사 버튼·스크롤 컨테이너를 다시 만들지 않는다.
    @Test func streamingUpdatesTailCodeBlockInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "앞 문단\n\n```swift\nlet a")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 2)
        let codeBefore = view.blockStack.arrangedSubviews[1]
        let bodyBefore = try #require(textViews(in: codeBefore).first)

        view.markdown = "앞 문단\n\n```swift\nlet a = 1"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[1] === codeBefore, "같은 언어의 코드 블록은 본문만 바꾼다")
        #expect(textViews(in: codeBefore).first === bodyBefore, "본문 UITextView도 그대로다")
        #expect(renderedText(in: codeBefore).contains("let a = 1"))
        #expect(copyButtons(in: codeBefore).first?.payload == "let a = 1", "복사 원문도 함께 바뀐다")

        view.markdown = "앞 문단\n\n```python\nlet a = 1"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[1] !== codeBefore, "언어가 바뀌면 새로 만든다")
    }

    /// 열 수가 같은 표는 바뀐 셀만 다시 채운다. 행이 늘어나는 tick도 새 행만 붙인다.
    @Test func streamingUpdatesTailTableCellsInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "| 항목 | 값 |\n| --- | --- |\n| 하나 | 1")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 1)
        let tableBefore = view.blockStack.arrangedSubviews[0]
        let cellsBefore = textViews(in: tableBefore)
        #expect(cellsBefore.count == 4)

        view.markdown = "| 항목 | 값 |\n| --- | --- |\n| 하나 | 12"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[0] === tableBefore, "행 수가 같으면 표 뷰를 유지한다")
        #expect(
            zip(textViews(in: tableBefore), cellsBefore).allSatisfy { $0 === $1 },
            "셀 UITextView 인스턴스도 유지한다"
        )
        #expect(renderedText(in: tableBefore).contains("12"))

        view.markdown = "| 항목 | 값 |\n| --- | --- |\n| 하나 | 12 |\n| 둘 | 3"
        try await waitForRender(view)
        #expect(textViews(in: view.blockStack.arrangedSubviews[0]).count == 6, "행이 늘면 새 행이 붙는다")
        #expect(renderedText(in: view).contains("둘"))
    }

    @Test func tableHeightFitsRowsOnCreationAndStreamingContentGrowth() async throws {
        let prefix = "| 설명 | 확률 |\n| --- | --- |\n| "
        let view = RichMarkdownUIView(markdown: prefix + "한 줄 | 68.27% |")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        let percentage = try #require(table.cells.last?.last)
        #expect(percentage.text == "68.27%")

        func fittedHeight() -> CGFloat {
            table.systemLayoutSizeFitting(
                CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }
        let initialHeight = fittedHeight()
        let minimumCellHeight = percentage.sizeThatFits(
            CGSize(width: 96, height: CGFloat.greatestFiniteMagnitude)
        ).height
        #expect(initialHeight >= minimumCellHeight * 2, "헤더와 본문이 초기 1pt 제약에 눌리면 안 된다")

        view.markdown = prefix + String(repeating: "긴 설명 ", count: 40) + "| 68.27% |"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.first === table, "같은 구조의 표는 제자리 갱신한다")
        #expect(table.cells.last?.last === percentage)
        #expect(fittedHeight() > initialHeight, "줄바꿈한 셀은 이전 표 높이보다 커져야 한다")
    }

    /// 제자리 갱신으로 다시 채운 셀도 열 정렬을 유지한다. `attributedText` 대입은 `textAlignment`를
    /// 기본값(natural)으로 되돌린다 (2026-10-15 시뮬레이터 실측).
    @Test func streamingTableCellKeepsColumnAlignmentAfterUpdate() async throws {
        let prefix = "| 항목 | 값 | 비고 |\n| :--- | ---: | :---: |\n| 하나 | 1 | 가"
        let view = RichMarkdownUIView(markdown: prefix)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        let cell = try #require(table.cells.last?.last)

        view.markdown = prefix + "나"
        try await waitForRender(view)
        #expect(table.cells.last?.last === cell, "같은 구조의 표는 셀을 제자리 갱신한다")
        #expect(cell.text == "가나")
        #expect(table.cells.allSatisfy { $0.map(\.textAlignment) == [.left, .right, .center] })
    }

    private func fittedHeight(of table: UIView, width: CGFloat = 320) -> CGFloat {
        table.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    /// 행이 늘어나는 tick도 표를 다시 만들지 않는다. 기존 셀은 그대로 두고 새 행만 붙인다
    /// (2026-10-15 시뮬레이터 실측: 행 추가 tick마다 셀 전부를 재생성해 hitch가 행 수에 비례했다, 10→28 ms).
    @Test func streamingAppendsTableRowInPlace() async throws {
        let prefix = "| 항목 | 값 |\n| :--- | ---: |\n| 하나 | 1 |"
        let view = RichMarkdownUIView(markdown: prefix)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        let cellsBefore = table.cells.flatMap { $0 }
        #expect(cellsBefore.count == 4)
        let heightBefore = fittedHeight(of: table)

        let appended = prefix + "\n| 둘 | 2"
        view.markdown = appended
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.first === table, "행이 늘어도 표 뷰를 유지한다")
        #expect(
            zip(table.cells.flatMap { $0 }, cellsBefore).allSatisfy { $0 === $1 },
            "기존 셀 UITextView 인스턴스를 유지한다"
        )
        #expect(table.cells.count == 3)
        let newRow = try #require(table.cells.last)
        #expect(newRow.map(\.text) == ["둘", "2"])
        #expect(newRow.map(\.textAlignment) == [.left, .right])
        #expect(newRow.map(\.accessibilityHint) == ["행 2, 열 1, 헤더 항목", "행 2, 열 2, 헤더 값"])
        #expect(newRow.allSatisfy { $0.layer.borderWidth > 0 && !$0.accessibilityTraits.contains(.header) })
        #expect(textViews(in: table).count == 6, "새 행이 계층에 붙어야 한다")

        let reference = RichMarkdownUIView(markdown: appended)
        reference.frame = view.frame
        try await waitForRender(reference)
        let referenceTable = try #require(reference.blockStack.arrangedSubviews.first as? TableScrollBlock)
        #expect(fittedHeight(of: table) > heightBefore, "행이 늘면 표 높이도 는다")
        #expect(fittedHeight(of: table) == fittedHeight(of: referenceTable), "한 번에 그린 표와 높이가 같다")
        #expect(
            table.widthConstraints.map { $0.map(\.constant) }
                == referenceTable.widthConstraints.map { $0.map(\.constant) },
            "한 번에 그린 표와 열 폭이 같다"
        )
    }

    private func firstAttachment(in textView: UITextView) -> NSTextAttachment? {
        let attributed = textView.attributedText ?? NSAttributedString()
        var found: NSTextAttachment?
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let attachment = value as? NSTextAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }

    /// 표 스트리밍 tick은 바뀐 셀만 다시 채운다. 수식이 든 셀도 내용과 hydration이 그대로면 손대지 않는다
    /// (2026-10-15 시뮬레이터 실측: 수식 셀을 tick마다 전부 다시 채웠다).
    @Test func streamingKeepsUnchangedMathCellUntouched() async throws {
        let prefix = #"| 수식 | 값 |\#n| --- | ---: |\#n| \(a+b\) | "#
        let view = RichMarkdownUIView(markdown: prefix + "1")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitFor(view) {
            !$0.model.hasOutstandingWork && !$0.hasPendingRebuild && attachmentCount(in: $0) == 1
        }
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        let mathCell = table.cells[1][0]
        let attachment = try #require(firstAttachment(in: mathCell))

        view.markdown = prefix + "12"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.first === table)
        #expect(table.cells[1][1].text == "12")
        #expect(firstAttachment(in: mathCell) === attachment, "내용·hydration이 그대로인 수식 셀은 다시 채우지 않는다")
    }

    /// 표를 만든 뒤 도착한 셀 수식 raster도 그 셀에 반영한다. 셀 run은 그대로이고 이미지 사전만 바뀌는 게시다.
    @Test func streamingTableCellHydratesMathArrivingAfterBuild() async throws {
        let unique = UUID().uuidString.prefix(8)
        let prefix = "| 항목 | 수식 |\n| --- | --- |\n| 하나 | "
        let view = RichMarkdownUIView(markdown: prefix)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        let cell = table.cells[1][1]

        // 처음 보는 latex라 raster 캐시가 비어 있다 — 문서 게시 뒤 이미지 게시가 따로 온다.
        view.markdown = prefix + #"\(q_{\#(unique)}\)"#
        try await waitFor(view) {
            !$0.model.hasOutstandingWork && !$0.hasPendingRebuild && attachmentCount(in: $0) == 1
        }
        #expect(view.blockStack.arrangedSubviews.first === table, "같은 구조의 표는 제자리 갱신한다")
        #expect(table.cells[1][1] === cell)
        #expect(attachmentCount(in: cell) == 1, "늦게 도착한 raster도 셀에 붙는다")
        #expect((cell as RichMarkdownTextView).spokenOverride == "수식: q_{\(unique)}")
    }

    /// tail이 아닌 목록 항목도 늦게 도착한 수식 raster를 반영한다.
    @Test func streamingListItemHydratesMathArrivingAfterBuild() async throws {
        let unique = UUID().uuidString.prefix(8)
        let view = RichMarkdownUIView(markdown: #"- \(r_{\#(unique)}\)\#n- 둘"#)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitFor(view) {
            !$0.model.hasOutstandingWork && !$0.hasPendingRebuild && attachmentCount(in: $0) == 1
        }
        let list = try #require(view.blockStack.arrangedSubviews.first)
        #expect(textViews(in: list).count == 2)
        #expect(attachmentCount(in: textViews(in: list)[0]) == 1, "첫 항목의 수식이 hydration되어야 한다")
    }

    /// 생성 규칙의 표 높이: 확정 열 폭에서 셀마다 잰 높이의 행별 최대 합.
    private func perCellTableHeight(_ table: TableScrollBlock) -> CGFloat {
        let widths = table.widthConstraints.first?.map(\.constant) ?? []
        let height = table.cells.reduce(CGFloat.zero) { total, row in
            total + (zip(row, widths).map { cell, width in
                ceil(cell.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
            }.max() ?? 0)
        }
        return max(1, ceil(height))
    }

    /// 셀 크기 캐시(자연 폭에 들면 자연 높이, 줄바꿈 셀만 열 폭에서 재측정)는 셀마다 열 폭에서 잰 높이와 같다.
    /// 정렬·수식·코드·링크가 섞이고 열 폭 상한에 눌려 줄바꿈되는 셀이 스트리밍으로 자라는 경우를 본다.
    @Test func cachedTableLayoutMatchesPerCellMeasurement() async throws {
        let prefix = #"""
        | 왼쪽 | 가운데 | 오른쪽 |
        | :--- | :---: | ---: |
        | 짧음 | \(x^2+1\) | 1 |
        | `code` | **굵게** | [링크](https://example.com) |
        | 아주
        """#
        let view = RichMarkdownUIView(markdown: prefix)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitFor(view) {
            !$0.model.hasOutstandingWork && !$0.hasPendingRebuild && attachmentCount(in: $0) == 1
        }
        let table = try #require(view.blockStack.arrangedSubviews.first as? TableScrollBlock)
        #expect(fittedHeight(of: table) == perCellTableHeight(table))

        var markdown = prefix
        for _ in 0..<6 {
            markdown += String(repeating: " 긴 설명", count: 8)
            view.markdown = markdown
            try await waitForRender(view)
            #expect(view.blockStack.arrangedSubviews.first === table, "같은 구조의 표는 제자리 갱신한다")
            #expect(fittedHeight(of: table) == perCellTableHeight(table), "캐시한 높이가 셀별 측정과 같아야 한다")
        }
        #expect(table.widthConstraints[0][0].constant == 240, "긴 셀은 열 폭 상한에서 줄바꿈한다")
    }

    /// 항목 수가 같은 목록은 마지막 항목의 문단만 갱신한다.
    @Test func streamingUpdatesTailListItemInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "- 하나\n- 둘")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.count == 1)
        let listBefore = view.blockStack.arrangedSubviews[0]
        let itemsBefore = textViews(in: listBefore)
        #expect(itemsBefore.count == 2)

        view.markdown = "- 하나\n- 둘째"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews[0] === listBefore, "항목 수가 같으면 목록 뷰를 유지한다")
        #expect(zip(textViews(in: listBefore), itemsBefore).allSatisfy { $0 === $1 })
        #expect(renderedText(in: listBefore).contains("둘째"))

        view.markdown = "- 하나\n- 둘째\n- 셋"
        try await waitForRender(view)
        #expect(textViews(in: view.blockStack.arrangedSubviews[0]).count == 3, "항목이 늘면 새 항목이 붙는다")
    }

    private func listMarkers(in list: UIView) -> [String?] {
        (list as? UIStackView)?.arrangedSubviews.map {
            (($0 as? UIStackView)?.arrangedSubviews.first as? UILabel)?.text
        } ?? []
    }

    /// 항목이 늘어나는 tick도 목록을 다시 만들지 않는다. 기존 항목은 그대로 두고 새 항목만 붙인다.
    @Test func streamingAppendsListItemInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "3. 하나\n4. 둘")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let list = try #require(view.blockStack.arrangedSubviews.first)
        let itemsBefore = textViews(in: list)
        #expect(itemsBefore.count == 2)

        view.markdown = "3. 하나\n4. 둘\n5. 셋"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.first === list, "항목이 늘어도 목록 뷰를 유지한다")
        let itemsAfter = textViews(in: list)
        #expect(itemsAfter.count == 3)
        #expect(zip(itemsAfter, itemsBefore).allSatisfy { $0 === $1 }, "기존 항목 뷰를 유지한다")
        #expect(listMarkers(in: list) == ["3.", "4.", "5."])
        let formerTail = itemsAfter[1]
        #expect(
            foregroundAlpha(in: formerTail, at: formerTail.attributedText.length - 1) == 1,
            "tail에서 벗어난 항목은 페이드를 걷어낸다"
        )
    }

    /// 인용도 자식 블록이 늘면 새 자식만 붙인다.
    @Test func streamingAppendsQuoteChildInPlace() async throws {
        let view = RichMarkdownUIView(markdown: "> 하나\n>\n> 둘")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let quote = try #require(view.blockStack.arrangedSubviews.first)
        let childrenBefore = textViews(in: quote)
        #expect(childrenBefore.count == 2)

        view.markdown = "> 하나\n>\n> 둘\n>\n> 셋"
        try await waitForRender(view)
        #expect(view.blockStack.arrangedSubviews.first === quote, "자식이 늘어도 인용 뷰를 유지한다")
        let childrenAfter = textViews(in: quote)
        #expect(childrenAfter.count == 3)
        #expect(zip(childrenAfter, childrenBefore).allSatisfy { $0 === $1 }, "기존 자식 뷰를 유지한다")
        #expect(renderedText(in: quote).contains("셋"))
    }

    @Test func streamingInstallsChipDecorationWhenInlineCodeCloses() async throws {
        let view = RichMarkdownUIView(markdown: "a `co")
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)
        let textView = try #require(textViews(in: view).first as? RichMarkdownTextView)
        #expect(textView.inlineCodeDecoration == nil)
        #expect(!renderedText(in: view).contains("`"), "미닫힌 백틱은 숨긴다")

        view.markdown = "a `code` b"
        try await waitForRender(view)
        #expect(textViews(in: view).first === textView, "같은 뷰를 유지한다")
        #expect(textView.inlineCodeDecoration != nil, "백틱이 닫히면 칩 장식을 그 자리에서 설치한다")
    }
}
