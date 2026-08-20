import Foundation
import Markdown

/// 2-pass 파이프라인 (DEVELOPMENT.md §3):
/// 사전 byte 상한 → 1차 파싱(금지 범위/paragraph 수집) → 원문 수식 스캔
/// → byte-length-preserving mask → 2차 파싱 → ParsedDocument.
package enum SwiftLatexParser {
    package static func parse(markdown: String, parsesDollarMath: Bool) -> ParsedDocument {
        parse(InputLimits.bound(markdown), parsesDollarMath: parsesDollarMath)
    }

    /// UI ingress에서 한 번 제한한 입력을 재검사 없이 파싱한다.
    /// `wasTruncated`는 원문 제한 상태이므로 결과에 그대로 보존한다.
    package static func parse(
        _ boundedInput: InputLimits.BoundedInput,
        parsesDollarMath: Bool
    ) -> ParsedDocument {
        let signpostState = SwiftLatexSignposts.parse.beginInterval("parse")
        defer { SwiftLatexSignposts.parse.endInterval("parse", signpostState) }

        let text = boundedInput.text
        let bytes = Array(text.utf8)
        let lineMap = UTF8LineMap(utf8: bytes)

        // 1차 파싱: 수식을 찾는 데 쓰지 않는다. code/HTML/link/image 금지 문맥과 paragraph 범위만 수집.
        let firstPass = Document(parsing: text)
        var collector = Pass1Collector(lineMap: lineMap)
        collector.visit(firstPass)

        let scanner = MathScanner(
            bytes: bytes,
            forbiddenRanges: collector.forbiddenRanges,
            softRanges: collector.softRanges,
            paragraphRanges: collector.paragraphRanges,
            parsesDollarMath: parsesDollarMath
        )
        let scan = scanner.scan()

        // 보호 버퍼로 2차 파싱. byte 길이가 같아 range를 원문에 그대로 쓴다.
        let masked = MathProtector.protect(bytes: bytes, spans: scan.spans)
        let secondPass = Document(parsing: String(decoding: masked, as: UTF8.self))

        let builder = ModelBuilder(originalBytes: bytes, lineMap: lineMap, spans: scan.spans)
        let blocks = Array(secondPass.blockChildren.compactMap { builder.convert(block: $0) })

        return ParsedDocument(
            blocks: blocks,
            wasTruncated: boundedInput.wasTruncated,
            diagnostics: scan.diagnostics
        )
    }
}

// MARK: - Pass 1

private struct Pass1Collector: MarkupWalker {
    let lineMap: UTF8LineMap
    /// hard barrier: code/HTML 전체 범위.
    var forbiddenRanges: [Range<Int>] = []
    /// soft range: link/image 전체 범위 (수식이 완전히 포함하면 수식이 이긴다).
    var softRanges: [Range<Int>] = []
    var paragraphRanges: [Range<Int>] = []

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if let range = utf8Range(of: paragraph, lineMap: lineMap) {
            paragraphRanges.append(range)
        }
        descendInto(paragraph)
    }

    // 금지 범위: 전체 범위를 기록하고 내부로 내려가지 않는다.
    mutating func visitCodeBlock(_ node: CodeBlock) { addForbidden(node) }
    mutating func visitInlineCode(_ node: InlineCode) { addForbidden(node) }
    mutating func visitHTMLBlock(_ node: HTMLBlock) { addForbidden(node) }
    mutating func visitInlineHTML(_ node: InlineHTML) { addForbidden(node) }
    mutating func visitLink(_ node: Link) { addSoft(node) }
    mutating func visitImage(_ node: Image) { addSoft(node) }

    private mutating func addForbidden(_ markup: Markup) {
        if let range = utf8Range(of: markup, lineMap: lineMap) {
            forbiddenRanges.append(range)
        }
    }

    private mutating func addSoft(_ markup: Markup) {
        if let range = utf8Range(of: markup, lineMap: lineMap) {
            softRanges.append(range)
        }
    }
}

/// swift-markdown SourceRange(1-based line/column, column은 UTF-8 byte) → 0-based UTF-8 offset range.
private func utf8Range(of markup: Markup, lineMap: UTF8LineMap) -> Range<Int>? {
    guard let range = markup.range,
          let lower = lineMap.offset(line: range.lowerBound.line, column: range.lowerBound.column),
          let upper = lineMap.offset(line: range.upperBound.line, column: range.upperBound.column),
          lower <= upper
    else { return nil }
    return lower..<min(upper, lineMap.byteCount)
}

// MARK: - Pass 2 model build

private struct ModelBuilder {
    let originalBytes: [UInt8]
    let lineMap: UTF8LineMap
    let inlineSpans: [ProtectedMathSpan]
    let displaySpans: [ProtectedMathSpan]

    init(originalBytes: [UInt8], lineMap: UTF8LineMap, spans: [ProtectedMathSpan]) {
        self.originalBytes = originalBytes
        self.lineMap = lineMap
        self.inlineSpans = spans.filter { !$0.kind.isDisplay }
        self.displaySpans = spans.filter { $0.kind.isDisplay }
    }

    func convert(block: BlockMarkup) -> ParsedBlock? {
        switch block {
        case let paragraph as Paragraph:
            if let range = utf8Range(of: paragraph, lineMap: lineMap),
               let span = displaySpans.first(where: { range.overlaps($0.originalUTF8Range) }) {
                return .blockMath(MathSegment(span: span))
            }
            return .paragraph(inlineRuns(of: paragraph))

        case let heading as Heading:
            return .heading(level: heading.level, runs: inlineRuns(of: heading))

        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            var body = code.code
            if body.hasSuffix("\n") { body.removeLast() }
            return .codeBlock(language: (language?.isEmpty ?? true) ? nil : language, code: body)

        case let quote as BlockQuote:
            return .blockQuote(Array(quote.blockChildren.compactMap { convert(block: $0) }))

        case let list as UnorderedList:
            let items = list.listItems.map { item in
                Array(item.blockChildren.compactMap { convert(block: $0) })
            }
            return .unorderedList(items: Array(items))

        case let list as OrderedList:
            let items = list.listItems.map { item in
                Array(item.blockChildren.compactMap { convert(block: $0) })
            }
            return .orderedList(start: Int(list.startIndex), items: Array(items))

        case is ThematicBreak:
            return .thematicBreak

        case let html as HTMLBlock:
            // HTML은 실행하지 않고 문자 그대로 표시한다.
            var literal = html.rawHTML
            if literal.hasSuffix("\n") { literal.removeLast() }
            return .paragraph([InlineRun(content: .text(literal))])

        default:
            // 미지원 노드는 읽을 수 있는 plain text로 낮추며 조용히 삭제하지 않는다.
            let fallback = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return nil }
            return .paragraph([InlineRun(content: .text(fallback))])
        }
    }

    private func inlineRuns(of container: Markup) -> [InlineRun] {
        var runs: [InlineRun] = []
        for child in container.children {
            appendRuns(for: child, bold: false, italic: false, strikethrough: false, into: &runs)
        }
        return runs
    }

    private func appendRuns(
        for markup: Markup,
        bold: Bool,
        italic: Bool,
        strikethrough: Bool,
        into runs: inout [InlineRun]
    ) {
        func run(_ content: InlineRun.Content) -> InlineRun {
            InlineRun(content: content, bold: bold, italic: italic, strikethrough: strikethrough)
        }

        switch markup {
        case let text as Markdown.Text:
            appendTextRuns(for: text, style: run, into: &runs)

        case let code as InlineCode:
            runs.append(run(.code(code.code)))

        case let link as Link:
            let label = link.plainText
            if let url = LinkPolicy.allowedURL(from: link.destination) {
                runs.append(run(.link(text: label, destination: url)))
            } else {
                // 상대 URL과 비허용 scheme은 plain text로 표시한다.
                runs.append(run(.text(label)))
            }

        case let image as Image:
            // 이미지 문법은 alt text만 표시한다.
            let alt = image.plainText
            if !alt.isEmpty { runs.append(run(.text(alt))) }

        case let html as InlineHTML:
            runs.append(run(.text(html.rawHTML)))

        case is LineBreak:
            runs.append(run(.hardBreak))

        case is SoftBreak:
            runs.append(run(.softBreak))

        case let strong as Strong:
            for child in strong.children {
                appendRuns(for: child, bold: true, italic: italic, strikethrough: strikethrough, into: &runs)
            }

        case let emphasis as Emphasis:
            for child in emphasis.children {
                appendRuns(for: child, bold: bold, italic: true, strikethrough: strikethrough, into: &runs)
            }

        case let strike as Strikethrough:
            for child in strike.children {
                appendRuns(for: child, bold: bold, italic: italic, strikethrough: true, into: &runs)
            }

        default:
            let fallback = markup.format()
            if !fallback.isEmpty { runs.append(run(.text(fallback))) }
        }
    }

    /// masked Text 노드를 원문 slice로 되돌리고, 겹치는 inline 수식 span을 math run으로 쪼갠다.
    private func appendTextRuns(
        for text: Markdown.Text,
        style: (InlineRun.Content) -> InlineRun,
        into runs: inout [InlineRun]
    ) {
        guard let range = utf8Range(of: text, lineMap: lineMap) else {
            // range가 없으면 fail-open: masked 문자열 대신 노드 문자열 그대로.
            runs.append(style(.text(text.string)))
            return
        }

        // span이 없으면 second pass의 Text가 Markdown entity/escape를 이미 해제했다.
        // 단, 수식 구분자 escape는 malformed LaTex를 원문으로 보여 주는 fail-open 계약이라
        // 원문 slice 경로를 유지한다. 이 fast path가 여러 entity Text마다 parser를 다시
        // 만드는 O(n^2) 경로를 막는다.
        let overlappingSpans = inlineSpans.filter { $0.originalUTF8Range.overlaps(range) }
        let source = String(decoding: originalBytes[range], as: UTF8.self)
        if overlappingSpans.isEmpty, !containsLiteralMathDelimiterEscape(in: range) {
            runs.append(style(.text(text.string)))
            return
        }

        if source.contains("&"), appendEntityDecodedRuns(
            in: range,
            source: source,
            decodedText: text.string,
            spans: overlappingSpans,
            style: style,
            into: &runs
        ) {
            return
        }

        var cursor = range.lowerBound
        for span in overlappingSpans {
            let spanRange = span.originalUTF8Range
            guard spanRange.lowerBound >= cursor, spanRange.upperBound <= range.upperBound else {
                continue // 부분 겹침은 발생하지 않아야 한다. fail-open으로 원문 텍스트에 남긴다.
            }
            if cursor < spanRange.lowerBound {
                runs.append(style(.text(slice(cursor..<spanRange.lowerBound))))
            }
            runs.append(style(.math(MathSegment(span: span))))
            cursor = spanRange.upperBound
        }
        if cursor < range.upperBound {
            runs.append(style(.text(slice(cursor..<range.upperBound))))
        }
    }

    /// entity가 수식 span의 앞뒤에 있어도 second pass와 같은 의미 해석을 유지한다.
    /// marker는 Markdown parser가 바꾸지 않는 PUA 문자로 만들어 수식 source와 분리한다.
    private func appendEntityDecodedRuns(
        in range: Range<Int>,
        source: String,
        decodedText: String,
        spans: [ProtectedMathSpan],
        style: (InlineRun.Content) -> InlineRun,
        into runs: inout [InlineRun]
    ) -> Bool {
        guard spans.allSatisfy({ range.contains($0.originalUTF8Range) }) else { return false }

        var markers = OpaqueMarkerFactory(rawSource: source, decodedText: decodedText)
        var markdown = ""
        var cursor = range.lowerBound
        var mathMarkers: [(marker: String, span: ProtectedMathSpan)] = []

        for span in spans {
            markdown += String(decoding: originalBytes[cursor..<span.originalUTF8Range.lowerBound], as: UTF8.self)
            let marker = markers.next()
            markdown += marker
            mathMarkers.append((marker, span))
            cursor = span.originalUTF8Range.upperBound
        }
        markdown += String(decoding: originalBytes[cursor..<range.upperBound], as: UTF8.self)

        let protected = protectLiteralMathDelimiterEscapes(in: markdown, markers: &markers)
        guard var decoded = decodedParagraphText(from: protected.markdown) else { return false }
        for restoration in protected.restorations {
            decoded = decoded.replacingOccurrences(of: restoration.marker, with: restoration.value)
        }

        var textStart = decoded.startIndex
        for entry in mathMarkers {
            guard let markerRange = decoded.range(of: entry.marker, range: textStart..<decoded.endIndex) else {
                return false
            }
            if textStart < markerRange.lowerBound {
                runs.append(style(.text(String(decoded[textStart..<markerRange.lowerBound]))))
            }
            runs.append(style(.math(MathSegment(span: entry.span))))
            textStart = markerRange.upperBound
        }
        if textStart < decoded.endIndex {
            runs.append(style(.text(String(decoded[textStart...]))))
        }
        return true
    }

    private func containsLiteralMathDelimiterEscape(in range: Range<Int>) -> Bool {
        let source = String(decoding: originalBytes[range], as: UTF8.self)
        return source.contains(#"\("#)
            || source.contains(#"\)"#)
            || source.contains(#"\["#)
            || source.contains(#"\]"#)
    }

    /// span 밖 텍스트는 원문 slice에서 Markdown escape를 해제해 표시한다.
    private func slice(_ range: Range<Int>) -> String {
        String(decoding: originalBytes[range], as: UTF8.self)
            .unescapingMarkdownPunctuation()
    }
}

/// raw/decoded corpus에 모두 없는 Plane 15/16 private-use scalar를 marker prefix로 쓴다.
///
/// HTML numeric entity가 이전 marker 문자열로 decode되는 충돌을 막고, marker마다 source를
/// 재검색하지 않아 수식 수에 비례해 CPU가 증폭되지 않는다.
private struct OpaqueMarkerFactory {
    private let sentinel: String
    private var serial = 0

    init(rawSource: String, decodedText: String) {
        let occupied = Set(rawSource.unicodeScalars).union(decodedText.unicodeScalars)
        // 한 입력은 256 KiB로 제한된다. 131k개가 넘는 Plane 15/16 scalar 전부를 raw와
        // decoded corpus에 동시에 넣을 수 없으므로 충돌 없는 scalar가 항상 존재한다.
        for value in 0xF0000...0x10FFFD {
            guard let scalar = Unicode.Scalar(value), !occupied.contains(scalar) else { continue }
            sentinel = String(scalar)
            return
        }
        preconditionFailure("bounded input must leave an opaque marker scalar")
    }

    mutating func next() -> String {
        defer { serial += 1 }
        return "\(sentinel)swiftlatex-\(serial)\(sentinel)"
    }
}

private struct LiteralMathEscapeProtection {
    let markdown: String
    let restorations: [(marker: String, value: String)]
}

/// `\(` 등의 malformed 수식 구분자는 Markdown parser가 escape를 벗기기 전에 보호한다.
private func protectLiteralMathDelimiterEscapes(
    in markdown: String,
    markers: inout OpaqueMarkerFactory
) -> LiteralMathEscapeProtection {
    var protected = ""
    var restorations: [(marker: String, value: String)] = []
    var index = markdown.startIndex

    while index < markdown.endIndex {
        guard markdown[index] == "\\" else {
            protected.append(markdown[index])
            index = markdown.index(after: index)
            continue
        }

        let runStart = index
        while index < markdown.endIndex, markdown[index] == "\\" {
            index = markdown.index(after: index)
        }
        guard index < markdown.endIndex,
              markdown[index] == "(" || markdown[index] == ")"
                || markdown[index] == "[" || markdown[index] == "]"
        else {
            protected += String(markdown[runStart..<index])
            continue
        }

        let marker = markers.next()
        protected += marker
        restorations.append((marker, String(markdown[runStart...index]).unescapingMarkdownPunctuation()))
        index = markdown.index(after: index)
    }

    return LiteralMathEscapeProtection(markdown: protected, restorations: restorations)
}

/// `Markdown.Text.string`과 같은 entity/escape 의미 해석이 필요한 text fragment의 최소 경로.
private func decodedParagraphText(from markdown: String) -> String? {
    let document = Document(parsing: markdown)
    for block in document.blockChildren {
        if let paragraph = block as? Paragraph {
            return paragraph.plainText
        }
    }
    return nil
}
