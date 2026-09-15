import Foundation
import JavaScriptCore
import SwiftLatex

/// 번들에 고정한 Prism을 JavaScriptCore에서 실행해 코드 블록의 색 범위를 만든다.
///
/// WebView도 HTML 변환도 쓰지 않는다. 사용자 코드는 실행할 스크립트에 이어 붙이지 않고
/// JavaScript 함수의 **문자열 인자**로만 전달한다. `evaluateScript`는 번들 리소스를
/// 초기화할 때만 호출한다.
///
/// ```swift
/// LatexMarkdownView(markdown: message)
///     .latexCodeBlocks(.init(highlighter: PrismHighlighter.shared))
/// ```
///
/// 실패와 미지원 언어는 던지지 않고 **빈 배열**이다 — 호출한 렌더러가 원문을 그대로 둔다.
public actor PrismHighlighter: LatexSyntaxHighlighting {
    /// 앱 하나에 context 하나면 충분하다. 여러 코드 블록의 요청은 actor가 직렬화한다.
    public static let shared = PrismHighlighter()

    /// 정규식 기반 토큰화의 상한. 코드 블록 하나가 이보다 길면 색을 입히지 않고 원문을 둔다.
    /// Markdown 입력 전체 상한(`InputLimits`, 256 KiB)과 별개로 **블록 단위**로 건다.
    public static let maxCodeUTF16Units = 100_000

    /// 로드 순서가 곧 의존 관계다. `clike`·`markup`·`javascript`·`c`는 자신을 확장하는
    /// 문법보다 먼저 와야 한다 (`Prism.languages.extend`).
    private static let scripts = [
        "prism-core",
        "prism-clike",
        "prism-markup",
        "prism-css",
        "prism-javascript",
        "prism-jsx",
        "prism-typescript",
        "prism-tsx",
        "prism-swift",
        "prism-python",
        "prism-json",
        "prism-bash",
        "prism-kotlin",
        "prism-java",
        "prism-c",
        "prism-cpp",
        "prism-go",
        "prism-rust",
        "prism-sql",
        "prism-yaml",
        "native-tokenize",
    ]

    /// Prism이 스스로 등록하지 않는 별칭만 담는다.
    /// `js`·`ts`·`py`·`sh`·`shell`·`kt`·`kts`·`yml`·`html`·`xml`·`svg`는
    /// 각 문법 파일이 `Prism.languages`에 직접 등록하므로 여기 없다.
    private static let aliases: [String: String] = [
        "c++": "cpp",
        "cxx": "cpp",
        "cc": "cpp",
        "objective-c++": "cpp",
        "golang": "go",
        "rs": "rust",
        "zsh": "bash",
        "console": "bash",
        "shell-session": "bash",
        "json5": "json",
        "jsonc": "json",
        "mysql": "sql",
        "postgres": "sql",
        "postgresql": "sql",
        "sqlite": "sql",
        "htm": "markup",
        "node": "javascript",
    ]

    private var context: JSContext?

    public init() {}

    public func spans(for code: String, language: String) async -> [LatexHighlightSpan] {
        // actor 큐에서 차례를 기다리는 동안 호출자가 사라질 수 있다(스트리밍 tick).
        // 실제로 실행을 시작하는 이 시점에 확인해 이미 버려진 요청을 토큰화하지 않는다.
        guard !Task.isCancelled else { return [] }

        let normalized = language.lowercased()
        let grammar = Self.aliases[normalized] ?? normalized
        guard !code.isEmpty, code.utf16.count <= Self.maxCodeUTF16Units else { return [] }

        do {
            let context = try loadedContext()
            let chunks = try tokenize(code, grammar: grammar, in: context)
            return try validatedSpans(chunks, source: code)
        } catch {
            // 미지원 문법·번들 손상·토큰 불일치 — 어느 쪽이든 원문을 그대로 표시한다.
            return []
        }
    }

    /// JSContext를 해제한다. 다음 호출에서 다시 초기화된다.
    /// `JSValue`나 네이티브 콜백을 보관하지 않아 context와 상호 참조하지 않는다.
    public func reset() {
        context = nil
    }

    // MARK: - JavaScriptCore

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        guard let created = JSContext() else { throw PrismError("JavaScriptCore context 생성 실패") }
        for name in Self.scripts {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "js",
                subdirectory: "Prism"
            ) else {
                throw PrismError("번들 리소스 없음: \(name).js")
            }
            let script = try String(contentsOf: url, encoding: .utf8)
            created.exception = nil
            created.evaluateScript(script, withSourceURL: url)
            if let exception = created.exception {
                throw PrismError(exception.toString() ?? "번들 스크립트 실행 실패: \(name).js")
            }
        }
        context = created
        return created
    }

    private func tokenize(
        _ source: String,
        grammar: String,
        in context: JSContext
    ) throws -> [[String: String]] {
        guard let function = context.objectForKeyedSubscript("nativeTokenize"), !function.isUndefined else {
            throw PrismError("토큰화 함수 없음")
        }
        context.exception = nil
        // 사용자 코드는 오직 인자로만 들어간다. 스크립트 문자열에 합치지 않는다.
        let value = function.call(withArguments: [source, grammar])
        if let exception = context.exception {
            throw PrismError(exception.toString() ?? "토큰화 오류")
        }
        guard let chunks = value?.toArray() as? [[String: String]] else {
            throw PrismError("토큰 변환 오류")
        }
        return chunks
    }

    // MARK: - 검증

    /// 조각을 UTF-16 범위로 바꾸고, 이어 붙인 결과가 원문과 **정확히** 같은지 확인한다.
    /// 한 글자라도 다르면 범위 전체를 버린다 — 잘못 밀린 색을 표시하지 않는다.
    private func validatedSpans(
        _ chunks: [[String: String]],
        source: String
    ) throws -> [LatexHighlightSpan] {
        var reconstructed = ""
        reconstructed.reserveCapacity(source.count)
        var offset = 0
        var spans: [LatexHighlightSpan] = []

        for chunk in chunks {
            guard let content = chunk["content"], let type = chunk["kind"] else {
                throw PrismError("토큰 필드 누락")
            }
            let length = content.utf16.count
            if length > 0, let kind = Self.kind(for: type) {
                let range = NSRange(location: offset, length: length)
                guard Range(range, in: source) != nil else { throw PrismError("유효하지 않은 UTF-16 범위") }
                spans.append(LatexHighlightSpan(range: range, kind: kind))
            }
            reconstructed += content
            offset += length
        }

        guard source.utf16.elementsEqual(reconstructed.utf16) else {
            throw PrismError("토큰 원문 불일치")
        }
        return spans
    }

    /// Prism 토큰 이름 → 테마 역할. 매핑이 없으면 `nil`이고 그 조각은 본문 색을 유지한다.
    ///
    /// `operator`·`punctuation`은 일부러 제외한다. 색을 주면 코드 대부분이 물들어
    /// 강조 대비가 사라진다.
    static func kind(for prismType: String) -> LatexHighlightKind? {
        // Prism은 `class-name` 같은 하이픈 이름과 `string.special` 같은 점 표기를 함께 쓴다.
        let category = prismType.split(separator: ".").first.map(String.init) ?? prismType
        switch category {
        case "keyword", "boolean", "constant", "atrule", "important", "null", "nil",
             "literal", "import", "module-declaration", "static", "directive",
             "directive-hash", "directive-name", "other-directive", "rule", "at":
            return .keyword

        case "string", "char", "character", "regex", "regex-source", "regex-delimiter",
             "regex-flags", "string-literal", "template-string", "triple-quoted-string",
             "raw-string", "attr-value", "url", "scalar":
            return .string

        case "comment", "doc-comment", "prolog", "doctype", "cdata", "shebang", "hashbang":
            return .comment

        case "number", "float", "color", "datetime":
            return .number

        case "class-name", "known-class-name", "builtin", "namespace", "constructor",
             "type-definition", "tag", "doctype-tag", "generic", "generics",
             "generic-function", "lifetime-annotation", "base-clause", "module",
             "entity", "named-entity", "package":
            return .type

        case "function", "function-name", "function-variable", "function-definition",
             "method", "macro", "macro-name":
            return .function

        case "property", "literal-property", "string-property", "attr-name", "attribute",
             "annotation", "decorator", "symbol", "label", "variable", "parameter",
             "property-access", "key", "selector", "environment":
            return .property

        default:
            return nil
        }
    }
}

private struct PrismError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}
