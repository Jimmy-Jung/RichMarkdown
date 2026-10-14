// Author: JunyoungJung
// Date: 2026-10-14

import Foundation
import Testing
@testable import RichMarkdown
@testable import RichMarkdownHighlight

/// 번들된 Prism 문법 전체의 토큰 범위 계약과 큰 입력 시간 예산.
///
/// 언어 목록은 번들 `Prism/prism-*.js`에서 읽는다. 문법을 추가하고 대표 조각을 넣지 않으면
/// `everyBundledGrammarHasASnippet`가 실패한다.
@Suite struct PrismLanguageCoverageTests {

    /// 모든 조각에 한글·이모지(서러게이트 쌍, ZWJ, 국기)를 문자열이나 주석으로 넣는다.
    static let snippets: [String: String] = [
        "clike": "if (a) { return \"한글 👩‍💻\"; } // 주석 🇰🇷",
        "markup": "<p class=\"인사\">안녕 👋</p><!-- 주석 🇰🇷 -->",
        "css": "/* 한글 🎨 */ .제목 { color: red; content: \"👩‍💻\"; }",
        "javascript": "const 인사 = `안녕 ${name} 👋`; // 주석 🇰🇷",
        "jsx": "const a = <div title=\"한글 👩‍💻\">안녕 🇰🇷</div>;",
        "typescript": "const 값: string = \"한글 👋\"; // 주석 🇰🇷",
        "tsx": "const a: JSX.Element = <b>안녕 👩‍💻</b>; // 🇰🇷",
        "swift": "// 주석 🇰🇷\nlet 인사 = \"안녕하세요 👋 \\(name)\"",
        "python": "# 주석 🇰🇷\ndef 인사():\n    return f\"안녕 👩‍💻 {name}\"",
        "json": "{\"이름\": \"한글 👋\", \"값\": 7, \"참\": true}",
        "bash": "echo \"안녕 👩‍💻\" # 주석 🇰🇷",
        "kotlin": "val 인사: String = \"안녕 👋 $name\" // 🇰🇷",
        "java": "String s = \"한글 👩‍💻\"; // 주석 🇰🇷",
        "c": "/* 한글 🇰🇷 */ int main(void) { puts(\"안녕 👋\"); return 0; }",
        "cpp": "#include <string>\nauto s = std::string(\"한글 👩‍💻\"); // 🇰🇷",
        "go": "func main() { fmt.Println(\"안녕 👋\") } // 주석 🇰🇷",
        "rust": "fn main() { let s = \"한글 👩‍💻\"; } // 주석 🇰🇷",
        "sql": "SELECT '한글 👋' AS 인사 FROM t WHERE id = 1; -- 주석 🇰🇷",
        "yaml": "이름: \"한글 👩‍💻\"\n버전: 7 # 주석 🇰🇷",
    ]

    /// 번들의 `prism-<언어>.js`. `prism-core`는 문법이 아니라 엔진이다.
    static let bundledGrammars: [String] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "js", subdirectory: "Prism") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.hasPrefix("prism-") && $0 != "prism-core" }
            .map { String($0.dropFirst("prism-".count)) }
            .sorted()
    }()

    @Test func everyBundledGrammarHasASnippet() {
        #expect(Self.bundledGrammars.count == 19, "번들 문법 수: \(Self.bundledGrammars)")
        #expect(Set(Self.bundledGrammars) == Set(Self.snippets.keys))
    }

    @Test(arguments: bundledGrammars)
    func spansStayInsideTheSourceOnCharacterBoundaries(_ language: String) async throws {
        let code = try #require(Self.snippets[language])
        let spans = await PrismHighlighter().spans(for: code, language: language)

        #expect(!spans.isEmpty, "\(language) 문법이 색 범위를 만들지 못했다")
        Self.expectWellFormed(spans, in: code, language: language)
    }

    /// 범위가 원문 안에 있고, 겹치지 않고 오름차순이며, UTF-16 경계가 Character 경계와 맞는다.
    static func expectWellFormed(
        _ spans: [RichMarkdownHighlightSpan],
        in code: String,
        language: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let length = code.utf16.count
        var previousEnd = 0
        for span in spans {
            let range = span.range
            #expect(range.length > 0, "\(language): 빈 범위 \(range)", sourceLocation: sourceLocation)
            #expect(range.location >= previousEnd, "\(language): 겹치거나 역순 \(range)", sourceLocation: sourceLocation)
            #expect(NSMaxRange(range) <= length, "\(language): 원문 밖 \(range)", sourceLocation: sourceLocation)
            #expect(Range(range, in: code) != nil, "\(language): Character 경계를 깼다 \(range)", sourceLocation: sourceLocation)
            previousEnd = max(previousEnd, NSMaxRange(range))
        }
        let rebuilt = RichMarkdownHighlightSegments.segments(code: code, spans: spans)
            .map { String($0.text) }
            .joined()
        #expect(rebuilt == code, "\(language): 구간을 이어 붙인 결과가 원문과 다르다", sourceLocation: sourceLocation)
    }

    // MARK: - 미지원 언어

    /// 미지원 이름은 빈 배열(원문 표시)이다. `Prism.languages`의 메서드·Object 프로토타입
    /// 이름도 문법으로 취급하지 않고, 그 뒤 같은 context가 정상 문법을 계속 처리한다.
    @Test func unknownLanguagesFallBackToPlainWithoutPoisoningTheContext() async {
        let highlighter = PrismHighlighter()
        let code = "let 인사 = \"안녕 👋\" // 🇰🇷"
        for language in ["", "brainfuck", "swift5", "extend", "insertBefore", "DFS",
                         "__proto__", "constructor", "toString", "hasOwnProperty"] {
            let spans = await highlighter.spans(for: code, language: language)
            #expect(spans.isEmpty, "'\(language)'는 미지원 언어로 원문을 두어야 한다: \(spans)")
        }
        let swift = await highlighter.spans(for: code, language: "swift")
        #expect(!swift.isEmpty, "미지원 요청 뒤에도 같은 context가 정상 문법을 처리해야 한다")
        Self.expectWellFormed(swift, in: code, language: "swift")
    }

    // MARK: - 큰 입력

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// 한글·이모지가 섞인 Swift 줄을 UTF-16 목표 길이까지 반복한다.
    private static func swiftSource(utf16Target: Int) -> String {
        let line = "let 값 = \"한글 👩‍💻\" + String(42) // 주석 🇰🇷\n"
        let count = utf16Target / line.utf16.count
        return String(repeating: line, count: count)
    }

    /// 1 MB 입력은 블록 상한(UTF-16 100,000) 밖이다. 토큰화하지 않고 바로 원문으로 돌아와야 한다.
    @Test func oneMegabyteInputReturnsPlainWithinBudget() async {
        let code = Self.swiftSource(utf16Target: 1_048_576)
        #expect(code.utf8.count >= 1_000_000)
        let highlighter = PrismHighlighter()
        _ = await highlighter.spans(for: "let a = 1", language: "swift") // context 초기화 제외

        let start = ContinuousClock.now
        let spans = await highlighter.spans(for: code, language: "swift")
        let elapsed = ContinuousClock.now - start

        #expect(spans.isEmpty, "상한 초과 입력은 색을 입히지 않는다")
        Attachment.record("1 MB(\(code.utf8.count) bytes) → \(Self.milliseconds(elapsed)) ms", named: "prism-1mb.txt")
        // 길이 검사만 하므로 Debug 시뮬레이터에서도 수 ms다. 1초는 토큰화가 섞였다는 신호다.
        #expect(elapsed < .seconds(1), "1 MB 거부가 \(elapsed) 걸렸다")
    }

    /// 상한 바로 아래(UTF-16 100,000 이하)가 실제 최악 토큰화 비용이다.
    @Test func largestAcceptedInputTokenizesWithinBudget() async {
        let code = Self.swiftSource(utf16Target: PrismHighlighter.maxCodeUTF16Units)
        #expect(code.utf16.count <= PrismHighlighter.maxCodeUTF16Units)
        let highlighter = PrismHighlighter()
        _ = await highlighter.spans(for: "let a = 1", language: "swift")

        let start = ContinuousClock.now
        let spans = await highlighter.spans(for: code, language: "swift")
        let elapsed = ContinuousClock.now - start

        #expect(!spans.isEmpty)
        Self.expectWellFormed(spans, in: code, language: "swift")
        Attachment.record(
            "\(code.utf16.count) UTF-16 units(\(code.utf8.count) bytes) → \(Self.milliseconds(elapsed)) ms, spans \(spans.count)",
            named: "prism-max-accepted.txt"
        )
        // Debug 시뮬레이터 기준 넉넉한 예산. 코드 블록 하이라이트는 비동기라 화면을 막지 않지만
        // 이 이상이면 스트리밍 tick마다 같은 블록을 다시 칠하는 비용이 체감된다.
        #expect(elapsed < .seconds(10), "상한 크기 토큰화가 \(elapsed) 걸렸다")
    }
}
