// Created by JunyoungJung on 2026-08-24.

import Foundation

/// Notion 스타일 블록 문서의 순수 로직 엔진.
///
/// 블록↔문서 UTF-16 좌표 변환, split/merge/indent/종류 변환, 인라인 서식 토글,
/// undo/redo(상한 100)를 제공한다. UI 의존이 없어 markdown 구조 조작
/// 파이프라인에도 단독으로 쓸 수 있다.
public struct BlockEditorModel: Sendable {
    private struct HistoryEntry {
        let blocks: [EditorBlock]
        let documentSelection: NSRange?
    }

    private struct DocumentBlockRange {
        let index: Int
        let content: NSRange
    }

    private static let historyLimit = 100
    public private(set) var blocks: [EditorBlock]
    public private(set) var currentSelection: BlockSelection? = nil
    public private(set) var currentDocumentSelection: NSRange? = nil
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    public init(markdown: String) {
        blocks = Self.normalized(Self.split(markdown).map(EditorBlock.init(markdown:)))
    }

    public init(blocks: [EditorBlock]) {
        self.blocks = Self.normalized(blocks)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var documentText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    public var markdown: String {
        var numberedCounts: [Int: Int] = [:]
        var previousKinds: [Int: EditorBlockKind] = [:]
        return blocks.map { block in
            let depth = block.indentLevel
            numberedCounts = numberedCounts.filter { $0.key <= depth }
            previousKinds = previousKinds.filter { $0.key <= depth }
            let ordinal: Int
            if block.kind == .numberedList {
                ordinal = previousKinds[depth] == .numberedList
                    ? (numberedCounts[depth] ?? 0) + 1
                    : 1
                numberedCounts[depth] = ordinal
            } else {
                ordinal = 1
                numberedCounts[depth] = 0
            }
            previousKinds[depth] = block.kind
            return block.markdown(numberedListOrdinal: ordinal)
        }.joined(separator: "\n")
    }

    public func block(id: UUID) -> EditorBlock? {
        blocks.first { $0.id == id }
    }

    public mutating func updateSelection(_ selection: BlockSelection?) {
        let validated = Self.validated(selection, in: blocks)
        currentSelection = validated
        currentDocumentSelection = validated.flatMap(documentRange(for:))
    }

    public mutating func updateDocumentSelection(_ selection: NSRange?) {
        guard let selection else {
            currentSelection = nil
            currentDocumentSelection = nil
            return
        }
        guard Self.validated(selection, in: documentText) != nil else { return }
        currentDocumentSelection = selection
        currentSelection = blockSelection(for: selection)
    }

    public func documentRange(for blockID: UUID) -> NSRange? {
        documentBlockRanges().first { blocks[$0.index].id == blockID }?.content
    }

    public func documentRange(for selection: BlockSelection) -> NSRange? {
        guard let blockRange = documentRange(for: selection.blockID),
              NSMaxRange(selection.range) <= blockRange.length
        else { return nil }
        return NSRange(
            location: blockRange.location + selection.range.location,
            length: selection.range.length
        )
    }

    public func blockSelection(for documentSelection: NSRange) -> BlockSelection? {
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

    public func numberedListOrdinal(for id: UUID) -> Int? {
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

    public mutating func updateText(id: UUID, text: String) {
        updateText(id: id, text: text, selection: currentSelection)
    }

    public mutating func updateText(id: UUID, text: String, selection: BlockSelection?) {
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
    public mutating func replaceDocumentText(
        in range: NSRange,
        with replacement: String
    ) -> NSRange? {
        guard Self.validated(range, in: documentText) != nil else { return nil }
        let nextSelection = NSRange(
            location: range.location + replacement.utf16.count,
            length: 0
        )

        if range.location == 0, range.length == documentText.utf16.count {
            let plainTextBlocks = replacement
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { EditorBlock(text: String($0)) }
            return replaceDocumentBlocks(in: range, with: plainTextBlocks)
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

    /// 앱 전용 pasteboard 표현으로 전달된 논리 블록 전체를 손실 없이 복원한다.
    @discardableResult
    public mutating func replaceDocumentBlocks(
        in range: NSRange,
        with replacement: [EditorBlock]
    ) -> NSRange? {
        guard range == NSRange(location: 0, length: documentText.utf16.count) else {
            return nil
        }
        apply(Self.normalized(replacement))
        let trailingEmptyBlockLength = blocks.count > 1 && blocks.last?.text.isEmpty == true ? 1 : 0
        updateDocumentSelection(NSRange(
            location: max(0, documentText.utf16.count - trailingEmptyBlockLength),
            length: 0
        ))
        return currentDocumentSelection
    }

    public mutating func splitBlock(id: UUID, atUTF16Offset offset: Int) -> BlockSelection? {
        splitBlock(id: id, replacing: NSRange(location: offset, length: 0))
    }

    public mutating func splitBlock(id: UUID, replacing range: NSRange) -> BlockSelection? {
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

    public mutating func insertSoftBreak(id: UUID, atUTF16Offset offset: Int) -> BlockSelection? {
        insertSoftBreak(id: id, replacing: NSRange(location: offset, length: 0))
    }

    public mutating func insertSoftBreak(id: UUID, replacing range: NSRange) -> BlockSelection? {
        guard let block = block(id: id) else { return nil }
        return block.kind.preservesLineBreaks
            ? replaceText(id: id, range: range, with: "\n")
            : splitBlock(id: id, replacing: range)
    }

    public mutating func backspaceAtStart(of id: UUID) -> BlockSelection? {
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
    public mutating func insert(after id: UUID?, kind: EditorBlockKind = .paragraph) -> BlockSelection? {
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
    public mutating func duplicate(id: UUID) -> BlockSelection? {
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
    public mutating func delete(id: UUID) -> BlockSelection? {
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

    public mutating func transform(id: UUID, to kind: EditorBlockKind) {
        guard let current = block(id: id), current.kind != kind else { return }
        let updated = blocks.map { block in
            guard block.id == id else { return block }
            return block.changingKind(to: kind)
        }
        apply(updated)
    }

    @discardableResult
    public mutating func indent(id: UUID) -> Bool {
        changeIndent(id: id, delta: 1)
    }

    @discardableResult
    public mutating func outdent(id: UUID) -> Bool {
        changeIndent(id: id, delta: -1)
    }

    @discardableResult
    public mutating func moveUp(id: UUID) -> Bool {
        guard let index = contentIndex(id: id), index > 0 else { return false }
        return move(from: index, to: index - 1)
    }

    @discardableResult
    public mutating func moveDown(id: UUID) -> Bool {
        guard let index = contentIndex(id: id), index < contentBlockCount - 1 else { return false }
        return move(from: index, to: index + 1)
    }

    @discardableResult
    public mutating func move(id: UUID, toPositionOf targetID: UUID) -> Bool {
        guard let from = contentIndex(id: id), let target = contentIndex(id: targetID), from != target else {
            return false
        }
        return move(from: from, to: target)
    }

    public mutating func replaceText(
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

    public mutating func applyInlineFormat(
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

    public mutating func applyShortcut(
        id: UUID,
        kind: EditorBlockKind,
        prefixUTF16Length: Int
    ) -> BlockSelection? {
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
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(HistoryEntry(blocks: blocks, documentSelection: currentDocumentSelection))
        blocks = previous.blocks
        setDocumentSelection(previous.documentSelection)
        return true
    }

    @discardableResult
    public mutating func undo(currentSelection selection: BlockSelection?) -> Bool {
        updateSelection(selection)
        return undo()
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(HistoryEntry(blocks: blocks, documentSelection: currentDocumentSelection))
        Self.trimHistory(&undoStack)
        blocks = next.blocks
        setDocumentSelection(next.documentSelection)
        return true
    }

    @discardableResult
    public mutating func redo(currentSelection selection: BlockSelection?) -> Bool {
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
