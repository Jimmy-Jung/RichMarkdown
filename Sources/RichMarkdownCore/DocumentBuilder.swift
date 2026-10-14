import Foundation
import Markdown

/// 2-pass 파이프라인 (DEVELOPMENT.md §3):
/// 사전 byte 상한 → 1차 파싱(금지 범위/paragraph 수집) → 원문 수식 스캔
/// → byte-length-preserving mask → 2차 파싱 → ParsedDocument.
package enum RichMarkdownParser {
    /// 따옴표·대시·말줄임 자동 치환(cmark smart)을 끈다. 원문 글자를 그대로 보존해야 Android(commonmark-java)와
    /// 같은 결과가 나오고, 치환으로 바이트 길이가 바뀌어 수식 mask offset이 어긋나는 일이 없다.
    package static var parseOptions: ParseOptions { [.disableSmartOpts] }

    package static func parse(markdown: String, parsesDollarMath: Bool) -> ParsedDocument {
        parse(markdown: markdown, dollarMath: DollarMathOptions(parsesDollarMath: parsesDollarMath))
    }

    package static func parse(markdown: String, dollarMath: DollarMathOptions) -> ParsedDocument {
        parse(InputLimits.bound(markdown), dollarMath: dollarMath)
    }

    package static func parse(
        _ boundedInput: InputLimits.BoundedInput,
        parsesDollarMath: Bool
    ) -> ParsedDocument {
        parse(boundedInput, dollarMath: DollarMathOptions(parsesDollarMath: parsesDollarMath))
    }

    /// UI ingress에서 한 번 제한한 입력을 재검사 없이 파싱한다.
    /// `wasTruncated`는 원문 제한 상태이므로 결과에 그대로 보존한다.
    package static func parse(
        _ boundedInput: InputLimits.BoundedInput,
        dollarMath: DollarMathOptions
    ) -> ParsedDocument {
        let signpostState = RichMarkdownSignposts.parse.beginInterval("parse")
        defer { RichMarkdownSignposts.parse.endInterval("parse", signpostState) }

        let text = boundedInput.text
        let bytes = Array(text.utf8)
        let lineMap = UTF8LineMap(utf8: bytes)

        let scan = scanMath(
            text: text,
            bytes: bytes,
            lineMap: lineMap,
            dollarMath: dollarMath
        )

        // 보호 버퍼로 2차 파싱. byte 길이가 같아 range를 원문에 그대로 쓴다.
        let masked = MathProtector.protect(bytes: bytes, spans: scan.spans)
        let secondPass = Document(parsing: String(decoding: masked, as: UTF8.self), options: Self.parseOptions)

        let shift = InlineColumnShift(document: secondPass, lineMap: lineMap, bytes: bytes, parsedBytes: masked)
        let builder = ModelBuilder(originalBytes: bytes, maskedBytes: masked, lineMap: lineMap, shift: shift, spans: scan.spans)
        let blocks = builder.convertBlocks(secondPass.blockChildren)

        return ParsedDocument(
            blocks: blocks,
            wasTruncated: boundedInput.wasTruncated,
            diagnostics: scan.diagnostics
        )
    }

    /// 편집기처럼 원문 위치가 필요한 클라이언트용 패키지 내부 API.
    /// Markdown code/HTML/link/image barrier와 delimiter 규칙을 공개 렌더러와 동일하게 적용한다.
    package static func scanInlineMathSpans(
        markdown: String,
        parsesDollarMath: Bool,
        excludingUTF8Ranges: [Range<Int>] = []
    ) -> [ProtectedMathSpan] {
        scanInlineMathSpans(
            markdown: markdown,
            dollarMath: DollarMathOptions(parsesDollarMath: parsesDollarMath),
            excludingUTF8Ranges: excludingUTF8Ranges
        )
    }

    package static func scanInlineMathSpans(
        markdown: String,
        dollarMath: DollarMathOptions,
        excludingUTF8Ranges: [Range<Int>] = []
    ) -> [ProtectedMathSpan] {
        // scanner의 결과는 원문 좌표이므로 제한 초과 입력을 자르거나 marker로 치환하지 않는다.
        // full parse와 같은 깊이 검사를 첫 AST 이전에 적용하고 빈 결과로 거절한다.
        guard markdown.utf8.count <= InputLimits.maxInputUTF8Bytes,
              InputLimits.firstLineExceedingNestingLimits(in: markdown) == nil
        else { return [] }

        let bytes = Array(markdown.utf8)
        let scan = scanMath(
            text: markdown,
            bytes: bytes,
            lineMap: UTF8LineMap(utf8: bytes),
            dollarMath: dollarMath,
            additionalForbiddenRanges: excludingUTF8Ranges
        )
        return scan.spans.filter { !$0.kind.isDisplay }
    }

    private static func scanMath(
        text: String,
        bytes: [UInt8],
        lineMap: UTF8LineMap,
        dollarMath: DollarMathOptions,
        additionalForbiddenRanges: [Range<Int>] = []
    ) -> MathScanner.Result {
        // 1차 파싱은 code/HTML/link/image 금지 문맥과 paragraph 범위만 수집한다.
        let firstPass = Document(parsing: text, options: Self.parseOptions)
        var collector = Pass1Collector(lineMap: lineMap, document: firstPass, bytes: bytes)
        collector.visit(firstPass)
        collector.forbiddenRanges.append(contentsOf: additionalForbiddenRanges)

        return MathScanner(
            bytes: bytes,
            forbiddenRanges: collector.forbiddenRanges,
            softRanges: collector.softRanges,
            paragraphRanges: collector.paragraphRanges,
            dollarMath: dollarMath
        ).scan()
    }
}

// MARK: - Pass 1

private struct Pass1Collector: MarkupWalker {
    let lineMap: UTF8LineMap
    let document: Markup
    let bytes: [UInt8]
    /// 인라인 노드(코드 span·HTML·링크·이미지)를 처음 만날 때 만든다. 그런 노드가 없는 답변(수식 위주 답변 대부분)은
    /// 위치 보정을 위한 트리 순회를 생략한다.
    private var inlineShift: InlineColumnShift?
    /// hard barrier: code/HTML 전체 범위.
    var forbiddenRanges: [Range<Int>] = []
    /// soft range: link/image 전체 범위 (수식이 완전히 포함하면 수식이 이긴다).
    var softRanges: [Range<Int>] = []
    var paragraphRanges: [Range<Int>] = []

    init(lineMap: UTF8LineMap, document: Markup, bytes: [UInt8]) {
        self.lineMap = lineMap
        self.document = document
        self.bytes = bytes
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        if let range = utf8Range(of: paragraph, lineMap: lineMap, shift: nil) {
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

    private mutating func shift(for markup: Markup) -> InlineColumnShift? {
        guard markup is InlineMarkup else { return nil }
        if let inlineShift { return inlineShift }
        let made = InlineColumnShift(document: document, lineMap: lineMap, bytes: bytes)
        inlineShift = made
        return made
    }

    private mutating func addForbidden(_ markup: Markup) {
        if let range = utf8Range(of: markup, lineMap: lineMap, shift: shift(for: markup)) {
            forbiddenRanges.append(range)
        }
    }

    private mutating func addSoft(_ markup: Markup) {
        if let range = utf8Range(of: markup, lineMap: lineMap, shift: shift(for: markup)) {
            softRanges.append(range)
        }
    }
}

/// swift-markdown SourceRange(1-based line/column, column은 UTF-8 byte) → 0-based UTF-8 offset range.
/// 인라인 노드는 `InlineColumnShift`로 swift-cmark의 연속 줄 밀림을 되돌린다. 블록 노드는 위치가 정확해 `shift`가 필요 없다.
private func utf8Range(of markup: Markup, lineMap: UTF8LineMap, shift: InlineColumnShift?) -> Range<Int>? {
    guard let range = markup.range else { return nil }
    let isInline = markup is InlineMarkup
    assert(!isInline || shift != nil, "인라인 노드 위치는 InlineColumnShift로 보정해야 한다")
    func offset(_ location: SourceLocation) -> Int? {
        if isInline, let shift { return shift.offset(line: location.line, column: location.column) }
        return lineMap.offset(line: location.line, column: location.column)
    }
    guard let lower = offset(range.lowerBound),
          let upper = offset(range.upperBound),
          lower <= upper
    else { return nil }
    return lower..<min(upper, lineMap.byteCount)
}

// MARK: - Pass 2 model build

/// `ModelBuilder.maskedSearchRange`의 문서 순서 커서. 한 번의 파싱 안에서만 쓴다.
private final class SearchCursor {
    var position = 0
}

private struct ModelBuilder {
    let originalBytes: [UInt8]
    let maskedBytes: [UInt8]
    let lineMap: UTF8LineMap
    let shift: InlineColumnShift
    /// 범위를 잃은 Text 노드를 가린 버퍼에서 찾을 때 문서 순서를 지키는 커서(이전 찾은 위치 다음부터 찾는다).
    private let searchCursor = SearchCursor()
    let inlineSpans: [ProtectedMathSpan]
    let displaySpans: [ProtectedMathSpan]

    init(originalBytes: [UInt8], maskedBytes: [UInt8], lineMap: UTF8LineMap, shift: InlineColumnShift, spans: [ProtectedMathSpan]) {
        self.originalBytes = originalBytes
        self.maskedBytes = maskedBytes
        self.lineMap = lineMap
        self.shift = shift
        self.inlineSpans = spans.filter { !$0.kind.isDisplay }
        self.displaySpans = spans.filter { $0.kind.isDisplay }
    }

    /// GFM 작업 목록 `[ ]`/`[x]`는 모델에 전용 블록이 없다. cmark-gfm이 지운 표식을 글자로 되살려
    /// Android(commonmark-java는 원문을 그대로 둔다)와 같은 결과를 내고 완료 상태 정보를 잃지 않는다.
    private func convertListItem(_ item: ListItem) -> [ParsedBlock] {
        var blocks = convertBlocks(item.blockChildren)
        guard item.checkbox != nil else { return blocks }
        // cmark-gfm은 `- [ ] 퀴즈- [x] 완료`처럼 같은 항목 뒤쪽의 `[x]`를 보고 체크됨으로 보고한다(퍼즈 패리티).
        // 표식 바로 뒤의 원문 상자를 읽는다.
        // 상자 뒤 공백도 원문 그대로 둔다(`[x]  완료`). 같은 줄에 내용이 없으면 끝 공백 없이 상자만 쓴다(블록 끝 공백 제거, Android와 같다).
        let box = sourceCheckboxIsChecked(item) ?? (item.checkbox == .checked) ? "[x]" : "[ ]"
        let marker = box + (sourceCheckboxSuffix(item) ?? " ")
        if case .paragraph(var runs) = blocks.first {
            if let first = runs.first, case .text(let text) = first.content,
               !first.bold, !first.italic, !first.strikethrough {
                runs[0].content = .text(marker + text)
            } else {
                runs.insert(InlineRun(content: .text(marker)), at: 0)
            }
            blocks[0] = .paragraph(runs)
        } else {
            blocks.insert(.paragraph([InlineRun(content: .text(marker))]), at: 0)
        }
        return blocks
    }

    /// 시작 위치로 정렬된 span 목록에서 range와 겹치는 것만 이진 탐색으로 꺼낸다. Text 노드마다 전체를 거르면
    /// O(span × node)다 (fixture pathological/mixed-delimiters-50000: span 2만 개에 10초 이상).
    private func spans(_ sorted: [ProtectedMathSpan], overlapping range: Range<Int>) -> [ProtectedMathSpan] {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].originalUTF8Range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sorted.count, sorted[end].originalUTF8Range.lowerBound < range.upperBound { end += 1 }
        return sorted[low..<end].filter { $0.originalUTF8Range.overlaps(range) }
    }

    /// 자식 블록을 차례로 변환한다. `Array(children.compactMap { … })`는 중첩 한 단계마다 지연 시퀀스 프레임 7개를 더 쌓아
    /// Debug·ASan 빌드에서 인용 64단계가 512 KB 협력 스레드를 넘쳤다(릴리스 빌드는 여유가 크다). 반복문으로 프레임을 줄인다.
    func convertBlocks(_ children: LazyMapSequence<MarkupChildren, BlockMarkup>) -> [ParsedBlock] {
        var blocks: [ParsedBlock] = []
        for child in children {
            if let block = convert(block: child) { blocks.append(block) }
        }
        return blocks
    }

    /// 블록 하나를 모델로 바꾼다. 인용·목록 중첩마다 재귀하므로 이 함수의 스택 프레임은 작게 유지하고 case 본문은 별도 함수에 둔다
    /// (Debug·ASan 빌드에서 모든 case의 지역 변수가 한 프레임(8 KB 이상)에 잡혀 인용 64단계가 512 KB 협력 스레드를 넘쳤다).
    func convert(block: BlockMarkup) -> ParsedBlock? {
        switch block {
        case let paragraph as Paragraph:
            return convertParagraph(paragraph)
        case let heading as Heading:
            return .heading(level: heading.level, runs: inlineRuns(of: heading))
        case let code as CodeBlock:
            return convertCodeBlock(code)
        case let quote as BlockQuote:
            return .blockQuote(convertBlocks(quote.blockChildren))
        case let list as UnorderedList:
            return .unorderedList(items: convertListItems(list.listItems))
        case let list as OrderedList:
            return .orderedList(start: Int(list.startIndex), items: convertListItems(list.listItems))
        case let table as Table:
            return convertTable(table)
        case is ThematicBreak:
            return .thematicBreak
        case let html as HTMLBlock:
            return convertHTMLBlock(html)
        default:
            return fallbackBlock(block)
        }
    }

    private func convertParagraph(_ paragraph: Paragraph) -> ParsedBlock {
        if let range = utf8Range(of: paragraph, lineMap: lineMap, shift: shift),
           let span = spans(displaySpans, overlapping: range).first {
            return .blockMath(MathSegment(span: span))
        }
        return .paragraph(inlineRuns(of: paragraph))
    }

    private func convertCodeBlock(_ code: CodeBlock) -> ParsedBlock {
        let language = code.language?.trimmingCharacters(in: .whitespaces)
        var body = code.code
        if body.hasSuffix("\n") { body.removeLast() }
        return .codeBlock(language: (language?.isEmpty ?? true) ? nil : language, code: body)
    }

    private func convertListItems(_ items: LazyMapSequence<MarkupChildren, ListItem>) -> [[ParsedBlock]] {
        var converted: [[ParsedBlock]] = []
        for item in items { converted.append(convertListItem(item)) }
        return converted
    }

    private func convertTable(_ table: Table) -> ParsedBlock? {
        let columnCount = table.body.rows.reduce(table.head.childCount) {
            max($0, $1.childCount)
        }
        let cellCount = table.body.rows.reduce(table.head.childCount) {
            $0 + $1.childCount
        }
        guard columnCount <= InputLimits.maxTableColumns,
              cellCount <= InputLimits.maxTableCells
        else {
            return fallbackBlock(table)
        }

        let header = Array(table.head.cells.map { inlineRuns(of: $0) })
        let rows = Array(table.body.rows.map { row in
            Array(row.cells.map { inlineRuns(of: $0) })
        })
        return .table(ParsedTable(
            columnAlignments: table.columnAlignments.map { alignment in
                switch alignment {
                case .some(.left): .left
                case .some(.center): .center
                case .some(.right): .right
                case .none: nil
                }
            },
            header: header,
            rows: rows
        ))
    }

    private func convertHTMLBlock(_ html: HTMLBlock) -> ParsedBlock {
        // HTML은 실행하지 않고 문자 그대로 표시한다.
        var literal = html.rawHTML
        if literal.hasSuffix("\n") { literal.removeLast() }
        return .paragraph([InlineRun(content: .text(literal))])
    }

    /// 미지원 노드와 렌더 상한을 넘는 표는 조용히 삭제하지 않고 plain text로 낮춘다.
    private func fallbackBlock(_ block: BlockMarkup) -> ParsedBlock? {
        let source: String
        if let range = utf8Range(of: block, lineMap: lineMap, shift: shift) {
            source = String(decoding: originalBytes[range], as: UTF8.self)
        } else {
            source = block.format()
        }
        let fallback = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return nil }
        return .paragraph([InlineRun(content: .text(fallback))])
    }

    /// 링크 라벨·이미지 대체 텍스트. swift-markdown `plainText`는 코드 span을 백틱째 돌려주지만 화면에 보이는 글자는
    /// 코드 내용뿐이다(CommonMark 예제 516·530). Android `plainText()`와 같은 규칙: 줄바꿈은 공백 하나.
    private static func labelText(of markup: Markup) -> String {
        switch markup {
        case let text as Markdown.Text: return text.string
        case let code as InlineCode: return code.code
        case let html as InlineHTML: return html.rawHTML
        case is SoftBreak, is LineBreak: return " "
        default: return markup.children.map(labelText(of:)).joined()
        }
    }

    private func inlineRuns(of container: Markup) -> [InlineRun] {
        var runs: [InlineRun] = []
        for child in container.children {
            appendRuns(for: child, bold: false, italic: false, strikethrough: false, into: &runs)
        }
        // CommonMark은 소프트·하드 줄바꿈 앞의 끝 공백·탭을 지운다. 원문 slice 경로에는 남아 있어 수식이 있는 줄에서만
        // 공백이 보였다(퍼즈 패리티, Android와 같은 규칙).
        for index in runs.indices.dropLast() {
            guard case .text(let text) = runs[index].content else { continue }
            switch runs[index + 1].content {
            case .softBreak, .hardBreak:
                var trimmed = Substring(text)
                while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
                if trimmed.count != text.count { runs[index].content = .text(String(trimmed)) }
            default:
                break
            }
        }
        // 하드 줄바꿈 다음 줄의 앞 공백은 무시한다(CommonMark 하드 줄바꿈 규칙). swift-cmark는 `- a \` 뒤 줄이 ` \`처럼
        // 공백과 글자 그대로의 `\`뿐이면 앞 공백을 Text에 남긴다(퍼즈 10만 회, Android는 지움).
        for index in runs.indices.dropFirst() {
            guard case .hardBreak = runs[index - 1].content, case .text(let text) = runs[index].content else { continue }
            let trimmed = text.drop { $0 == " " || $0 == "\t" }
            if trimmed.count != text.count { runs[index].content = .text(String(trimmed)) }
        }
        // 빈 글자 run은 화면에 아무것도 그리지 않는다. 빈 라벨 링크·줄 끝 공백에서 생기며 Android와 같게 뺀다(CommonMark 예제 484·556).
        return runs.filter { run in
            if case .text(let text) = run.content { return !text.isEmpty }
            return true
        }
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
            let label = Self.labelText(of: link)
            if let url = LinkPolicy.allowedURL(from: link.destination) {
                runs.append(run(.link(text: label, destination: url)))
            } else {
                // 상대 URL과 비허용 scheme은 plain text로 표시한다.
                runs.append(run(.text(label)))
            }

        case let image as Image:
            // 이미지 문법은 alt text만 표시한다.
            let alt = Self.labelText(of: image)
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

    /// Text 노드의 원문 범위. cmark-gfm 취소선 확장은 끝에 짝 없는 `~`가 남은 Text를 합치면서 끝 위치(또는 범위 전체)를
    /// 잃는다(`값 \\(x\\) 끝~` → 범위 1:1-1:1). 그대로 두면 수식 span을 찾지 못해 가림 문자 `xxxxx`가 화면에 나왔다
    /// (퍼즈 패리티로 발견). 범위가 비었으면 앞 형제의 끝·다음 형제의 시작·줄 끝으로 되살린다.
    private func textRange(of text: Markdown.Text) -> Range<Int>? {
        guard let range = unclampedTextRange(of: text) else { return nil }
        // Text 노드는 줄을 넘지 않는다(줄바꿈은 별도 노드). 보정한 범위가 줄 끝 문자를 넘으면 그 앞에서 자른다 —
        // 게으른 인용 연속 줄에서 swift-cmark가 앞 공백을 세는 바람에 끝이 한 바이트 밀려 `\n`이 글자로 새었다(퍼즈 10만 회).
        if let newline = originalBytes[range].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            return range.lowerBound..<newline
        }
        return range
    }

    private func unclampedTextRange(of text: Markdown.Text) -> Range<Int>? {
        if let range = utf8Range(of: text, lineMap: lineMap, shift: shift), !range.isEmpty || text.string.isEmpty {
            return trimmingLeftoverDelimiters(range, text: text.string)
        }
        guard !text.string.isEmpty else { return nil }
        guard let start = text.range.flatMap({ shift.offset(line: $0.lowerBound.line, column: $0.lowerBound.column) }) ?? inferredStart(of: text)
        else { return maskedSearchRange(of: text.string) }
        let end = inferredEnd(of: text, from: start)
        return end > start ? start..<end : nil
    }

    /// cmark-gfm 표 확장이 앞 문단의 줄을 가져가면 남은 문단·강조·Text가 위치를 모두 잃는다(퍼즈 패리티:
    /// `**판별식**\\(D\\)의 …` 뒤에 표 머리 행). 가린 버퍼는 원문과 길이·글자가 같고 수식만 `x`로 가렸으므로
    /// Text 글자를 가린 버퍼에서 문서 순서대로 찾는다. 이스케이프·엔티티가 있으면 글자가 달라 찾지 못하고 nil이다.
    /// 원문의 Markdown 이스케이프(`\` + ASCII 구두점)는 노드 글자에서 구두점 하나가 되므로 그 차이를 허용해 맞춘다
    /// (퍼즈 10만 회: 표 머리 행 앞 문단의 `x^2\)`를 찾지 못해 fail-open으로 `x^2)`가 됐다).
    private func maskedSearchRange(of text: String) -> Range<Int>? {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, needle.count <= maskedBytes.count else { return nil }
        func isASCIIPunctuation(_ byte: UInt8) -> Bool {
            (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
        }
        func match(at start: Int) -> Int? {
            var j = 0, k = start
            while j < needle.count {
                guard k < maskedBytes.count else { return nil }
                if maskedBytes[k] == needle[j] {
                    k += 1
                } else if maskedBytes[k] == 0x5C, k + 1 < maskedBytes.count, maskedBytes[k + 1] == needle[j], isASCIIPunctuation(needle[j]) {
                    k += 2
                } else {
                    return nil
                }
                j += 1
            }
            return k
        }
        var i = searchCursor.position
        while i + needle.count <= maskedBytes.count {
            if maskedBytes[i] == needle[0] || maskedBytes[i] == 0x5C, let end = match(at: i) {
                searchCursor.position = end
                return i..<end
            }
            i += 1
        }
        return nil
    }

    /// 앞 형제가 범위를 가지면 그 끝, 줄바꿈이면 다음 줄의 내용 시작(앞 공백·`>` 다음).
    private func inferredStart(of text: Markdown.Text) -> Int? {
        guard let parent = text.parent else { return nil }
        var index = text.indexInParent - 1
        var crossedBreak = false
        while index >= 0, let sibling = parent.child(at: index) {
            if sibling is SoftBreak || sibling is LineBreak { crossedBreak = true; index -= 1; continue }
            guard let range = utf8Range(of: sibling, lineMap: lineMap, shift: shift) else { return nil }
            guard crossedBreak else { return range.upperBound }
            guard var offset = lineMap.lineStart(lineMap.line(containing: max(range.upperBound - 1, range.lowerBound)) + 1) else { return nil }
            while offset < originalBytes.count, [0x20, 0x09, 0x3E].contains(originalBytes[offset]) { offset += 1 }
            return offset
        }
        return nil
    }

    /// 다음 형제가 범위를 가지면 그 시작, 아니면(줄바꿈·마지막) 시작 줄의 내용 끝에서 끝 공백을 뺀 위치.
    private func inferredEnd(of text: Markdown.Text, from start: Int) -> Int {
        if let parent = text.parent, text.indexInParent + 1 < parent.childCount,
           let next = parent.child(at: text.indexInParent + 1), !(next is SoftBreak || next is LineBreak),
           let range = utf8Range(of: next, lineMap: lineMap, shift: shift), range.lowerBound > start {
            return range.lowerBound
        }
        var end = lineMap.lineEnd(lineMap.line(containing: start)) ?? originalBytes.count
        // 표 셀 안이면 셀 끝을 넘지 않는다. 짝 없는 `~`만 있는 셀의 Text는 길이 0으로 보고되어, 줄 끝까지 잡으면
        // 행 전체(`~| x\) | y |`)가 첫 셀 글자가 됐다(퍼즈 10만 회). 셀 위치도 표 행 보정을 거쳐야 맞다.
        if let cell = text.parent as? Table.Cell, let cellRange = cell.range,
           let cellEnd = shift.offset(line: cellRange.upperBound.line, column: cellRange.upperBound.column), cellEnd > start {
            end = min(end, cellEnd)
        }
        while end > start, originalBytes[end - 1] == 0x20 || originalBytes[end - 1] == 0x09 { end -= 1 }
        return end
    }

    /// 목록 표식(`-`·`+`·`*`·`1.`·`1)`)과 공백 뒤 `[`의 원문 위치. 상자 모양(`[?]`)이 아니면 nil.
    private func sourceCheckboxStart(_ item: ListItem) -> Int? {
        guard let start = item.range.flatMap({ lineMap.offset(line: $0.lowerBound.line, column: $0.lowerBound.column) }) else { return nil }
        var i = start
        let bytes = originalBytes
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        guard i < bytes.count, [0x2D, 0x2B, 0x2A, 0x2E, 0x29].contains(bytes[i]) else { return nil }
        i += 1
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        guard i + 2 < bytes.count, bytes[i] == 0x5B, bytes[i + 2] == 0x5D else { return nil }
        return i
    }

    /// 상자 뒤부터 같은 줄 내용 앞까지의 공백·탭. 내용이 없으면 빈 문자열, 상자를 찾지 못하면 nil.
    private func sourceCheckboxSuffix(_ item: ListItem) -> String? {
        guard let box = sourceCheckboxStart(item) else { return nil }
        var end = box + 3
        while end < originalBytes.count, originalBytes[end] == 0x20 || originalBytes[end] == 0x09 { end += 1 }
        if end >= originalBytes.count || originalBytes[end] == 0x0A || originalBytes[end] == 0x0D { return "" }
        return String(decoding: originalBytes[(box + 3)..<end], as: UTF8.self)
    }

    /// 목록 표식(`-`·`+`·`*`·`1.`·`1)`)과 공백 뒤의 `[ ]`·`[x]`·`[X]`. 찾지 못하면 nil.
    private func sourceCheckboxIsChecked(_ item: ListItem) -> Bool? {
        guard let i = sourceCheckboxStart(item) else { return nil }
        let bytes = originalBytes
        switch bytes[i + 1] {
        case 0x20: return false
        case 0x78, 0x58: return true
        default: return nil
        }
    }

    /// swift-cmark는 일부만 강조로 쓰인 구분자 묶음(`**영벡터*`의 남은 `*`)에서 Text 범위를 묶음 전체로 보고한다.
    /// 원문 slice 앞뒤의 `*`·`_`·`~`가 노드 글자보다 많으면 그만큼 범위를 줄인다(구분자는 모두 1바이트 ASCII).
    private func trimmingLeftoverDelimiters(_ range: Range<Int>, text: String) -> Range<Int> {
        func isDelimiter(_ byte: UInt8) -> Bool { byte == 0x2A || byte == 0x5F || byte == 0x7E }
        let textBytes = Array(text.utf8)
        var lower = range.lowerBound
        var upper = range.upperBound
        let leadingText = textBytes.prefix(while: isDelimiter).count
        var leadingSlice = 0
        while lower + leadingSlice < upper, isDelimiter(originalBytes[lower + leadingSlice]) { leadingSlice += 1 }
        if leadingSlice > leadingText { lower += leadingSlice - leadingText }
        let trailingText = textBytes.reversed().prefix(while: isDelimiter).count
        var trailingSlice = 0
        while upper - trailingSlice > lower, isDelimiter(originalBytes[upper - trailingSlice - 1]) { trailingSlice += 1 }
        if trailingSlice > trailingText { upper -= trailingSlice - trailingText }
        return lower..<upper
    }

    /// masked Text 노드를 원문 slice로 되돌리고, 겹치는 inline 수식 span을 math run으로 쪼갠다.
    private func appendTextRuns(
        for text: Markdown.Text,
        style: (InlineRun.Content) -> InlineRun,
        into runs: inout [InlineRun]
    ) {
        guard let range = textRange(of: text) else {
            // range가 없으면 fail-open: masked 문자열 대신 노드 문자열 그대로.
            runs.append(style(.text(text.string)))
            return
        }

        // span이 없으면 second pass의 Text가 Markdown entity/escape를 이미 해제했다.
        // 단, 수식 구분자 escape는 malformed LaTex를 원문으로 보여 주는 fail-open 계약이라
        // 원문 slice 경로를 유지한다. 이 fast path가 여러 entity Text마다 parser를 다시
        // 만드는 O(n^2) 경로를 막는다.
        let overlappingSpans = spans(inlineSpans, overlapping: range)
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

    /// 바이트로 찾는다. `String.contains`는 문자 묶음 단위라 `\(` 뒤에 너비 없는 결합자(U+200D)·결합 문자가 붙으면
    /// `(`가 다른 문자 묶음이 되어 놓쳤다(퍼즈 패리티: `\(\u{200D}👩` → 이스케이프가 풀린 `(`로 표시).
    private func containsLiteralMathDelimiterEscape(in range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i + 1 < range.upperBound {
            if originalBytes[i] == 0x5C, [0x28, 0x29, 0x5B, 0x5D].contains(originalBytes[i + 1]) { return true }
            i += 1
        }
        return false
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
        return "\(sentinel)richmarkdown-\(serial)\(sentinel)"
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
    let document = Document(parsing: markdown, options: RichMarkdownParser.parseOptions)
    for block in document.blockChildren {
        if let paragraph = block as? Paragraph {
            return paragraph.plainText
        }
    }
    return nil
}
