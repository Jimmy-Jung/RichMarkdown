// Created by JunyoungJung on 2026-08-24.

import Foundation

/// Notion 스타일 블록의 종류.
///
/// 표시용 문자열(제목·아이콘)은 UI 레이어의 책임이므로 여기에 두지 않는다.
public enum EditorBlockKind: Codable, Equatable, Hashable, Sendable {
    case paragraph
    /// 제목. 파싱·직렬화는 1...3 레벨만 지원한다.
    case heading(level: Int)
    case bulletedList
    case numberedList
    case toDo(isChecked: Bool)
    case quote
    case code(language: String?)
    case equation

    /// Enter로 블록을 나눌 때 뒤쪽 블록이 이어받는 종류.
    public var continuationKind: EditorBlockKind {
        switch self {
        case .bulletedList, .numberedList, .toDo:
            self
        default:
            .paragraph
        }
    }

    public var supportsIndentation: Bool {
        true
    }

    public var supportsRenderedCaret: Bool {
        switch self {
        case .paragraph, .heading:
            true
        default:
            false
        }
    }

    /// 코드·수식은 블록 내부 개행을 보존한다. 그 외 개행은 블록 경계다.
    public var preservesLineBreaks: Bool {
        switch self {
        case .code, .equation:
            true
        default:
            false
        }
    }
}

/// 블록 하나의 값 타입.
///
/// `markdown:` 이니셜라이저가 한 블록 분량의 markdown을 파싱하고
/// `markdown(numberedListOrdinal:)`이 역직렬화한다. 파싱↔직렬화 왕복은 손실 없이
/// 보존되는 것이 계약이다.
public struct EditorBlock: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: EditorBlockKind
    public var text: String
    public var inlineMarks: [InlineMark]
    /// 들여쓰기 깊이. 0...3으로 clamp된다.
    public var indentLevel: Int

    public init(
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

    public init(markdown: String) {
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

    public var markdown: String {
        markdown(numberedListOrdinal: 1)
    }

    public func markdown(numberedListOrdinal: Int) -> String {
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

/// 블록 내부 UTF-16 range 기반 선택.
public struct BlockSelection: Equatable, Sendable {
    public let blockID: UUID
    public let range: NSRange

    public init(blockID: UUID, range: NSRange) {
        self.blockID = blockID
        self.range = range
    }
}

public enum InlineFormat: Int, CaseIterable, Codable, Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    case code

    /// 직렬화 시 사용하는 정식 구분자. italic은 `<em>`이 정식이며
    /// `*`·`_`는 파싱만 지원한다.
    var delimiters: (opening: String, closing: String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("<em>", "</em>")
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        }
    }
}

/// 인라인 서식 하나. `range`는 UTF-16 offset이다.
public struct InlineMark: Codable, Equatable, Sendable {
    public let format: InlineFormat
    public var range: NSRange

    public init(format: InlineFormat, range: NSRange) {
        self.format = format
        self.range = range
    }
}

/// 인라인 markdown(`**`, `*`, `~~`, `` ` ``)을 텍스트 + `[InlineMark]`로 분리하는 코덱.
///
/// LaTeX-aware: `\(...\)`, `$...$`, `$$...$$` 구간 안의 `*`, `_`는 서식 구분자로
/// 해석하지 않는다. 코드 마크와 겹치는 다른 서식은 정규화 단계에서 무효화된다.
public enum InlineMarkdownCodec {
    private struct ParseResult {
        var text = ""
        var marks: [InlineMark] = []
        var closed = false
    }

    public static func parse(_ source: String) -> (text: String, marks: [InlineMark]) {
        var index = source.startIndex
        let result = parse(source, index: &index, closing: nil)
        return (result.text, normalized(result.marks, text: result.text))
    }

    public static func serialize(text: String, marks: [InlineMark]) -> String {
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

    public static func normalized(_ marks: [InlineMark], text: String) -> [InlineMark] {
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

extension EditorBlock {
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
