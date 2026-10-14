import Foundation
@testable import RichMarkdownCore

/// `ParsedDocument` → 플랫폼 중립 JSON (Tests/Fixtures/README.md §3).
/// 키 이름·enum 철자는 계약 그대로이고, 거짓인 `b`/`i`/`s`는 생략한다.
enum FixtureNormalizer {
    static func data(_ document: ParsedDocument) throws -> Data {
        try JSONSerialization.data(withJSONObject: json(document), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func json(_ document: ParsedDocument) -> [String: Any] {
        [
            "truncated": document.wasTruncated,
            "diagnostics": diagnosticKinds(document).map(name),
            "blocks": document.blocks.map(block),
        ]
    }

    /// 종류만 문서 순서(UTF-8 시작 offset 기준, 안정 정렬)로.
    static func diagnosticKinds(_ document: ParsedDocument) -> [MathDiagnostic.Kind] {
        document.diagnostics.enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (lhs.element.utf8Range.lowerBound, rhs.element.utf8Range.lowerBound)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element.kind)
    }

    static func name(_ kind: MathKind) -> String {
        switch kind {
        case .inlineParen: "inlineParen"
        case .displayBracket: "displayBracket"
        case .inlineDollar: "inlineDollar"
        case .displayDollar: "displayDollar"
        case .inlineDoubleDollar: "inlineDoubleDollar"
        }
    }

    static func name(_ kind: MathDiagnostic.Kind) -> String {
        switch kind {
        case .unterminatedDelimiter: "unterminatedDelimiter"
        case .emptyMath: "emptyMath"
        case .nestedDelimiter: "nestedDelimiter"
        case .oversizedMathSource: "oversizedMathSource"
        case .nonParagraphDisplayDelimiter: "nonParagraphDisplayDelimiter"
        }
    }

    static func typeName(_ block: ParsedBlock) -> String {
        switch block {
        case .paragraph: "p"
        case .heading: "h"
        case .codeBlock: "code"
        case .blockMath: "math"
        case .blockQuote: "quote"
        case .unorderedList: "ul"
        case .orderedList: "ol"
        case .table: "table"
        case .thematicBreak: "hr"
        }
    }

    static func block(_ block: ParsedBlock) -> [String: Any] {
        var object: [String: Any] = ["t": typeName(block)]
        switch block {
        case .paragraph(let runs):
            object["runs"] = runs.map(run)
        case .heading(let level, let runs):
            object["level"] = level
            object["runs"] = runs.map(run)
        case .codeBlock(let language, let code):
            object["lang"] = language ?? NSNull()
            object["code"] = code
        case .blockMath(let segment):
            object.merge(math(segment)) { current, _ in current }
        case .blockQuote(let children):
            object["blocks"] = children.map(Self.block)
        case .unorderedList(let items):
            object["items"] = items.map { $0.map(Self.block) }
        case .orderedList(let start, let items):
            object["start"] = start
            object["items"] = items.map { $0.map(Self.block) }
        case .table(let table):
            object["align"] = table.columnAlignments.map(alignment)
            object["header"] = table.header.map { $0.map(run) }
            object["rows"] = table.rows.map { $0.map { $0.map(run) } }
        case .thematicBreak:
            break
        }
        return object
    }

    static func run(_ run: InlineRun) -> [String: Any] {
        var object: [String: Any]
        switch run.content {
        case .text(let value): object = ["c": "text", "v": value]
        case .code(let value): object = ["c": "code", "v": value]
        case .math(let segment): object = math(segment).merging(["c": "math"]) { _, new in new }
        case .link(let text, let destination): object = ["c": "link", "v": text, "href": destination.absoluteString]
        case .hardBreak: object = ["c": "br"]
        case .softBreak: object = ["c": "sbr"]
        }
        if run.bold { object["b"] = true }
        if run.italic { object["i"] = true }
        if run.strikethrough { object["s"] = true }
        return object
    }

    private static func math(_ segment: MathSegment) -> [String: Any] {
        ["kind": name(segment.kind), "latex": segment.latex, "source": segment.source]
    }

    private static func alignment(_ alignment: ParsedTable.ColumnAlignment?) -> Any {
        switch alignment {
        case .left: "left"
        case .center: "center"
        case .right: "right"
        case nil: NSNull()
        }
    }

    // MARK: - 검사용 탐색

    /// 문서 전체의 inline run (문단·제목·표 셀, 목록·인용 재귀) 문서 순서.
    static func allRuns(_ blocks: [ParsedBlock]) -> [InlineRun] {
        blocks.flatMap { block -> [InlineRun] in
            switch block {
            case .paragraph(let runs), .heading(_, let runs): runs
            case .blockQuote(let children): allRuns(children)
            case .unorderedList(let items), .orderedList(_, let items): items.flatMap(allRuns)
            case .table(let table): (table.header + table.rows.flatMap { $0 }).flatMap { $0 }
            case .codeBlock, .blockMath, .thematicBreak: []
            }
        }
    }

    static func linkCount(_ document: ParsedDocument) -> Int {
        allRuns(document.blocks).filter {
            if case .link = $0.content { return true }
            return false
        }.count
    }

    /// `plainTextContains` 대상 (README §2): run의 `v`·수식 `source`·코드 블록 `code`를 문서 순서로 잇고 블록 사이에 `\n`.
    static func plainText(_ blocks: [ParsedBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let runs), .heading(_, let runs): runs.map(plainText).joined()
            case .codeBlock(_, let code): code
            case .blockMath(let segment): segment.source
            case .blockQuote(let children): plainText(children)
            case .unorderedList(let items), .orderedList(_, let items): items.map(plainText).joined(separator: "\n")
            case .table(let table):
                (table.header + table.rows.flatMap { $0 }).map { $0.map(plainText).joined() }.joined(separator: "\n")
            case .thematicBreak: ""
            }
        }.joined(separator: "\n")
    }

    private static func plainText(_ run: InlineRun) -> String {
        switch run.content {
        case .text(let value), .code(let value): value
        case .math(let segment): segment.source
        case .link(let text, _): text
        case .hardBreak, .softBreak: ""
        }
    }

    /// 최대 block quote 중첩 깊이.
    static func maxQuoteDepth(_ blocks: [ParsedBlock], current: Int = 0) -> Int {
        blocks.map { block -> Int in
            switch block {
            case .blockQuote(let children): maxQuoteDepth(children, current: current + 1)
            case .unorderedList(let items), .orderedList(_, let items):
                items.map { maxQuoteDepth($0, current: current) }.max() ?? current
            default: current
            }
        }.max() ?? current
    }

    /// 문서 안 모든 표 (목록·인용 재귀).
    static func allTables(_ blocks: [ParsedBlock]) -> [ParsedTable] {
        blocks.flatMap { block -> [ParsedTable] in
            switch block {
            case .table(let table): [table]
            case .blockQuote(let children): allTables(children)
            case .unorderedList(let items), .orderedList(_, let items): items.flatMap(allTables)
            default: []
            }
        }
    }

    // MARK: - JSON 비교

    /// 파싱된 JSON 값 두 개의 첫 차이를 경로와 함께 설명한다. 같으면 nil.
    static func firstDifference(expected: Any, actual: Any, path: String = "$") -> String? {
        switch (expected, actual) {
        case (let e as [String: Any], let a as [String: Any]):
            for key in Set(e.keys).union(a.keys).sorted() {
                guard let ev = e[key] else { return "\(path).\(key): expected에 없음, actual=\(describe(a[key]))" }
                guard let av = a[key] else { return "\(path).\(key): actual에 없음, expected=\(describe(ev))" }
                if let diff = firstDifference(expected: ev, actual: av, path: "\(path).\(key)") { return diff }
            }
            return nil
        case (let e as [Any], let a as [Any]):
            guard e.count == a.count else { return "\(path): 길이 expected=\(e.count) actual=\(a.count)" }
            for (index, pair) in zip(e, a).enumerated() {
                if let diff = firstDifference(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]") { return diff }
            }
            return nil
        default:
            guard (expected as AnyObject).isEqual(actual) else {
                return "\(path): expected=\(describe(expected)) actual=\(describe(actual))"
            }
            return nil
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
            return String(decoding: data.prefix(300), as: UTF8.self)
        }
        return String(describing: value)
    }
}
