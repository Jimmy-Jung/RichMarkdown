import Foundation
@testable import RichMarkdownCore

/// 재현 가능한 fuzz용 PRNG (Tests/Fixtures/README.md §6). 두 플랫폼이 같은 수열을 낸다.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// `pick(n) = next() % n` (부호 없는 64-bit 나머지).
    mutating func pick(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }
}

/// `.meta.json` 사이드카 (README §2). 병리 규칙 파일의 `dollarMath`·`expect`도 같은 뜻이다.
struct FixtureMeta: Decodable, Sendable {
    var dollarMath: [String]?
    var budgetMs: Int?
    var expect: FixtureExpect?

    /// 생략 = 1000 ms.
    var budget: Duration { .milliseconds(budgetMs ?? 1000) }

    func options() throws -> DollarMathOptions {
        try FixtureSupport.dollarMathOptions(dollarMath)
    }
}

struct FixtureExpect: Decodable, Sendable {
    var truncated: Bool?
    var mathLatex: [String]?
    var mathKinds: [String]?
    var blockTypes: [String]?
    var diagnostics: [String]?
    var linkCount: Int?
    var plainTextContains: [String]?
}

/// `pathological/*.gen.json` 생성 규칙 (README §5). 종류별로 쓰는 키만 채워진다.
struct PathologicalRule: Decodable, Sendable {
    var kind: String
    var unit: String?
    var count: Int?
    var suffix: String?
    var line: String?
    var prefix: String?
    var depth: Int?
    var indent: String?
    var item: String?
    var open: String?
    var close: String?
    var fill: String?
    var columns: Int?
    var rows: Int?
    var cell: String?
    var dollarMath: [String]?
    var budgetMs: Int?
    var expect: FixtureExpect?

    var meta: FixtureMeta {
        FixtureMeta(dollarMath: dollarMath, budgetMs: budgetMs, expect: expect)
    }

    func generate() throws -> String {
        switch kind {
        case "repeat":
            return String(repeating: try field(unit, "unit"), count: try field(count, "count")) + (suffix ?? "")
        case "repeat-lines":
            let lines = Array(repeating: try field(line, "line"), count: try field(count, "count"))
            return (prefix ?? "") + lines.joined(separator: "\n")
        case "nested-list":
            let indent = try field(indent, "indent")
            let item = try field(item, "item")
            return (0..<(try field(depth, "depth")))
                .map { String(repeating: indent, count: $0) + item }
                .joined(separator: "\n")
        case "math-oversize":
            let body = String(repeating: try field(fill, "fill"), count: try field(count, "count"))
            return try field(open, "open") + body + (try field(close, "close"))
        case "table":
            let columns = try field(columns, "columns")
            let row = "| " + Array(repeating: try field(cell, "cell"), count: columns).joined(separator: " | ") + " |"
            let separator = "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|"
            return ([row, separator] + Array(repeating: row, count: try field(rows, "rows"))).joined(separator: "\n")
        default:
            throw FixtureError.unknownRule(kind)
        }
    }

    private func field<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw FixtureError.missingRuleField(kind, name) }
        return value
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case missingFixturesDirectory(String)
    case unknownDollarMath(String)
    case unknownRule(String)
    case missingRuleField(String, String)
    case malformedJSON(String)

    var description: String {
        switch self {
        case .missingFixturesDirectory(let path): "Tests/Fixtures를 찾지 못함: \(path)"
        case .unknownDollarMath(let value): "알 수 없는 dollarMath 값: \(value)"
        case .unknownRule(let kind): "알 수 없는 병리 규칙 kind: \(kind)"
        case .missingRuleField(let kind, let name): "병리 규칙 \(kind)에 \(name) 키가 없음"
        case .malformedJSON(let path): "JSON 객체가 아님: \(path)"
        }
    }
}

/// `Tests/Fixtures` 코퍼스 접근 (README §1·§4·§5). 파일 id는 확장자를 뺀 상대 경로다.
enum FixtureSupport {
    private static let environment = ProcessInfo.processInfo.environment

    /// `#filePath` 두 단계 위의 `Fixtures`. 없으면 `RICHMARKDOWN_FIXTURES_DIR`.
    static let rootURL: URL = {
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        if FileManager.default.fileExists(atPath: fromSource.path) { return fromSource }
        if let override = environment["RICHMARKDOWN_FIXTURES_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fromSource
    }()

    /// `manifest.json`의 상대 경로 목록 (정렬 순서 그대로). 읽기 실패는 빈 목록이며 테스트가 보고한다.
    static let manifestPaths: [String] = {
        struct Manifest: Decodable { struct Entry: Decodable { var path: String }; var files: [Entry] }
        guard let data = try? Data(contentsOf: rootURL.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [] }
        return manifest.files.map(\.path)
    }()

    /// README §4 코퍼스: commonmark를 뺀 `.md` fixture id. `security/mermaid`는 Mermaid 모듈 몫이다.
    static let corpusCategories: Set<String> = [
        "math", "unicode", "markdown", "streaming", "security", "samples", "pathological", "regressions",
    ]

    static var corpusIDs: [String] {
        manifestPaths
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix("security/mermaid/") }
            .filter { corpusCategories.contains(category(of: $0)) }
            .map { String($0.dropLast(".md".count)) }
            .sorted()
    }

    static var pathologicalIDs: [String] {
        manifestPaths
            .filter { $0.hasSuffix(".gen.json") }
            .map { String($0.dropLast(".gen.json".count)) }
            .sorted()
    }

    /// 퍼즈 기본 입력 (README §6): `math/`·`markdown/`·`unicode/`·`samples/`의 `.md`를 id 사전순으로.
    static var fuzzCorpusIDs: [String] {
        let categories: Set<String> = ["math", "markdown", "unicode", "samples"]
        return corpusIDs.filter { categories.contains(category(of: $0)) }
    }

    /// README §6: 첫 측정에 모듈 로딩 비용이 실리지 않도록 시간을 재기 전에 1회 파싱한다.
    static func warmUp() {
        _ = warmedUp
    }

    private static let warmedUp: Void = {
        _ = RichMarkdownParser.parse(markdown: "워밍업 \\(x\\)\n\n| a |\n|---|\n| b |", dollarMath: [.single, .inlineDouble])
    }()

    static func category(of id: String) -> String {
        String(id.prefix { $0 != "/" })
    }

    // MARK: - 파일 읽기

    static func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    /// `.md` 원문. BOM·CRLF·CR·NUL을 바꾸지 않는다 (fixture는 모두 유효한 UTF-8).
    static func markdown(id: String) throws -> String {
        String(decoding: try Data(contentsOf: url(id + ".md")), as: UTF8.self)
    }

    static func meta(id: String) throws -> FixtureMeta {
        try decodeIfExists(FixtureMeta.self, at: url(id + ".meta.json")) ?? FixtureMeta()
    }

    static func rule(id: String) throws -> PathologicalRule {
        try JSONDecoder().decode(PathologicalRule.self, from: Data(contentsOf: url(id + ".gen.json")))
    }

    /// `parity-exceptions.json`이 id별로 승인한 필드 이름(`href` 등). URL 구현 차이처럼 플랫폼·OS마다 값이 다른 필드다.
    static func ignoredFields(id: String) throws -> Set<String> {
        let data = try Data(contentsOf: url("parity-exceptions.json"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let exceptions = root?["exceptions"] as? [[String: Any]] ?? []
        let entry = exceptions.first { $0["id"] as? String == id }
        return Set(entry?["ignore"] as? [String] ?? [])
    }

    /// 승인된 필드의 값을 같은 표식으로 바꿔 비교에서 뺀다 (README §4, scripts/fixtures-parity.py와 같은 규칙).
    static func masking(_ object: Any, fields: Set<String>) -> Any {
        guard !fields.isEmpty else { return object }
        if let dict = object as? [String: Any] {
            return dict.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = fields.contains(pair.key) ? "<ignored>" : masking(pair.value, fields: fields)
            }
        }
        if let array = object as? [Any] { return array.map { masking($0, fields: fields) } }
        return object
    }

    /// `<id>.expected.json`이 있으면 파싱한 JSON 객체.
    static func expected(id: String) throws -> [String: Any]? {
        let fileURL = url(id + ".expected.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any] else {
            throw FixtureError.malformedJSON(fileURL.path)
        }
        return object
    }

    /// CommonMark spec 예제의 `markdown` 입력을 `example` 번호와 함께 돌려준다.
    static func commonMarkExamples() throws -> [(example: Int, markdown: String)] {
        struct Example: Decodable { var markdown: String; var example: Int }
        let data = try Data(contentsOf: url("commonmark/spec-0.31.2.json"))
        return try JSONDecoder().decode([Example].self, from: data).map { ($0.example, $0.markdown) }
    }

    private static func decodeIfExists<T: Decodable>(_ type: T.Type, at fileURL: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: fileURL))
    }

    static func dollarMathOptions(_ names: [String]?) throws -> DollarMathOptions {
        var options: DollarMathOptions = []
        for name in names ?? [] {
            switch name {
            case "single": options.insert(.single)
            case "inlineDouble": options.insert(.inlineDouble)
            default: throw FixtureError.unknownDollarMath(name)
            }
        }
        return options
    }

    // MARK: - 출력

    /// `RICHMARKDOWN_FIXTURE_OUT/ios/`. 환경 변수가 없으면 nil이며 출력을 생략한다.
    static var outputDirectory: URL? {
        environment["RICHMARKDOWN_FIXTURE_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("ios", isDirectory: true)
        }
    }

    /// `<out>/ios/<relativePath>`에 쓴다. id가 `/`를 포함하므로 중간 디렉터리를 만든다.
    static func writeOutput(_ data: Data, relativePath: String) throws {
        guard let outputDirectory else { return }
        let fileURL = outputDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
    }

    /// 퍼즈가 찾은 최소화 입력을 `regressions/<seed>-<n>.md`로 저장하고 경로를 돌려준다.
    static func writeRegression(_ text: String, seed: UInt64, iteration: Int) throws -> URL {
        let directory = url("regressions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(seed)-\(iteration).md")
        try Data(text.utf8).write(to: fileURL)
        return fileURL
    }
}
