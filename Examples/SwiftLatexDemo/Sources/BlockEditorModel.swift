// Created by JunyoungJung on 2026-08-21.

import Foundation

enum EditorBlockKind: Equatable, Hashable {
    case paragraph
    case heading(level: Int)
    case bulletedList
    case numberedList
    case toDo(isChecked: Bool)
    case quote
    case code(language: String?)
    case equation

    var title: String {
        switch self {
        case .paragraph: "텍스트"
        case let .heading(level): "제목 \(level)"
        case .bulletedList: "글머리 기호 목록"
        case .numberedList: "번호 매기기 목록"
        case .toDo: "할 일"
        case .quote: "인용"
        case .code: "코드"
        case .equation: "수식"
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: "textformat"
        case .heading: "textformat.size"
        case .bulletedList: "list.bullet"
        case .numberedList: "list.number"
        case .toDo: "checkmark.square"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .equation: "function"
        }
    }

    var continuationKind: EditorBlockKind {
        switch self {
        case .bulletedList, .numberedList, .toDo:
            self
        default:
            .paragraph
        }
    }

    var supportsIndentation: Bool {
        switch self {
        case .bulletedList, .numberedList, .toDo:
            true
        default:
            false
        }
    }

    var supportsRenderedCaret: Bool {
        switch self {
        case .paragraph, .heading:
            true
        default:
            false
        }
    }

    var preservesLineBreaks: Bool {
        switch self {
        case .code, .equation:
            true
        default:
            false
        }
    }
}

struct EditorBlock: Identifiable, Equatable {
    let id: UUID
    var kind: EditorBlockKind
    var text: String
    var inlineMarks: [InlineMark]
    var indentLevel: Int

    init(
        id: UUID = UUID(),
        kind: EditorBlockKind = .paragraph,
        text: String,
        inlineMarks: [InlineMark] = [],
        indentLevel: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.inlineMarks = InlineMarkdownCodec.normalized(inlineMarks, text: text)
        self.indentLevel = indentLevel
    }

    init(markdown: String) {
        id = UUID()
        let leadingSpaces = markdown.prefix { $0 == " " }.count
        let deindented = String(markdown.dropFirst(leadingSpaces))
        let source: String
        if Self.hasListMarker(deindented) {
            indentLevel = min(leadingSpaces / 2, 3)
            source = deindented
        } else {
            indentLevel = 0
            source = markdown
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("```"), lines.count >= 2,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            let language = String(first.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            kind = .code(language: language.isEmpty ? nil : language)
            text = lines.dropFirst().dropLast().joined(separator: "\n")
            inlineMarks = []
            return
        }

        if source.hasPrefix("\\["), source.hasSuffix("\\]"), source.count >= 4 {
            kind = .equation
            text = String(source.dropFirst(2).dropLast(2))
            inlineMarks = []
            return
        }

        let markerCount = source.prefix { $0 == "#" }.count
        if (1...3).contains(markerCount), source.dropFirst(markerCount).hasPrefix(" ") {
            kind = .heading(level: markerCount)
            (text, inlineMarks) = InlineMarkdownCodec.parse(
                String(source.dropFirst(markerCount + 1))
            )
            return
        }

        if source.hasPrefix("- [ ] ") || source.hasPrefix("- [x] ") {
            kind = .toDo(isChecked: source.hasPrefix("- [x] "))
            (text, inlineMarks) = InlineMarkdownCodec.parse(String(source.dropFirst(6)))
            return
        }
        if source.hasPrefix("- ") || source.hasPrefix("* ") || source.hasPrefix("+ ") {
            kind = .bulletedList
            (text, inlineMarks) = InlineMarkdownCodec.parse(String(source.dropFirst(2)))
            return
        }
        if let match = source.range(of: #"^\d+\. "#, options: .regularExpression) {
            kind = .numberedList
            (text, inlineMarks) = InlineMarkdownCodec.parse(String(source[match.upperBound...]))
            return
        }
        if source.hasPrefix("> ") {
            kind = .quote
            (text, inlineMarks) = InlineMarkdownCodec.parse(String(source.dropFirst(2)))
            return
        }

        kind = .paragraph
        (text, inlineMarks) = InlineMarkdownCodec.parse(source)
    }

    var markdown: String {
        markdown(numberedListOrdinal: 1)
    }

    func markdown(numberedListOrdinal: Int) -> String {
        let indent = String(repeating: "  ", count: indentLevel)
        let inlineMarkdown = InlineMarkdownCodec.serialize(text: text, marks: inlineMarks)
        return switch kind {
        case .paragraph:
            inlineMarkdown
        case let .heading(level):
            String(repeating: "#", count: min(max(level, 1), 3)) + " " + inlineMarkdown
        case .bulletedList:
            indent + "- " + inlineMarkdown
        case .numberedList:
            indent + "\(max(numberedListOrdinal, 1)). " + inlineMarkdown
        case let .toDo(isChecked):
            indent + (isChecked ? "- [x] " : "- [ ] ") + inlineMarkdown
        case .quote:
            "> " + inlineMarkdown
        case let .code(language):
            "```\(language ?? "")\n\(text)\n```"
        case .equation:
            "\\[\(text)\\]"
        }
    }

    private static func hasListMarker(_ source: String) -> Bool {
        if source.hasPrefix("- ") || source.hasPrefix("* ") || source.hasPrefix("+ ") {
            return true
        }
        return source.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }
}

struct BlockSelection: Equatable {
    let blockID: UUID
    let range: NSRange
}

enum InlineFormat: Int, CaseIterable, Hashable {
    case bold
    case italic
    case strikethrough
    case code

    var delimiters: (opening: String, closing: String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("<em>", "</em>")
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        }
    }
}

struct InlineMark: Equatable {
    let format: InlineFormat
    var range: NSRange
}

private enum InlineMarkdownCodec {
    private struct ParseResult {
        var text = ""
        var marks: [InlineMark] = []
        var closed = false
    }

    static func parse(_ source: String) -> (text: String, marks: [InlineMark]) {
        var index = source.startIndex
        let result = parse(source, index: &index, closing: nil)
        return (result.text, normalized(result.marks, text: result.text))
    }

    static func serialize(text: String, marks: [InlineMark]) -> String {
        let marks = normalized(marks, text: text).filter { $0.range.length > 0 }
        guard !marks.isEmpty else { return escaped(text, insideCode: false) }

        var boundaries: Set<Int> = [0, text.utf16.count]
        for mark in marks {
            boundaries.insert(mark.range.location)
            boundaries.insert(NSMaxRange(mark.range))
        }

        let offsets = boundaries.sorted()
        var result = ""
        var active: [InlineFormat] = []
        for (start, end) in zip(offsets, offsets.dropFirst()) {
            let desired = activeFormats(at: start, marks: marks)
            transition(from: &active, to: desired, result: &result)
            guard let range = Range(NSRange(location: start, length: end - start), in: text) else {
                continue
            }
            result += escaped(String(text[range]), insideCode: active.contains(.code))
        }
        transition(from: &active, to: [], result: &result)
        return result
    }

    static func normalized(_ marks: [InlineMark], text: String) -> [InlineMark] {
        let latexRanges = inlineLatexRanges(in: text)
        let valid = marks
            .filter {
                $0.range.location >= 0
                    && $0.range.length > 0
                    && NSMaxRange($0.range) <= text.utf16.count
                    && Range($0.range, in: text) != nil
            }
            .flatMap { mark in
                if mark.format == .code { return [mark] }
                return subtract(latexRanges, from: mark.range).map {
                    InlineMark(format: mark.format, range: $0)
                }
            }
            .sorted {
                if $0.range.location != $1.range.location {
                    return $0.range.location < $1.range.location
                }
                if $0.range.length != $1.range.length {
                    return $0.range.length > $1.range.length
                }
                return $0.format.rawValue < $1.format.rawValue
            }

        var merged: [InlineMark] = []
        for format in InlineFormat.allCases {
            for mark in valid.filter({ $0.format == format }) {
                if let lastIndex = merged.indices.last,
                   merged[lastIndex].format == format,
                   mark.range.location <= NSMaxRange(merged[lastIndex].range) {
                    merged[lastIndex].range = NSUnionRange(merged[lastIndex].range, mark.range)
                } else {
                    merged.append(mark)
                }
            }
        }
        let codeRanges = merged.filter { $0.format == .code }.map(\.range)
        let effective = merged.flatMap { mark -> [InlineMark] in
            guard mark.format != .code else { return [mark] }
            return subtract(codeRanges, from: mark.range).map {
                InlineMark(format: mark.format, range: $0)
            }
        }
        return effective.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            if $0.range.length != $1.range.length {
                return $0.range.length > $1.range.length
            }
            return $0.format.rawValue < $1.format.rawValue
        }
    }

    private static func inlineLatexRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex {
            if let range = inlineLatexRange(in: text, at: index) {
                ranges.append(NSRange(range, in: text))
                index = range.upperBound
            } else {
                index = text.index(after: index)
            }
        }
        return ranges
    }

    private static func subtract(_ exclusions: [NSRange], from source: NSRange) -> [NSRange] {
        var segments = [source]
        for exclusion in exclusions {
            segments = segments.flatMap { segment in
                let intersection = NSIntersectionRange(segment, exclusion)
                guard intersection.length > 0 else { return [segment] }
                var result: [NSRange] = []
                if segment.location < intersection.location {
                    result.append(NSRange(
                        location: segment.location,
                        length: intersection.location - segment.location
                    ))
                }
                if NSMaxRange(intersection) < NSMaxRange(segment) {
                    result.append(NSRange(
                        location: NSMaxRange(intersection),
                        length: NSMaxRange(segment) - NSMaxRange(intersection)
                    ))
                }
                return result
            }
        }
        return segments
    }

    private static func parse(
        _ source: String,
        index: inout String.Index,
        closing: String?
    ) -> ParseResult {
        var result = ParseResult()
        while index < source.endIndex {
            if let latexRange = inlineLatexRange(in: source, at: index) {
                result.text += source[latexRange]
                index = latexRange.upperBound
                continue
            }
            if source[index] == "\\",
               let escapedIndex = source.index(index, offsetBy: 1, limitedBy: source.endIndex),
               escapedIndex < source.endIndex,
               isEscapable(source[escapedIndex]) {
                result.text.append(source[escapedIndex])
                index = source.index(after: escapedIndex)
                continue
            }
            if let closing, source[index...].hasPrefix(closing) {
                index = source.index(index, offsetBy: closing.count)
                result.closed = true
                return result
            }

            if let token = openingToken(in: source, at: index) {
                let format = token.format
                let delimiterEnd = source.index(
                    index,
                    offsetBy: token.opening.count
                )
                guard closingRange(
                    token.closing,
                    in: source,
                    from: delimiterEnd
                ) != nil else {
                    let next = source.index(after: index)
                    result.text += source[index..<next]
                    index = next
                    continue
                }
                index = delimiterEnd
                let start = result.text.utf16.count
                if format == .code,
                   let end = closingRange(token.closing, in: source, from: index) {
                    let content = decodedCodeEscapes(String(source[index..<end.lowerBound]))
                    result.text += content
                    index = end.upperBound
                } else {
                    let nested = parse(source, index: &index, closing: token.closing)
                    guard nested.closed else {
                        result.text += token.opening + nested.text
                        result.marks += shifted(
                            nested.marks,
                            by: start + token.opening.utf16.count
                        )
                        continue
                    }
                    result.text += nested.text
                    result.marks += shifted(nested.marks, by: start)
                }
                let length = result.text.utf16.count - start
                result.marks.append(InlineMark(
                    format: format,
                    range: NSRange(location: start, length: length)
                ))
                continue
            }

            let next = source.index(after: index)
            result.text += source[index..<next]
            index = next
        }
        return result
    }

    private static func closingRange(
        _ delimiter: String,
        in source: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor] == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex, isEscapable(source[next]) {
                    cursor = source.index(after: next)
                    continue
                }
            }
            if source[cursor...].hasPrefix(delimiter) {
                return cursor..<source.index(cursor, offsetBy: delimiter.count)
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func escaped(_ source: String, insideCode: Bool) -> String {
        let targets: Set<Character> = insideCode ? ["`"] : ["*", "_", "~", "`", "<"]
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if !insideCode, let latexRange = inlineLatexRange(in: source, at: index) {
                result += source[latexRange]
                index = latexRange.upperBound
                continue
            }
            let character = source[index]
            let next = source.index(after: index)
            if character == "\\",
               next < source.endIndex,
               (targets.contains(source[next]) || source[next] == "\\") {
                result += "\\\\"
            } else {
                if targets.contains(character) { result += "\\" }
                result.append(character)
            }
            index = next
        }
        return result
    }

    private static func inlineLatexRange(
        in source: String,
        at index: String.Index
    ) -> Range<String.Index>? {
        let delimiter: (opening: String, closing: String)
        if source[index...].hasPrefix("\\(") {
            delimiter = ("\\(", "\\)")
        } else if source[index...].hasPrefix("$$") {
            delimiter = ("$$", "$$")
        } else if source[index...].hasPrefix("$") {
            delimiter = ("$", "$")
        } else {
            return nil
        }

        let contentStart = source.index(index, offsetBy: delimiter.opening.count)
        guard let closingRange = source.range(
            of: delimiter.closing,
            range: contentStart..<source.endIndex
        ) else { return nil }
        if source[index..<closingRange.upperBound].contains(where: \.isNewline) {
            return nil
        }
        return index..<closingRange.upperBound
    }

    private static func decodedCodeEscapes(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex,
                   (source[next] == "`" || source[next] == "\\") {
                    result.append(source[next])
                    index = source.index(after: next)
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    private static func isEscapable(_ character: Character) -> Bool {
        character == "\\" || character == "*" || character == "_"
            || character == "~" || character == "`" || character == "<"
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func openingToken(
        in source: String,
        at index: String.Index
    ) -> (format: InlineFormat, opening: String, closing: String)? {
        for format in [InlineFormat.code, .bold, .strikethrough]
        where source[index...].hasPrefix(format.delimiters.opening) {
            return (format, format.delimiters.opening, format.delimiters.closing)
        }
        let italic = InlineFormat.italic.delimiters
        if source[index...].hasPrefix(italic.opening) {
            return (.italic, italic.opening, italic.closing)
        }
        if source[index...].hasPrefix("_") {
            let next = source.index(after: index)
            guard next < source.endIndex, !source[next].isWhitespace else { return nil }
            if index > source.startIndex {
                let previous = source[source.index(before: index)]
                if isWord(previous), isWord(source[next]) { return nil }
            }
            return (.italic, "_", "_")
        }
        if source[index...].hasPrefix("*") { return (.italic, "*", "*") }
        return nil
    }

    private static func shifted(_ marks: [InlineMark], by offset: Int) -> [InlineMark] {
        marks.map {
            InlineMark(
                format: $0.format,
                range: NSRange(location: $0.range.location + offset, length: $0.range.length)
            )
        }
    }

    private static func activeFormats(at offset: Int, marks: [InlineMark]) -> [InlineFormat] {
        let active = Set(marks.compactMap { mark in
            mark.range.location <= offset && offset < NSMaxRange(mark.range)
                ? mark.format
                : nil
        })
        if active.contains(.code) { return [.code] }
        return [InlineFormat.bold, .italic, .strikethrough].filter(active.contains)
    }

    private static func transition(
        from active: inout [InlineFormat],
        to desired: [InlineFormat],
        result: inout String
    ) {
        let commonCount = zip(active, desired).prefix { pair in
            pair.0 == pair.1
        }.count
        for format in active.dropFirst(commonCount).reversed() {
            result += format.delimiters.closing
        }
        for format in desired.dropFirst(commonCount) {
            result += format.delimiters.opening
        }
        active = desired
    }
}

private extension EditorBlock {
    func replacingText(in range: NSRange, with replacement: String) -> EditorBlock? {
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= text.utf16.count,
              let sourceRange = Range(range, in: text)
        else { return nil }

        let updatedText = text.replacingCharacters(in: sourceRange, with: replacement)
        let replacementLength = replacement.utf16.count
        let updatedMarks = inlineMarks.compactMap {
            Self.transformed($0, replacing: range, replacementLength: replacementLength)
        }
        return EditorBlock(
            id: id,
            kind: kind,
            text: updatedText,
            inlineMarks: updatedMarks,
            indentLevel: indentLevel
        )
    }

    func split(atUTF16Offset offset: Int) -> (left: EditorBlock, right: EditorBlock)? {
        guard let index = Self.stringIndex(in: text, utf16Offset: offset) else { return nil }
        let leftText = String(text[..<index])
        let rightText = String(text[index...])
        var leftMarks: [InlineMark] = []
        var rightMarks: [InlineMark] = []

        for mark in inlineMarks {
            let start = mark.range.location
            let end = NSMaxRange(mark.range)
            let leftLength = max(0, min(end, offset) - start)
            if leftLength > 0 || mark.range.length == 0 && start < offset {
                leftMarks.append(InlineMark(
                    format: mark.format,
                    range: NSRange(location: start, length: leftLength)
                ))
            }

            let rightStart = max(start, offset)
            let rightLength = max(0, end - rightStart)
            if rightLength > 0 || mark.range.length == 0 && start >= offset {
                rightMarks.append(InlineMark(
                    format: mark.format,
                    range: NSRange(location: rightStart - offset, length: rightLength)
                ))
            }
        }

        let continuation = kind.continuationKind
        return (
            EditorBlock(
                id: id,
                kind: kind,
                text: leftText,
                inlineMarks: leftMarks,
                indentLevel: indentLevel
            ),
            EditorBlock(
                kind: continuation,
                text: rightText,
                inlineMarks: rightMarks,
                indentLevel: continuation.supportsIndentation ? indentLevel : 0
            )
        )
    }

    func merged(with following: EditorBlock) -> EditorBlock {
        let offset = text.utf16.count
        let shifted = following.inlineMarks.map {
            InlineMark(
                format: $0.format,
                range: NSRange(location: $0.range.location + offset, length: $0.range.length)
            )
        }
        return EditorBlock(
            id: id,
            kind: kind,
            text: text + following.text,
            inlineMarks: inlineMarks + shifted,
            indentLevel: indentLevel
        )
    }

    func changingKind(to kind: EditorBlockKind, indentLevel: Int? = nil) -> EditorBlock {
        EditorBlock(
            id: id,
            kind: kind,
            text: text,
            inlineMarks: kind.preservesLineBreaks ? [] : inlineMarks,
            indentLevel: indentLevel ?? (kind.supportsIndentation ? self.indentLevel : 0)
        )
    }

    func subblock(
        in range: NSRange,
        id: UUID,
        kind: EditorBlockKind,
        indentLevel: Int
    ) -> EditorBlock? {
        guard let sourceRange = Range(range, in: text) else { return nil }
        let subtext = String(text[sourceRange])
        let marks = inlineMarks.compactMap { mark -> InlineMark? in
            let start = max(mark.range.location, range.location)
            let end = min(NSMaxRange(mark.range), NSMaxRange(range))
            guard end > start else { return nil }
            return InlineMark(
                format: mark.format,
                range: NSRange(location: start - range.location, length: end - start)
            )
        }
        return EditorBlock(
            id: id,
            kind: kind,
            text: subtext,
            inlineMarks: marks,
            indentLevel: indentLevel
        )
    }

    private static func transformed(
        _ mark: InlineMark,
        replacing range: NSRange,
        replacementLength: Int
    ) -> InlineMark? {
        let markStart = mark.range.location
        let markEnd = NSMaxRange(mark.range)
        let changeStart = range.location
        let changeEnd = NSMaxRange(range)
        let delta = replacementLength - range.length

        if range.length == 0 {
            if changeStart < markStart {
                return InlineMark(
                    format: mark.format,
                    range: NSRange(location: markStart + delta, length: mark.range.length)
                )
            }
            if changeStart > markEnd { return mark }
            return InlineMark(
                format: mark.format,
                range: NSRange(location: markStart, length: mark.range.length + replacementLength)
            )
        }

        if markEnd <= changeStart { return mark }
        if markStart >= changeEnd {
            return InlineMark(
                format: mark.format,
                range: NSRange(location: markStart + delta, length: mark.range.length)
            )
        }

        let prefixLength = max(0, changeStart - markStart)
        let suffixLength = max(0, markEnd - changeEnd)
        let updatedLength = prefixLength + replacementLength + suffixLength
        guard updatedLength > 0 else { return nil }
        return InlineMark(
            format: mark.format,
            range: NSRange(
                location: min(markStart, changeStart),
                length: updatedLength
            )
        )
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(utf16Index, within: text)
    }
}

struct BlockEditorModel {
    private struct HistoryEntry {
        let blocks: [EditorBlock]
        let documentSelection: NSRange?
    }

    private struct DocumentBlockRange {
        let index: Int
        let content: NSRange
    }

    private static let historyLimit = 100
    private(set) var blocks: [EditorBlock]
    private(set) var currentSelection: BlockSelection? = nil
    private(set) var currentDocumentSelection: NSRange? = nil
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    init(markdown: String) {
        blocks = Self.normalized(Self.split(markdown).map(EditorBlock.init(markdown:)))
    }

    init(blocks: [EditorBlock]) {
        self.blocks = Self.normalized(blocks)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var documentText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    func block(id: UUID) -> EditorBlock? {
        blocks.first { $0.id == id }
    }

    mutating func updateSelection(_ selection: BlockSelection?) {
        let validated = Self.validated(selection, in: blocks)
        currentSelection = validated
        currentDocumentSelection = validated.flatMap(documentRange(for:))
    }

    mutating func updateDocumentSelection(_ selection: NSRange?) {
        guard let selection else {
            currentSelection = nil
            currentDocumentSelection = nil
            return
        }
        guard Self.validated(selection, in: documentText) != nil else { return }
        currentDocumentSelection = selection
        currentSelection = blockSelection(for: selection)
    }

    func documentRange(for blockID: UUID) -> NSRange? {
        documentBlockRanges().first { blocks[$0.index].id == blockID }?.content
    }

    func documentRange(for selection: BlockSelection) -> NSRange? {
        guard let blockRange = documentRange(for: selection.blockID),
              NSMaxRange(selection.range) <= blockRange.length
        else { return nil }
        return NSRange(
            location: blockRange.location + selection.range.location,
            length: selection.range.length
        )
    }

    func blockSelection(for documentSelection: NSRange) -> BlockSelection? {
        guard Self.validated(documentSelection, in: documentText) != nil,
              let position = documentPosition(at: documentSelection.location)
        else { return nil }
        let block = blocks[position.index]
        let availableLength = block.text.utf16.count - position.offset
        return BlockSelection(
            blockID: block.id,
            range: NSRange(
                location: position.offset,
                length: min(documentSelection.length, availableLength)
            )
        )
    }

    func numberedListOrdinal(for id: UUID) -> Int? {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              blocks[index].kind == .numberedList
        else { return nil }

        let indentLevel = blocks[index].indentLevel
        var ordinal = 1
        var cursor = index - 1
        while cursor >= 0 {
            let candidate = blocks[cursor]
            if candidate.indentLevel < indentLevel { break }
            if candidate.indentLevel == indentLevel {
                guard candidate.kind == .numberedList else { break }
                ordinal += 1
            }
            cursor -= 1
        }
        return ordinal
    }

    mutating func updateText(id: UUID, text: String) {
        updateText(id: id, text: text, selection: currentSelection)
    }

    mutating func updateText(id: UUID, text: String, selection: BlockSelection?) {
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return block.replacingText(
                in: NSRange(location: 0, length: block.text.utf16.count),
                with: text
            ) ?? block
        }
        apply(updated)
        updateSelection(selection)
    }

    /// TextKit의 전역 UTF-16 변경을 논리 블록 변경으로 환원한다.
    /// 코드/수식 내부 개행은 같은 블록에 남고, 일반 개행은 새 블록을 만든다.
    @discardableResult
    mutating func replaceDocumentText(
        in range: NSRange,
        with replacement: String
    ) -> NSRange? {
        guard Self.validated(range, in: documentText) != nil else { return nil }
        let nextSelection = NSRange(
            location: range.location + replacement.utf16.count,
            length: 0
        )

        if range.location == 0, range.length == documentText.utf16.count {
            let parts = replacement.split(separator: "\n", omittingEmptySubsequences: false)
            let updated = parts.map { EditorBlock(kind: .paragraph, text: String($0)) }
            apply(updated)
            updateDocumentSelection(nextSelection)
            return currentDocumentSelection
        }

        guard let start = documentPosition(at: range.location),
              let end = documentPosition(at: NSMaxRange(range))
        else { return nil }
        let startBlock = blocks[start.index]
        let endBlock = blocks[end.index]

        if start.index == end.index,
           replacement == "\n",
           !startBlock.kind.preservesLineBreaks,
           let selection = splitBlock(
               id: startBlock.id,
               replacing: NSRange(
                   location: start.offset,
                   length: end.offset - start.offset
               )
           ),
           let documentSelection = documentRange(for: selection) {
            updateDocumentSelection(documentSelection)
            return currentDocumentSelection
        }

        if replacement.isEmpty,
           range.length == 1,
           start.index + 1 == end.index,
           start.offset == startBlock.text.utf16.count,
           end.offset == 0,
           let selection = backspaceAtStart(of: endBlock.id),
           let documentSelection = documentRange(for: selection) {
            updateDocumentSelection(documentSelection)
            return currentDocumentSelection
        }

        if start.index == end.index, startBlock.kind.preservesLineBreaks {
            guard let edited = startBlock.replacingText(
                in: NSRange(location: start.offset, length: end.offset - start.offset),
                with: replacement
            ) else { return nil }
            let updated = blocks.enumerated().map { index, block in
                index == start.index ? edited : block
            }
            apply(updated)
            updateDocumentSelection(nextSelection)
            return currentDocumentSelection
        }

        let parts = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let replacementBlocks: [EditorBlock]
        if parts.count == 1 {
            if start.index == end.index {
                guard let edited = startBlock.replacingText(
                    in: NSRange(location: start.offset, length: end.offset - start.offset),
                    with: parts[0]
                ) else { return nil }
                replacementBlocks = [edited]
            } else {
                guard let first = startBlock.replacingText(
                    in: NSRange(
                        location: start.offset,
                        length: startBlock.text.utf16.count - start.offset
                    ),
                    with: parts[0]
                ), let last = endBlock.replacingText(
                    in: NSRange(location: 0, length: end.offset),
                    with: ""
                ) else { return nil }
                replacementBlocks = [first.merged(with: last)]
            }
        } else {
            let continuationKind = startBlock.kind.continuationKind
            guard let first = startBlock.replacingText(
                in: NSRange(
                    location: start.offset,
                    length: startBlock.text.utf16.count - start.offset
                ),
                with: parts[0]
            ), let lastSource = endBlock.replacingText(
                in: NSRange(location: 0, length: end.offset),
                with: parts[parts.count - 1]
            ) else { return nil }
            var splitBlocks = [first]
            if parts.count > 2 {
                splitBlocks += parts[1..<(parts.count - 1)].map {
                    EditorBlock(
                        kind: continuationKind,
                        text: $0,
                        indentLevel: continuationKind.supportsIndentation ? startBlock.indentLevel : 0
                    )
                }
            }
            let preservesEndBlock = end.index != start.index
            splitBlocks.append(EditorBlock(
                id: preservesEndBlock ? endBlock.id : UUID(),
                kind: preservesEndBlock ? endBlock.kind : continuationKind,
                text: lastSource.text,
                inlineMarks: lastSource.inlineMarks,
                indentLevel: preservesEndBlock
                    ? endBlock.indentLevel
                    : (continuationKind.supportsIndentation ? startBlock.indentLevel : 0)
            ))
            replacementBlocks = splitBlocks
        }

        let updated = Array(blocks[..<start.index])
            + replacementBlocks
            + Array(blocks[(end.index + 1)...])
        apply(updated)
        updateDocumentSelection(nextSelection)
        return currentDocumentSelection
    }

    mutating func splitBlock(id: UUID, atUTF16Offset offset: Int) -> BlockSelection? {
        splitBlock(id: id, replacing: NSRange(location: offset, length: 0))
    }

    mutating func splitBlock(id: UUID, replacing range: NSRange) -> BlockSelection? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }

        let current = blocks[index]
        guard let edited = current.replacingText(in: range, with: ""),
              let parts = edited.split(atUTF16Offset: range.location)
        else { return nil }
        if edited.text.isEmpty, current.kind.supportsIndentation {
            transform(id: id, to: .paragraph)
            return BlockSelection(blockID: id, range: NSRange(location: 0, length: 0))
        }

        let updated = Array(blocks[..<index]) + [parts.left, parts.right] + Array(blocks[(index + 1)...])
        apply(updated)
        return BlockSelection(blockID: parts.right.id, range: NSRange(location: 0, length: 0))
    }

    mutating func insertSoftBreak(id: UUID, atUTF16Offset offset: Int) -> BlockSelection? {
        insertSoftBreak(id: id, replacing: NSRange(location: offset, length: 0))
    }

    mutating func insertSoftBreak(id: UUID, replacing range: NSRange) -> BlockSelection? {
        guard let block = block(id: id) else { return nil }
        return block.kind.preservesLineBreaks
            ? replaceText(id: id, range: range, with: "\n")
            : splitBlock(id: id, replacing: range)
    }

    mutating func backspaceAtStart(of id: UUID) -> BlockSelection? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        let current = blocks[index]
        guard current.kind == .paragraph else {
            transform(id: id, to: .paragraph)
            return BlockSelection(blockID: id, range: NSRange(location: 0, length: 0))
        }
        guard index > 0 else { return nil }

        let previous = blocks[index - 1]
        if case .code = previous.kind {
            return BlockSelection(
                blockID: previous.id,
                range: NSRange(location: previous.text.utf16.count, length: 0)
            )
        }
        if previous.kind == .equation {
            return BlockSelection(
                blockID: previous.id,
                range: NSRange(location: previous.text.utf16.count, length: 0)
            )
        }

        let boundary = previous.text.utf16.count
        let merged = previous.merged(with: current)
        let updated = Array(blocks[..<(index - 1)]) + [merged] + Array(blocks[(index + 1)...])
        apply(updated)
        return BlockSelection(
            blockID: previous.id,
            range: NSRange(location: boundary, length: 0)
        )
    }

    @discardableResult
    mutating func insert(after id: UUID?, kind: EditorBlockKind = .paragraph) -> BlockSelection? {
        let index: Int
        if let id, let found = blocks.firstIndex(where: { $0.id == id }) {
            index = found + 1
        } else {
            index = max(blocks.count - 1, 0)
        }
        let inserted = EditorBlock(kind: kind, text: "")
        let updated = Array(blocks[..<index]) + [inserted] + Array(blocks[index...])
        apply(updated)
        return BlockSelection(blockID: inserted.id, range: NSRange(location: 0, length: 0))
    }

    @discardableResult
    mutating func duplicate(id: UUID) -> BlockSelection? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        let source = blocks[index]
        let copy = EditorBlock(
            kind: source.kind,
            text: source.text,
            inlineMarks: source.inlineMarks,
            indentLevel: source.indentLevel
        )
        let insertion = index + 1
        let updated = Array(blocks[..<insertion]) + [copy] + Array(blocks[insertion...])
        apply(updated)
        return BlockSelection(
            blockID: copy.id,
            range: NSRange(location: copy.text.utf16.count, length: 0)
        )
    }

    @discardableResult
    mutating func delete(id: UUID) -> BlockSelection? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = blocks.filter { $0.id != id }
        if updated.isEmpty { updated = [EditorBlock(text: "")] }
        apply(updated)

        let destination = min(index, blocks.count - 1)
        let target = blocks[destination]
        return BlockSelection(
            blockID: target.id,
            range: NSRange(location: target.text.utf16.count, length: 0)
        )
    }

    mutating func transform(id: UUID, to kind: EditorBlockKind) {
        guard let current = block(id: id), current.kind != kind else { return }
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return block.changingKind(to: kind)
        }
        apply(updated)
    }

    @discardableResult
    mutating func indent(id: UUID) -> Bool {
        changeIndent(id: id, delta: 1)
    }

    @discardableResult
    mutating func outdent(id: UUID) -> Bool {
        changeIndent(id: id, delta: -1)
    }

    @discardableResult
    mutating func moveUp(id: UUID) -> Bool {
        guard let index = contentIndex(id: id), index > 0 else { return false }
        return move(from: index, to: index - 1)
    }

    @discardableResult
    mutating func moveDown(id: UUID) -> Bool {
        guard let index = contentIndex(id: id), index < contentBlockCount - 1 else { return false }
        return move(from: index, to: index + 1)
    }

    @discardableResult
    mutating func move(id: UUID, toPositionOf targetID: UUID) -> Bool {
        guard let from = contentIndex(id: id), let target = contentIndex(id: targetID), from != target else {
            return false
        }
        return move(from: from, to: target)
    }

    mutating func replaceText(
        id: UUID,
        range: NSRange,
        with replacement: String
    ) -> BlockSelection? {
        guard let current = block(id: id),
              let edited = current.replacingText(in: range, with: replacement)
        else { return nil }
        let updated = blocks.map { block in
            block.id == id ? edited : block
        }
        apply(updated)
        return BlockSelection(
            blockID: id,
            range: NSRange(location: range.location + replacement.utf16.count, length: 0)
        )
    }

    mutating func applyInlineFormat(
        _ format: InlineFormat,
        id: UUID,
        range: NSRange
    ) -> BlockSelection? {
        guard let current = block(id: id),
              !current.kind.preservesLineBreaks,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= current.text.utf16.count,
              Range(range, in: current.text) != nil
        else {
            return nil
        }
        var marks = current.inlineMarks.filter { $0.format != format }
        let formatMarks = current.inlineMarks.filter { $0.format == format }
        if Self.covers(range, with: formatMarks.map(\.range)) {
            for mark in formatMarks {
                let leftLength = max(
                    min(range.location, NSMaxRange(mark.range)) - mark.range.location,
                    0
                )
                if leftLength > 0 {
                    marks.append(InlineMark(
                        format: format,
                        range: NSRange(location: mark.range.location, length: leftLength)
                    ))
                }
                let rightStart = max(NSMaxRange(range), mark.range.location)
                let rightLength = max(NSMaxRange(mark.range) - rightStart, 0)
                if rightLength > 0 {
                    marks.append(InlineMark(
                        format: format,
                        range: NSRange(location: rightStart, length: rightLength)
                    ))
                }
            }
        } else {
            marks.append(contentsOf: formatMarks)
            marks.append(InlineMark(format: format, range: range))
        }
        let edited = EditorBlock(
            id: current.id,
            kind: current.kind,
            text: current.text,
            inlineMarks: marks,
            indentLevel: current.indentLevel
        )
        apply(blocks.map { $0.id == id ? edited : $0 })
        return BlockSelection(
            blockID: id,
            range: range
        )
    }

    private static func covers(_ target: NSRange, with ranges: [NSRange]) -> Bool {
        var cursor = target.location
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if NSMaxRange(range) <= cursor { continue }
            if range.location > cursor { return false }
            cursor = max(cursor, NSMaxRange(range))
            if cursor >= NSMaxRange(target) { return true }
        }
        return false
    }

    mutating func applyShortcut(id: UUID, kind: EditorBlockKind, prefixUTF16Length: Int) -> BlockSelection? {
        guard let current = block(id: id),
              prefixUTF16Length >= 0,
              prefixUTF16Length <= current.text.utf16.count,
              Self.stringIndex(in: current.text, utf16Offset: prefixUTF16Length) != nil
        else { return nil }
        guard let withoutPrefix = current.replacingText(
            in: NSRange(location: 0, length: prefixUTF16Length),
            with: ""
        ) else { return nil }
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return withoutPrefix.changingKind(to: kind, indentLevel: 0)
        }
        apply(updated)
        return BlockSelection(blockID: id, range: NSRange(location: 0, length: 0))
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(HistoryEntry(blocks: blocks, documentSelection: currentDocumentSelection))
        blocks = previous.blocks
        setDocumentSelection(previous.documentSelection)
        return true
    }

    @discardableResult
    mutating func undo(currentSelection selection: BlockSelection?) -> Bool {
        updateSelection(selection)
        return undo()
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(HistoryEntry(blocks: blocks, documentSelection: currentDocumentSelection))
        Self.trimHistory(&undoStack)
        blocks = next.blocks
        setDocumentSelection(next.documentSelection)
        return true
    }

    @discardableResult
    mutating func redo(currentSelection selection: BlockSelection?) -> Bool {
        updateSelection(selection)
        return redo()
    }

    private var contentBlockCount: Int {
        blocks.last?.text.isEmpty == true && blocks.last?.kind == .paragraph
            ? max(blocks.count - 1, 0)
            : blocks.count
    }

    private func contentIndex(id: UUID) -> Int? {
        guard let index = blocks.firstIndex(where: { $0.id == id }), index < contentBlockCount else {
            return nil
        }
        return index
    }

    private mutating func changeIndent(id: UUID, delta: Int) -> Bool {
        guard let current = block(id: id), current.kind.supportsIndentation else { return false }
        let nextLevel = min(max(current.indentLevel + delta, 0), 3)
        guard nextLevel != current.indentLevel else { return false }
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return EditorBlock(
                id: block.id,
                kind: block.kind,
                text: block.text,
                inlineMarks: block.inlineMarks,
                indentLevel: nextLevel
            )
        }
        apply(updated)
        return true
    }

    private mutating func move(from: Int, to: Int) -> Bool {
        guard from != to, blocks.indices.contains(from), blocks.indices.contains(to) else { return false }
        var updated = blocks
        let item = updated.remove(at: from)
        updated.insert(item, at: to)
        apply(updated)
        return true
    }

    private mutating func apply(_ updated: [EditorBlock]) {
        let normalized = Self.normalized(updated)
        guard normalized != blocks else { return }
        undoStack.append(HistoryEntry(blocks: blocks, documentSelection: currentDocumentSelection))
        Self.trimHistory(&undoStack)
        redoStack.removeAll(keepingCapacity: true)
        blocks = normalized
    }

    private mutating func setDocumentSelection(_ selection: NSRange?) {
        currentDocumentSelection = Self.validated(selection, in: documentText)
        currentSelection = currentDocumentSelection.flatMap(blockSelection(for:))
    }

    private func documentBlockRanges() -> [DocumentBlockRange] {
        var location = 0
        return blocks.enumerated().map { index, block in
            let range = DocumentBlockRange(
                index: index,
                content: NSRange(location: location, length: block.text.utf16.count)
            )
            location += block.text.utf16.count
            if index < blocks.count - 1 { location += 1 }
            return range
        }
    }

    private func documentPosition(at offset: Int) -> (index: Int, offset: Int)? {
        guard offset >= 0, offset <= documentText.utf16.count else { return nil }
        let ranges = documentBlockRanges()
        for range in ranges where offset <= NSMaxRange(range.content) {
            return (range.index, offset - range.content.location)
        }
        guard let last = ranges.last else { return nil }
        return (last.index, last.content.length)
    }

    private static func trimHistory(_ history: inout [HistoryEntry]) {
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    private static func validated(
        _ selection: BlockSelection?,
        in blocks: [EditorBlock]
    ) -> BlockSelection? {
        guard let selection,
              let block = blocks.first(where: { $0.id == selection.blockID }),
              selection.range.location >= 0,
              selection.range.length >= 0,
              NSMaxRange(selection.range) <= block.text.utf16.count,
              Range(selection.range, in: block.text) != nil
        else { return nil }
        return selection
    }

    private static func validated(_ range: NSRange?, in text: String) -> NSRange? {
        guard let range,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= text.utf16.count,
              Range(range, in: text) != nil
        else { return nil }
        return range
    }

    private static func normalized(_ source: [EditorBlock]) -> [EditorBlock] {
        let expanded = source.flatMap { block -> [EditorBlock] in
            guard !block.kind.preservesLineBreaks, block.text.contains("\n") else { return [block] }
            var location = 0
            return block.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, text in
                    let kind = index == 0 ? block.kind : block.kind.continuationKind
                    let length = text.utf16.count
                    defer { location += length + 1 }
                    return block.subblock(
                        in: NSRange(location: location, length: length),
                        id: index == 0 ? block.id : UUID(),
                        kind: kind,
                        indentLevel: kind.supportsIndentation ? block.indentLevel : 0
                    )
                }
        }
        guard !expanded.isEmpty else { return [EditorBlock(text: "")] }
        guard expanded.last?.text.isEmpty != true || expanded.last?.kind != .paragraph else {
            return expanded
        }
        return expanded + [EditorBlock(text: "")]
    }

    private static func split(_ text: String, atUTF16Offset offset: Int) -> (left: String, right: String)? {
        guard let index = stringIndex(in: text, utf16Offset: offset) else { return nil }
        return (String(text[..<index]), String(text[index...]))
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(utf16Index, within: text)
    }

    private static func split(_ markdown: String) -> [String] {
        var result: [String] = []
        var current: [Substring] = []
        var inFence = false

        func flush() {
            if !current.isEmpty {
                result.append(current.joined(separator: "\n"))
                current = []
            }
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                current.append(line)
                if trimmed.hasPrefix("```") {
                    inFence = false
                    flush()
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flush()
                current = [line]
                inFence = true
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            if startsStandaloneBlock(line) {
                flush()
                current = [line]
                continue
            }

            if let first = current.first,
               startsStandaloneBlock(first),
               !(startsListItem(first) && line.first?.isWhitespace == true) {
                flush()
            }
            current.append(line)
        }
        flush()
        return result
    }

    private static func startsStandaloneBlock(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
            return true
        }
        if trimmed.hasPrefix("> ") || startsListItem(line) {
            return true
        }
        return trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]")
    }

    private static func startsListItem(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        return trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }
}
