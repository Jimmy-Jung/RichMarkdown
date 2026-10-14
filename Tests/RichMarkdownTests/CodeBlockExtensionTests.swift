import Foundation
import SwiftUI
import Testing
import UIKit
@testable import RichMarkdown

/// 코드 블록 확장점 계약. 하이라이터·다이어그램 구현체 없이 코어만 검증한다.
@MainActor
@Suite struct CodeBlockExtensionTests {

    // MARK: - 스텁

    /// 지정한 범위를 그대로 돌려주는 최소 하이라이터.
    private final class FixedSpanHighlighter: RichMarkdownSyntaxHighlighting {
        private let fixed: [RichMarkdownHighlightSpan]
        init(_ fixed: [RichMarkdownHighlightSpan]) { self.fixed = fixed }
        func spans(for code: String, language: String) async -> [RichMarkdownHighlightSpan] { fixed }
    }

    private final class MarkerDiagramRenderer: RichMarkdownDiagramRendering {
        let languages: Set<String> = ["diagram"]

        @MainActor func makeUIView(
            source: String,
            theme: RichMarkdownTheme,
            onSizeChange: @escaping @MainActor () -> Void
        ) -> UIView {
            let view = UIView()
            view.accessibilityIdentifier = "stub.diagram"
            return view
        }

        @MainActor func makeSwiftUIView(source: String, theme: RichMarkdownTheme) -> AnyView {
            AnyView(Color.clear)
        }
    }

    /// 만든 뷰 수와 원문 갱신 호출을 센다. `supportsUpdate`가 false면 기본 구현(갱신 불가)을 흉내 낸다.
    @MainActor
    private final class CountingDiagramRenderer: RichMarkdownDiagramRendering {
        nonisolated let languages: Set<String> = ["diagram"]
        let supportsUpdate: Bool
        var created = 0
        var lastSource = ""

        init(supportsUpdate: Bool) { self.supportsUpdate = supportsUpdate }

        func makeUIView(
            source: String,
            theme: RichMarkdownTheme,
            onSizeChange: @escaping @MainActor () -> Void
        ) -> UIView {
            created += 1
            lastSource = source
            let view = UIView()
            view.accessibilityIdentifier = "stub.diagram"
            return view
        }

        func updateUIView(_ view: UIView, source: String, theme: RichMarkdownTheme) -> Bool {
            guard supportsUpdate, view.accessibilityIdentifier == "stub.diagram" else { return false }
            lastSource = source
            return true
        }

        func makeSwiftUIView(source: String, theme: RichMarkdownTheme) -> AnyView {
            AnyView(Color.clear)
        }
    }

    private func waitForRender(_ view: RichMarkdownUIView, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while view.model.hasOutstandingWork || view.hasPendingRebuild {
            #expect(Date() < deadline, "렌더가 제한 시간 안에 끝나야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
            view.layoutIfNeeded()
        }
        view.layoutIfNeeded()
    }

    private func findView(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let found = findView(in: subview, identifier: identifier) { return found }
        }
        return nil
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let textView = view as? UITextView { found.append(textView) }
        for subview in view.subviews { found.append(contentsOf: textViews(in: subview)) }
        return found
    }

    // MARK: - 구간 분할

    @Test func noSpansKeepsOneUncoloredSegment() {
        let segments = RichMarkdownHighlightSegments.segments(code: "let a = 1", spans: [])
        #expect(segments.count == 1)
        #expect(segments[0].kind == nil)
        #expect(String(segments[0].text) == "let a = 1")
    }

    @Test func segmentsPreserveSourceExactly() {
        let code = "let 인사 = \"안녕 👋\" // 주석"
        let spans = [
            RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            RichMarkdownHighlightSpan(range: NSRange(location: 9, length: 8), kind: .string),
        ]
        let rebuilt = RichMarkdownHighlightSegments.segments(code: code, spans: spans)
            .map { String($0.text) }
            .joined()
        #expect(rebuilt == code)
    }

    @Test func invalidSpansAreDroppedWithoutLosingText() {
        let code = "let a = 1"
        let spans = [
            RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            // 앞 span과 겹친다.
            RichMarkdownHighlightSpan(range: NSRange(location: 2, length: 3), kind: .string),
            // 원문 밖이다.
            RichMarkdownHighlightSpan(range: NSRange(location: 50, length: 3), kind: .number),
            // 길이가 0이다.
            RichMarkdownHighlightSpan(range: NSRange(location: 4, length: 0), kind: .number),
        ]
        let segments = RichMarkdownHighlightSegments.segments(code: code, spans: spans)

        #expect(segments.map { String($0.text) }.joined() == code)
        #expect(segments.filter { $0.kind != nil }.count == 1)
    }

    @Test func extremeHighlightRangesPreserveSourceInBothRenderers() {
        let code = "let 한글 = \"🙂e\u{301}\""
        let spans = [
            RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            RichMarkdownHighlightSpan(range: NSRange(location: -1, length: 1), kind: .string),
            RichMarkdownHighlightSpan(range: NSRange(location: 4, length: -1), kind: .string),
            RichMarkdownHighlightSpan(range: NSRange(location: 1, length: Int.max), kind: .number),
            RichMarkdownHighlightSpan(range: NSRange(location: Int.max, length: 1), kind: .number),
        ]
        let segments = RichMarkdownHighlightSegments.segments(code: code, spans: spans)
        #expect(segments.map { String($0.text) }.joined() == code)
        #expect(segments.compactMap(\.kind) == [.keyword])
        #expect(RichMarkdownHighlightSegments.attributed(
            code: code, spans: spans, colors: .default,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular), textColor: .label
        ).string == code)
        #expect(String(RichMarkdownHighlightSegments.attributedString(
            code: code, spans: spans, colors: .default
        ).characters) == code)
    }

    @Test func spansOutOfOrderAreSortedBeforeUse() {
        let code = "abcdef"
        let spans = [
            RichMarkdownHighlightSpan(range: NSRange(location: 3, length: 3), kind: .string),
            RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
        ]
        let segments = RichMarkdownHighlightSegments.segments(code: code, spans: spans)

        #expect(segments.map { String($0.text) } == ["abc", "def"])
        #expect(segments.map(\.kind) == [.keyword, .string])
    }

    @Test func attributedOutputsKeepTheOriginalCharacters() {
        let code = "func f() { return \"값\" } // 끝 🎯"
        let spans = [RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 4), kind: .keyword)]

        let uikit = RichMarkdownHighlightSegments.attributed(
            code: code,
            spans: spans,
            colors: .default,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: .label
        )
        let swiftUI = RichMarkdownHighlightSegments.attributedString(code: code, spans: spans, colors: .default)

        #expect(uikit.string == code)
        #expect(String(swiftUI.characters) == code)
    }

    // MARK: - 테마

    @Test func syntaxColorsCoverEveryKind() {
        let colors = RichMarkdownSyntaxColors.default
        var seen = Set<Color>()
        for kind in RichMarkdownHighlightKind.allCases {
            seen.insert(colors.color(for: kind))
        }
        #expect(seen.count == RichMarkdownHighlightKind.allCases.count, "역할마다 서로 다른 색이어야 한다")
    }

    @Test func syntaxColorsAreThemeValueAndAffectEquality() {
        var custom = RichMarkdownTheme.default
        custom.syntax.keyword = .red
        #expect(custom != RichMarkdownTheme.default)
    }

    // MARK: - 주입 계약

    @Test func optionsOnlyMatchRegisteredLanguages() {
        let options = RichMarkdownCodeBlockOptions(diagram: MarkerDiagramRenderer())
        #expect(options.diagramRenderer(for: "diagram") != nil)
        #expect(options.diagramRenderer(for: "DIAGRAM") != nil)
        #expect(options.diagramRenderer(for: "mermaid") == nil)
    }

    @Test func defaultOptionsChangeNothing() async throws {
        let view = RichMarkdownUIView(markdown: "```swift\nlet a = 1\n```")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(view.blockStack.arrangedSubviews.count == 1)
        #expect(textViews(in: view).contains { $0.text == "let a = 1" })
    }

    // MARK: - UIKit 배선

    @Test func highlighterColorsCodeBlockWithoutChangingText() async throws {
        let code = "let a = 1"
        let view = RichMarkdownUIView(markdown: "```swift\n\(code)\n```")
        view.codeBlocks = RichMarkdownCodeBlockOptions(
            highlighter: FixedSpanHighlighter([
                RichMarkdownHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            ])
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let baseColor = UIColor(RichMarkdownTheme.default.textColor)
        let deadline = Date().addingTimeInterval(5)
        var colored: UITextView?
        while colored == nil, Date() < deadline {
            colored = textViews(in: view).first { textView in
                guard textView.text == code, let attributed = textView.attributedText else { return false }
                var found = false
                attributed.enumerateAttribute(
                    .foregroundColor,
                    in: NSRange(location: 0, length: attributed.length)
                ) { value, _, _ in
                    if let color = value as? UIColor, color != baseColor { found = true }
                }
                return found
            }
            if colored == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }

        #expect(colored != nil, "하이라이터 범위가 코드 블록 색으로 반영되어야 한다")
        #expect(colored?.text == code, "색만 바뀌고 원문은 그대로여야 한다")
    }

    @Test func diagramRendererReplacesMatchingCodeBlockBody() async throws {
        let view = RichMarkdownUIView(markdown: "```diagram\nA --> B\n```")
        view.codeBlocks = RichMarkdownCodeBlockOptions(diagram: MarkerDiagramRenderer())
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(findView(in: view, identifier: "stub.diagram") != nil)
        #expect(!textViews(in: view).contains { $0.text == "A --> B" })
    }

    @Test func diagramRendererLeavesOtherLanguagesAsCode() async throws {
        let view = RichMarkdownUIView(markdown: "```swift\nlet a = 1\n```")
        view.codeBlocks = RichMarkdownCodeBlockOptions(diagram: MarkerDiagramRenderer())
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(findView(in: view, identifier: "stub.diagram") == nil)
        #expect(textViews(in: view).contains { $0.text == "let a = 1" })
    }

    /// 스트리밍으로 다이어그램 원문이 자라는 동안 UIKit 렌더러가 tick마다 다이어그램 뷰(실제로는 WKWebView)를
    /// 새로 만들지 않는다. SwiftUI 경로(`updateUIView`)와 같은 재사용 계약이다 (iPad Pro M5 실측: 6 스칼라 조각에서 25회 생성).
    @Test func streamingDiagramReusesViewWhenRendererSupportsUpdate() async throws {
        let renderer = CountingDiagramRenderer(supportsUpdate: true)
        let view = RichMarkdownUIView()
        view.codeBlocks = RichMarkdownCodeBlockOptions(diagram: renderer)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)

        for source in ["A", "A --> B", "A --> B\nB --> C"] {
            view.markdown = "앞 문단\n\n```diagram\n\(source)"
            try await waitForRender(view)
        }
        view.streaming = nil
        try await waitForRender(view)

        #expect(renderer.created == 1, "같은 다이어그램 블록은 뷰를 한 번만 만든다")
        #expect(renderer.lastSource == "A --> B\nB --> C", "기존 뷰에 마지막 원문이 전달돼야 한다")
        let copy = view.blockStack.arrangedSubviews.last.flatMap { findCopyButton(in: $0) }
        #expect(copy?.payload == "A --> B\nB --> C", "복사 버튼도 마지막 원문을 복사해야 한다")
    }

    @Test func streamingDiagramFallsBackToRecreationWithoutUpdateSupport() async throws {
        let renderer = CountingDiagramRenderer(supportsUpdate: false)
        let view = RichMarkdownUIView()
        view.codeBlocks = RichMarkdownCodeBlockOptions(diagram: renderer)
        view.streaming = .default
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)

        for source in ["A", "A --> B"] {
            view.markdown = "```diagram\n\(source)"
            try await waitForRender(view)
        }

        #expect(renderer.created == 2, "갱신을 지원하지 않는 렌더러는 지금처럼 새 뷰를 받는다")
        #expect(renderer.lastSource == "A --> B")
    }

    private func findCopyButton(in view: UIView) -> RichMarkdownCopyButton? {
        if let button = view as? RichMarkdownCopyButton { return button }
        for subview in view.subviews {
            if let found = findCopyButton(in: subview) { return found }
        }
        return nil
    }
}
