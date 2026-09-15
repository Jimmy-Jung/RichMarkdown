import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SwiftLatex

/// 코드 블록 확장점 계약. 하이라이터·다이어그램 구현체 없이 코어만 검증한다.
@MainActor
@Suite struct CodeBlockExtensionTests {

    // MARK: - 스텁

    /// 지정한 범위를 그대로 돌려주는 최소 하이라이터.
    private final class FixedSpanHighlighter: LatexSyntaxHighlighting {
        private let fixed: [LatexHighlightSpan]
        init(_ fixed: [LatexHighlightSpan]) { self.fixed = fixed }
        func spans(for code: String, language: String) async -> [LatexHighlightSpan] { fixed }
    }

    private final class MarkerDiagramRenderer: LatexDiagramRendering {
        let languages: Set<String> = ["diagram"]

        @MainActor func makeUIView(
            source: String,
            theme: LatexTheme,
            onSizeChange: @escaping @MainActor () -> Void
        ) -> UIView {
            let view = UIView()
            view.accessibilityIdentifier = "stub.diagram"
            return view
        }

        @MainActor func makeSwiftUIView(source: String, theme: LatexTheme) -> AnyView {
            AnyView(Color.clear)
        }
    }

    private func waitForRender(_ view: LatexMarkdownUIView, timeout: TimeInterval = 10) async throws {
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
        let segments = LatexHighlightSegments.segments(code: "let a = 1", spans: [])
        #expect(segments.count == 1)
        #expect(segments[0].kind == nil)
        #expect(String(segments[0].text) == "let a = 1")
    }

    @Test func segmentsPreserveSourceExactly() {
        let code = "let 인사 = \"안녕 👋\" // 주석"
        let spans = [
            LatexHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            LatexHighlightSpan(range: NSRange(location: 9, length: 8), kind: .string),
        ]
        let rebuilt = LatexHighlightSegments.segments(code: code, spans: spans)
            .map { String($0.text) }
            .joined()
        #expect(rebuilt == code)
    }

    @Test func invalidSpansAreDroppedWithoutLosingText() {
        let code = "let a = 1"
        let spans = [
            LatexHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            // 앞 span과 겹친다.
            LatexHighlightSpan(range: NSRange(location: 2, length: 3), kind: .string),
            // 원문 밖이다.
            LatexHighlightSpan(range: NSRange(location: 50, length: 3), kind: .number),
            // 길이가 0이다.
            LatexHighlightSpan(range: NSRange(location: 4, length: 0), kind: .number),
        ]
        let segments = LatexHighlightSegments.segments(code: code, spans: spans)

        #expect(segments.map { String($0.text) }.joined() == code)
        #expect(segments.filter { $0.kind != nil }.count == 1)
    }

    @Test func spansOutOfOrderAreSortedBeforeUse() {
        let code = "abcdef"
        let spans = [
            LatexHighlightSpan(range: NSRange(location: 3, length: 3), kind: .string),
            LatexHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
        ]
        let segments = LatexHighlightSegments.segments(code: code, spans: spans)

        #expect(segments.map { String($0.text) } == ["abc", "def"])
        #expect(segments.map(\.kind) == [.keyword, .string])
    }

    @Test func attributedOutputsKeepTheOriginalCharacters() {
        let code = "func f() { return \"값\" } // 끝 🎯"
        let spans = [LatexHighlightSpan(range: NSRange(location: 0, length: 4), kind: .keyword)]

        let uikit = LatexHighlightSegments.attributed(
            code: code,
            spans: spans,
            colors: .default,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            textColor: .label
        )
        let swiftUI = LatexHighlightSegments.attributedString(code: code, spans: spans, colors: .default)

        #expect(uikit.string == code)
        #expect(String(swiftUI.characters) == code)
    }

    // MARK: - 테마

    @Test func syntaxColorsCoverEveryKind() {
        let colors = LatexSyntaxColors.default
        var seen = Set<Color>()
        for kind in LatexHighlightKind.allCases {
            seen.insert(colors.color(for: kind))
        }
        #expect(seen.count == LatexHighlightKind.allCases.count, "역할마다 서로 다른 색이어야 한다")
    }

    @Test func syntaxColorsAreThemeValueAndAffectEquality() {
        var custom = LatexTheme.default
        custom.syntax.keyword = .red
        #expect(custom != LatexTheme.default)
    }

    // MARK: - 주입 계약

    @Test func optionsOnlyMatchRegisteredLanguages() {
        let options = LatexCodeBlockOptions(diagram: MarkerDiagramRenderer())
        #expect(options.diagramRenderer(for: "diagram") != nil)
        #expect(options.diagramRenderer(for: "DIAGRAM") != nil)
        #expect(options.diagramRenderer(for: "mermaid") == nil)
    }

    @Test func defaultOptionsChangeNothing() async throws {
        let view = LatexMarkdownUIView(markdown: "```swift\nlet a = 1\n```")
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(view.blockStack.arrangedSubviews.count == 1)
        #expect(textViews(in: view).contains { $0.text == "let a = 1" })
    }

    // MARK: - UIKit 배선

    @Test func highlighterColorsCodeBlockWithoutChangingText() async throws {
        let code = "let a = 1"
        let view = LatexMarkdownUIView(markdown: "```swift\n\(code)\n```")
        view.codeBlocks = LatexCodeBlockOptions(
            highlighter: FixedSpanHighlighter([
                LatexHighlightSpan(range: NSRange(location: 0, length: 3), kind: .keyword),
            ])
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        let baseColor = UIColor(LatexTheme.default.textColor)
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
        let view = LatexMarkdownUIView(markdown: "```diagram\nA --> B\n```")
        view.codeBlocks = LatexCodeBlockOptions(diagram: MarkerDiagramRenderer())
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(findView(in: view, identifier: "stub.diagram") != nil)
        #expect(!textViews(in: view).contains { $0.text == "A --> B" })
    }

    @Test func diagramRendererLeavesOtherLanguagesAsCode() async throws {
        let view = LatexMarkdownUIView(markdown: "```swift\nlet a = 1\n```")
        view.codeBlocks = LatexCodeBlockOptions(diagram: MarkerDiagramRenderer())
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        try await waitForRender(view)

        #expect(findView(in: view, identifier: "stub.diagram") == nil)
        #expect(textViews(in: view).contains { $0.text == "let a = 1" })
    }
}
