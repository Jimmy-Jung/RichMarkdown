import Foundation
import Testing
@testable import SwiftLatex
@testable import SwiftLatexHighlight

/// 번들 Prism을 JavaScriptCore에서 실제로 실행해 검증한다. 모킹하지 않는다.
@Suite struct PrismHighlighterTests {

    /// 색 범위가 원문을 한 글자도 바꾸거나 빠뜨리지 않는지 확인한다.
    /// 렌더러는 이 구간 분할로 화면 문자열을 만들므로 이 성질이 곧 표시 정확성이다.
    private func expectLossless(
        _ code: String,
        spans: [LatexHighlightSpan],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let segments = LatexHighlightSegments.segments(code: code, spans: spans)
        let rebuilt = segments.map { String($0.text) }.joined()
        #expect(rebuilt == code, "구간을 이어 붙인 결과가 원문과 달라졌다", sourceLocation: sourceLocation)
    }

    private func kinds(_ spans: [LatexHighlightSpan]) -> Set<LatexHighlightKind> {
        Set(spans.map(\.kind))
    }

    // MARK: - 실제 문법

    @Test func swiftCodeProducesKeywordStringCommentSpans() async {
        let code = """
        // 원의 넓이
        struct Circle {
            let radius: Double
            func area() -> Double { .pi * radius * radius }
            var label: String { "원 r=\\(radius)" }
        }
        """
        let spans = await PrismHighlighter().spans(for: code, language: "swift")

        #expect(!spans.isEmpty)
        #expect(kinds(spans).isSuperset(of: [.keyword, .comment, .string]))
        expectLossless(code, spans: spans)
    }

    @Test func jsonSeparatesPropertyFromString() async {
        let code = #"{"name": "SwiftLatex", "version": 7, "beta": true}"#
        let spans = await PrismHighlighter().spans(for: code, language: "json")

        #expect(kinds(spans).contains(.property))
        #expect(kinds(spans).contains(.string))
        #expect(kinds(spans).contains(.number))
        expectLossless(code, spans: spans)

        // `"name"`은 property, `"SwiftLatex"`는 string이어야 한다 — 실제 문자로 확인한다.
        let property = spans.first { $0.kind == .property }
        let propertyText = property.flatMap { Range($0.range, in: code) }.map { String(code[$0]) }
        #expect(propertyText == #""name""#)
    }

    @Test(arguments: [
        "javascript", "typescript", "python", "bash", "kotlin", "java",
        "c", "cpp", "go", "rust", "sql", "yaml", "css", "markup", "jsx", "tsx",
    ])
    func bundledGrammarsLoad(_ language: String) async {
        // 문법마다 유효한 최소 조각. 로드에 실패하면 빈 배열이 되므로 그것으로 판정한다.
        let samples: [String: String] = [
            "javascript": "const a = 1; // c",
            "typescript": "const a: number = 1;",
            "python": "def f(x):\n    return 'a'",
            "bash": "echo \"hi\" # c",
            "kotlin": "val a: Int = 1",
            "java": "class A { int b = 1; }",
            "c": "int main(void) { return 0; }",
            "cpp": "#include <vector>\nint main() { return 0; }",
            "go": "func main() { println(\"hi\") }",
            "rust": "fn main() { let x = 1; }",
            "sql": "SELECT id FROM users WHERE id = 1;",
            "yaml": "name: SwiftLatex\nversion: 7",
            "css": ".a { color: red; }",
            "markup": "<p class=\"a\">hi</p>",
            "jsx": "const a = <div className=\"b\">hi</div>;",
            "tsx": "const a: JSX.Element = <div>hi</div>;",
        ]
        let code = samples[language]!
        let spans = await PrismHighlighter().spans(for: code, language: language)

        #expect(!spans.isEmpty, "\(language) 문법이 색 범위를 만들지 못했다")
        expectLossless(code, spans: spans)
    }

    // MARK: - 별칭

    @Test(arguments: [
        ("JS", "javascript"), ("Py", "python"), ("c++", "cpp"),
        ("rs", "rust"), ("sh", "bash"), ("yml", "yaml"), ("kt", "kotlin"),
    ])
    func aliasesResolveToSameSpansAsCanonicalName(_ pair: (alias: String, canonical: String)) async {
        let samples: [String: String] = [
            "javascript": "const a = 1;",
            "python": "x = 'a'",
            "cpp": "int a = 1;",
            "rust": "let x = 1;",
            "bash": "echo hi",
            "yaml": "a: 1",
            "kotlin": "val a = 1",
        ]
        let code = samples[pair.canonical]!
        let highlighter = PrismHighlighter()
        let viaAlias = await highlighter.spans(for: code, language: pair.alias)
        let viaCanonical = await highlighter.spans(for: code, language: pair.canonical)

        #expect(!viaAlias.isEmpty, "\(pair.alias)가 문법을 찾지 못했다")
        #expect(viaAlias == viaCanonical)
    }

    // MARK: - Unicode

    @Test func koreanAndEmojiRangesStayOnCharacterBoundaries() async {
        let code = """
        // 한글 주석 🎯 이모지
        let 인사 = "안녕하세요 👋 SwiftLatex"
        """
        let spans = await PrismHighlighter().spans(for: code, language: "swift")

        #expect(!spans.isEmpty)
        for span in spans {
            // UTF-16 범위가 서러게이트 쌍을 가르면 nil이 된다.
            #expect(Range(span.range, in: code) != nil, "범위가 Character 경계를 깼다: \(span)")
        }
        expectLossless(code, spans: spans)
    }

    // MARK: - fallback 계약

    @Test func unsupportedLanguageReturnsNoSpans() async {
        let spans = await PrismHighlighter().spans(for: "SOME TEXT", language: "brainfuck")
        #expect(spans.isEmpty)
    }

    @Test func emptyCodeReturnsNoSpans() async {
        let spans = await PrismHighlighter().spans(for: "", language: "swift")
        #expect(spans.isEmpty)
    }

    @Test func oversizeCodeReturnsNoSpans() async {
        let code = String(repeating: "let a = 1\n", count: 20_000)
        #expect(code.utf16.count > PrismHighlighter.maxCodeUTF16Units)

        let spans = await PrismHighlighter().spans(for: code, language: "swift")
        #expect(spans.isEmpty)
    }

    @Test func resetRebuildsContextAndKeepsResults() async {
        let highlighter = PrismHighlighter()
        let code = "let a = 1 // c"
        let before = await highlighter.spans(for: code, language: "swift")
        await highlighter.reset()
        let after = await highlighter.spans(for: code, language: "swift")

        #expect(!before.isEmpty)
        #expect(before == after)
    }

    // MARK: - 역할 매핑

    @Test func operatorsAndPunctuationStayUncolored() {
        #expect(PrismHighlighter.kind(for: "operator") == nil)
        #expect(PrismHighlighter.kind(for: "punctuation") == nil)
        #expect(PrismHighlighter.kind(for: "plain") == nil)
    }

    @Test func dottedPrismTypeUsesItsCategory() {
        #expect(PrismHighlighter.kind(for: "string.special") == .string)
        #expect(PrismHighlighter.kind(for: "class-name") == .type)
        #expect(PrismHighlighter.kind(for: "function-variable") == .function)
    }
}
