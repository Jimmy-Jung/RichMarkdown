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
    var indentLevel: Int

    init(
        id: UUID = UUID(),
        kind: EditorBlockKind = .paragraph,
        text: String,
        indentLevel: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
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
            return
        }

        if source.hasPrefix("\\["), source.hasSuffix("\\]"), source.count >= 4 {
            kind = .equation
            text = String(source.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        let markerCount = source.prefix { $0 == "#" }.count
        if (1...3).contains(markerCount), source.dropFirst(markerCount).hasPrefix(" ") {
            kind = .heading(level: markerCount)
            text = String(source.dropFirst(markerCount + 1))
            return
        }

        if source.hasPrefix("- [ ] ") || source.hasPrefix("- [x] ") {
            kind = .toDo(isChecked: source.hasPrefix("- [x] "))
            text = String(source.dropFirst(6))
            return
        }
        if source.hasPrefix("- ") || source.hasPrefix("* ") || source.hasPrefix("+ ") {
            kind = .bulletedList
            text = String(source.dropFirst(2))
            return
        }
        if let match = source.range(of: #"^\d+\. "#, options: .regularExpression) {
            kind = .numberedList
            text = String(source[match.upperBound...])
            return
        }
        if source.hasPrefix("> ") {
            kind = .quote
            text = String(source.dropFirst(2))
            return
        }

        kind = .paragraph
        text = source
    }

    var markdown: String {
        markdown(numberedListOrdinal: 1)
    }

    func markdown(numberedListOrdinal: Int) -> String {
        let indent = String(repeating: "  ", count: indentLevel)
        return switch kind {
        case .paragraph:
            text
        case let .heading(level):
            String(repeating: "#", count: min(max(level, 1), 3)) + " " + text
        case .bulletedList:
            indent + "- " + text
        case .numberedList:
            indent + "\(max(numberedListOrdinal, 1)). " + text
        case let .toDo(isChecked):
            indent + (isChecked ? "- [x] " : "- [ ] ") + text
        case .quote:
            "> " + text
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

enum InlineFormat {
    case bold
    case italic
    case strikethrough
    case code

    fileprivate var delimiters: (opening: String, closing: String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("*", "*")
        case .strikethrough: ("~~", "~~")
        case .code: ("`", "`")
        }
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
            return EditorBlock(
                id: block.id,
                kind: block.kind,
                text: text,
                indentLevel: block.indentLevel
            )
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
            guard let sourceRange = Range(
                NSRange(location: start.offset, length: end.offset - start.offset),
                in: startBlock.text
            ) else { return nil }
            let text = startBlock.text.replacingCharacters(in: sourceRange, with: replacement)
            let updated = blocks.enumerated().map { index, block in
                guard index == start.index else { return block }
                return EditorBlock(
                    id: block.id,
                    kind: block.kind,
                    text: text,
                    indentLevel: block.indentLevel
                )
            }
            apply(updated)
            updateDocumentSelection(nextSelection)
            return currentDocumentSelection
        }

        guard let prefixEnd = Self.stringIndex(in: startBlock.text, utf16Offset: start.offset),
              let suffixStart = Self.stringIndex(in: endBlock.text, utf16Offset: end.offset)
        else { return nil }
        let prefix = String(startBlock.text[..<prefixEnd])
        let suffix = String(endBlock.text[suffixStart...])
        let parts = replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let replacementBlocks: [EditorBlock]
        if parts.count == 1 {
            replacementBlocks = [EditorBlock(
                id: startBlock.id,
                kind: startBlock.kind,
                text: prefix + parts[0] + suffix,
                indentLevel: startBlock.indentLevel
            )]
        } else {
            let continuationKind = startBlock.kind.continuationKind
            var splitBlocks = [EditorBlock(
                id: startBlock.id,
                kind: startBlock.kind,
                text: prefix + parts[0],
                indentLevel: startBlock.indentLevel
            )]
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
                text: parts[parts.count - 1] + suffix,
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
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= blocks[index].text.utf16.count,
              let sourceRange = Range(range, in: blocks[index].text)
        else { return nil }

        let current = blocks[index]
        let text = current.text.replacingCharacters(in: sourceRange, with: "")
        guard let parts = Self.split(text, atUTF16Offset: range.location) else { return nil }
        if text.isEmpty, current.kind.supportsIndentation {
            transform(id: id, to: .paragraph)
            return BlockSelection(blockID: id, range: NSRange(location: 0, length: 0))
        }

        let left = EditorBlock(
            id: current.id,
            kind: current.kind,
            text: parts.left,
            indentLevel: current.indentLevel
        )
        let right = EditorBlock(
            kind: current.kind.continuationKind,
            text: parts.right,
            indentLevel: current.kind.supportsIndentation ? current.indentLevel : 0
        )
        let updated = Array(blocks[..<index]) + [left, right] + Array(blocks[(index + 1)...])
        apply(updated)
        return BlockSelection(blockID: right.id, range: NSRange(location: 0, length: 0))
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
        let merged = EditorBlock(
            id: previous.id,
            kind: previous.kind,
            text: previous.text + current.text,
            indentLevel: previous.indentLevel
        )
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
        let copy = EditorBlock(kind: source.kind, text: source.text, indentLevel: source.indentLevel)
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
            return EditorBlock(
                id: block.id,
                kind: kind,
                text: block.text,
                indentLevel: kind.supportsIndentation ? block.indentLevel : 0
            )
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
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= current.text.utf16.count,
              let sourceRange = Range(range, in: current.text)
        else { return nil }

        let updatedText = current.text.replacingCharacters(in: sourceRange, with: replacement)
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return EditorBlock(
                id: block.id,
                kind: block.kind,
                text: updatedText,
                indentLevel: block.indentLevel
            )
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
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= current.text.utf16.count,
              let sourceRange = Range(range, in: current.text)
        else {
            return nil
        }
        let delimiters = format.delimiters
        let selected = String(current.text[sourceRange])
        let replacement = delimiters.opening + selected + delimiters.closing
        guard replaceText(id: id, range: range, with: replacement) != nil else { return nil }
        let location = range.location + delimiters.opening.utf16.count
        return BlockSelection(
            blockID: id,
            range: NSRange(location: location, length: selected.utf16.count)
        )
    }

    mutating func applyShortcut(id: UUID, kind: EditorBlockKind, prefixUTF16Length: Int) -> BlockSelection? {
        guard let current = block(id: id),
              prefixUTF16Length >= 0,
              prefixUTF16Length <= current.text.utf16.count,
              let contentStart = Self.stringIndex(in: current.text, utf16Offset: prefixUTF16Length)
        else { return nil }
        let updatedText = String(current.text[contentStart...])
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return EditorBlock(id: block.id, kind: kind, text: updatedText, indentLevel: 0)
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
            return block.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { index, text in
                    let kind = index == 0 ? block.kind : block.kind.continuationKind
                    return EditorBlock(
                        id: index == 0 ? block.id : UUID(),
                        kind: kind,
                        text: String(text),
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
