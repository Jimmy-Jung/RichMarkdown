// Created by JunyoungJung on 2026-08-24.

import SwiftLatex
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 키보드 액세서리(또는 자체 툴바)가 에디터에 전달하는 편집 명령.
public enum EditorToolbarAction {
    case insert(EditorBlockKind)
    case transform(EditorBlockKind)
    case format(InlineFormat)
    case indent
    case outdent
    case undo
    case redo
    case duplicate
    case delete
    case moveUp
    case moveDown
    case done
}

/// `BlockDocumentTextEditor`에 주입하는 키보드 액세서리 뷰의 계약.
///
/// 에디터가 선택 블록·undo 가능 여부가 바뀔 때마다 `update`를 호출한다.
/// 구체 툴바 UI는 앱의 책임이다 — package는 주입점만 연다.
@MainActor
public protocol BlockEditorInputAccessory: UIView {
    func update(kind: EditorBlockKind, canUndo: Bool, canRedo: Bool)
}

public final class BlockDocumentUITextView: UITextView {
    public static let blockDocumentPasteboardType = "com.swiftlatex.block-document"

    public var fullDocumentMarkdown: String?
    public var fullDocumentBlocks: [EditorBlock] = []
    public var onPasteDocumentBlocks: ((NSRange, [EditorBlock]) -> Bool)?
    private let ownedContentStorage: NSTextContentStorage
    public private(set) var inlineCodeDecoration: InlineCodeDecorationView?
    public private(set) var quoteBarDecoration: QuoteBarDecorationView?
    public private(set) var toDoCheckboxDecoration: ToDoCheckboxDecorationView?

    public init() {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
        ownedContentStorage = contentStorage
        super.init(frame: .zero, textContainer: textContainer)
        inlineCodeDecoration = InlineCodeDecorationView.install(on: self)
        quoteBarDecoration = QuoteBarDecorationView.install(on: self)
        toDoCheckboxDecoration = ToDoCheckboxDecorationView.install(on: self)
    }

    override public var attributedText: NSAttributedString! {
        get { super.attributedText }
        set {
            super.attributedText = newValue
            inlineCodeDecoration?.invalidate()
            quoteBarDecoration?.invalidate()
            toDoCheckboxDecoration?.invalidate()
        }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        inlineCodeDecoration?.refresh()
        quoteBarDecoration?.refresh()
        toDoCheckboxDecoration?.refresh()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("BlockDocumentUITextView는 코드로만 생성합니다")
    }

    override public func copy(_ sender: Any?) {
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        guard selectedRange == fullRange, let fullDocumentMarkdown else {
            super.copy(sender)
            return
        }
        var item: [String: Any] = [
            UTType.utf8PlainText.identifier: fullDocumentMarkdown,
        ]
        if let data = BlockDocumentPasteboardPayload.encode(fullDocumentBlocks) {
            item[Self.blockDocumentPasteboardType] = data
        }
        UIPasteboard.general.setItems([item])
    }

    override public func paste(_ sender: Any?) {
        guard
            let data = UIPasteboard.general.data(
                forPasteboardType: Self.blockDocumentPasteboardType
            ),
            let blocks = BlockDocumentPasteboardPayload.decode(data),
            onPasteDocumentBlocks?(selectedRange, blocks) == true
        else {
            super.paste(sender)
            return
        }
    }
}

/// 블록 구조를 손실 없이 복사·붙여넣기하기 위한 pasteboard 표현 (JSON, 버전 필드 포함).
///
/// `decode`는 heading level과 indent를 clamp해 조작된 payload를 방어한다.
public struct BlockDocumentPasteboardPayload: Codable {
    private static let maximumBytes = 256 * 1_024
    private let version: Int
    private let blocks: [Block]

    private struct Block: Codable {
        let kind: EditorBlockKind
        let text: String
        let inlineMarks: [InlineMark]
        let indentLevel: Int

        init(_ block: EditorBlock) {
            kind = block.kind
            text = block.text
            inlineMarks = block.inlineMarks
            indentLevel = block.indentLevel
        }

        var editorBlock: EditorBlock {
            let safeKind: EditorBlockKind = switch kind {
            case let .heading(level): .heading(level: min(max(level, 1), 3))
            default: kind
            }
            return EditorBlock(
                kind: safeKind,
                text: text,
                inlineMarks: inlineMarks,
                indentLevel: safeKind.supportsIndentation ? min(max(indentLevel, 0), 3) : 0
            )
        }
    }

    public static func encode(_ blocks: [EditorBlock]) -> Data? {
        guard !blocks.isEmpty else { return nil }
        let payload = Self(version: 1, blocks: blocks.map(Block.init))
        guard let data = try? JSONEncoder().encode(payload), data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    public static func decode(_ data: Data) -> [EditorBlock]? {
        guard data.count <= maximumBytes,
              let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.version == 1,
              !payload.blocks.isEmpty
        else { return nil }
        return payload.blocks.map(\.editorBlock)
    }
}

/// 논리 블록 전체를 TextKit 2 문서 하나로 투영한다.
/// UIKit의 기본 선택기가 블록 경계와 무관하게 선택·복사·전체 선택을 처리한다.
public struct BlockDocumentTextEditor: UIViewRepresentable {
    @Environment(\.sizeCategory) private var sizeCategory

    let blocks: [EditorBlock]
    let selection: NSRange?
    let canUndo: Bool
    let canRedo: Bool
    let onReplaceText: (NSRange, String) -> NSRange?
    let onSelectionChange: (NSRange) -> Void
    let onToolbarAction: (EditorToolbarAction, NSRange) -> Void
    var onReplaceDocumentBlocks: ((NSRange, [EditorBlock]) -> NSRange?)? = nil
    var parsesDollarMath = false
    var theme: LatexTheme = .default
    var blockAlignment: BlockAlignmentConfiguration = .default
    var sourceMarkdown: String? = nil
    var makeInputAccessory: ((@escaping (EditorToolbarAction) -> Void) -> (any BlockEditorInputAccessory)?)? = nil

    public init(
        blocks: [EditorBlock],
        selection: NSRange?,
        canUndo: Bool,
        canRedo: Bool,
        onReplaceText: @escaping (NSRange, String) -> NSRange?,
        onSelectionChange: @escaping (NSRange) -> Void,
        onToolbarAction: @escaping (EditorToolbarAction, NSRange) -> Void,
        onReplaceDocumentBlocks: ((NSRange, [EditorBlock]) -> NSRange?)? = nil,
        parsesDollarMath: Bool = false,
        theme: LatexTheme = .default,
        blockAlignment: BlockAlignmentConfiguration = .default,
        sourceMarkdown: String? = nil,
        makeInputAccessory: ((@escaping (EditorToolbarAction) -> Void) -> (any BlockEditorInputAccessory)?)? = nil
    ) {
        self.blocks = blocks
        self.selection = selection
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.onReplaceText = onReplaceText
        self.onSelectionChange = onSelectionChange
        self.onToolbarAction = onToolbarAction
        self.onReplaceDocumentBlocks = onReplaceDocumentBlocks
        self.parsesDollarMath = parsesDollarMath
        self.theme = theme
        self.blockAlignment = blockAlignment
        self.sourceMarkdown = sourceMarkdown
        self.makeInputAccessory = makeInputAccessory
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> BlockDocumentUITextView {
        let view = BlockDocumentUITextView()
        view.backgroundColor = .clear
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 96, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "blockDocumentTextView"
        view.accessibilityLabel = "문서 편집기"
        view.fullDocumentMarkdown = sourceMarkdown
        view.fullDocumentBlocks = blocks
        let editingEquationIDs = selection.map {
            Self.equationBlockIDs(in: blocks, selection: $0)
        } ?? []
        let editingInlineMathRanges = selection.map {
            MarkdownStyler.inlineMathRanges(
                in: blocks,
                intersecting: $0,
                parsesDollarMath: parsesDollarMath
            )
        } ?? []
        view.attributedText = MarkdownStyler.styledDocument(
            blocks,
            editingEquationIDs: editingEquationIDs,
            parsesDollarMath: parsesDollarMath,
            theme: theme,
            alignment: blockAlignment,
            selection: selection,
            traitCollection: view.traitCollection
        )
        if let selection {
            view.selectedRange = Self.clamped(selection, length: view.text.utf16.count)
        }

        let coordinator = context.coordinator
        view.onPasteDocumentBlocks = { [weak coordinator] range, blocks in
            coordinator?.replaceDocumentBlocks(in: range, with: blocks) != nil
        }
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = view.text
        coordinator.lastBlocks = blocks
        coordinator.lastEditingEquationIDs = editingEquationIDs
        coordinator.lastEditingInlineMathRanges = editingInlineMathRanges
        coordinator.lastParsesDollarMath = parsesDollarMath
        coordinator.lastTheme = theme
        coordinator.lastBlockAlignment = blockAlignment
        coordinator.lastContentSizeCategory = sizeCategory
        let block = activeBlock
        let kind = block?.kind ?? .paragraph
        let accessory = makeInputAccessory?(coordinator.handleToolbarAction)
        accessory?.update(kind: kind, canUndo: canUndo, canRedo: canRedo)
        coordinator.accessory = accessory
        view.inputAccessoryView = accessory
        coordinator.applyTypingAttributes(
            MarkdownStyler.typingAttributes(
                for: block,
                theme: theme,
                alignment: blockAlignment,
                traitCollection: view.traitCollection
            ),
            to: view
        )
        return view
    }

    public func updateUIView(_ view: BlockDocumentUITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.fullDocumentMarkdown = sourceMarkdown
        view.fullDocumentBlocks = blocks
        let nextSelection = Self.clamped(
            selection ?? view.selectedRange,
            length: blocks.map(\.text).joined(separator: "\n").utf16.count
        )
        let editingEquationIDs = selection.map { _ in
            Self.equationBlockIDs(in: blocks, selection: nextSelection)
        } ?? coordinator.lastEditingEquationIDs
        let editingInlineMathRanges = selection.map { _ in
            MarkdownStyler.inlineMathRanges(
                in: blocks,
                intersecting: nextSelection,
                parsesDollarMath: parsesDollarMath
            )
        } ?? coordinator.lastEditingInlineMathRanges
        let block = activeBlock
        let kind = block?.kind ?? .paragraph
        coordinator.accessory?.update(kind: kind, canUndo: canUndo, canRedo: canRedo)

        guard view.markedTextRange == nil else { return }
        if coordinator.lastBlocks != blocks
            || coordinator.lastEditingEquationIDs != editingEquationIDs
            || coordinator.lastEditingInlineMathRanges != editingInlineMathRanges
            || coordinator.lastParsesDollarMath != parsesDollarMath
            || coordinator.lastTheme != theme
            || coordinator.lastBlockAlignment != blockAlignment
            || coordinator.lastContentSizeCategory != sizeCategory
        {
            coordinator.applyDocumentStyle(to: view, selection: nextSelection)
        }
        if view.selectedRange != nextSelection {
            coordinator.applySelection(nextSelection, to: view)
        }
        coordinator.applyTypingAttributes(
            MarkdownStyler.typingAttributes(
                for: block,
                theme: theme,
                alignment: blockAlignment,
                traitCollection: view.traitCollection
            ),
            to: view
        )
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockDocumentTextEditor
        weak var editingView: UITextView? {
            didSet {
                if let editingView {
                    lastCommittedSelection = editingView.selectedRange
                }
            }
        }
        weak var accessory: (any BlockEditorInputAccessory)?
        var isApplyingUpdate = false
        var baselineText = ""
        var lastBlocks: [EditorBlock] = []
        var lastEditingEquationIDs: Set<UUID> = []
        var lastEditingInlineMathRanges: [NSRange] = []
        var lastParsesDollarMath = false
        var lastTheme: LatexTheme = .default
        var lastBlockAlignment: BlockAlignmentConfiguration = .default
        var lastContentSizeCategory: ContentSizeCategory?
        private var pendingTextChange: (range: NSRange, replacement: String)?
        private var compositionRange: NSRange?
        private var lastCommittedSelection = NSRange(location: 0, length: 0)

        init(_ parent: BlockDocumentTextEditor) {
            self.parent = parent
        }

        public func textViewDidChange(_ view: UITextView) {
            reconcileTextChange(in: view)
        }

        public func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard !isApplyingUpdate else { return true }
            pendingTextChange = (range, text)
            return true
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingUpdate, textView.markedTextRange == nil else { return }
            reconcileTextChange(in: textView)
            let editingEquationIDs = BlockDocumentTextEditor.equationBlockIDs(
                in: parent.blocks,
                selection: textView.selectedRange
            )
            let editingInlineMathRanges = MarkdownStyler.inlineMathRanges(
                in: parent.blocks,
                intersecting: textView.selectedRange,
                parsesDollarMath: parent.parsesDollarMath
            )
            if editingEquationIDs != lastEditingEquationIDs
                || editingInlineMathRanges != lastEditingInlineMathRanges
            {
                applyDocumentStyle(to: textView, selection: textView.selectedRange)
            }
            lastCommittedSelection = textView.selectedRange
            parent.onSelectionChange(textView.selectedRange)
        }

        func handleToolbarAction(_ action: EditorToolbarAction) {
            guard editingView?.markedTextRange == nil else {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "한글 입력을 완료한 후 편집 도구를 사용하세요"
                )
                return
            }
            let range = editingView?.selectedRange
                ?? parent.selection
                ?? NSRange(location: 0, length: 0)
            if case .done = action { editingView?.resignFirstResponder() }
            parent.onToolbarAction(action, range)
        }

        func replaceDocumentBlocks(
            in range: NSRange,
            with blocks: [EditorBlock]
        ) -> NSRange? {
            guard !isApplyingUpdate, editingView?.markedTextRange == nil else { return nil }
            pendingTextChange = nil
            compositionRange = nil
            return parent.onReplaceDocumentBlocks?(range, blocks)
        }

        func applyDocumentStyle(to view: UITextView, selection: NSRange? = nil) {
            let requestedSelection = selection ?? view.selectedRange
            let editingEquationIDs = BlockDocumentTextEditor.equationBlockIDs(
                in: parent.blocks,
                selection: requestedSelection
            )
            let editingInlineMathRanges = MarkdownStyler.inlineMathRanges(
                in: parent.blocks,
                intersecting: requestedSelection,
                parsesDollarMath: parent.parsesDollarMath
            )
            let selection = BlockDocumentTextEditor.sourceAlignedSelection(
                requestedSelection,
                in: parent.blocks,
                editingEquationIDs: editingEquationIDs,
                editingInlineMathRanges: editingInlineMathRanges
            )
            let styled = MarkdownStyler.styledDocument(
                parent.blocks,
                editingEquationIDs: editingEquationIDs,
                parsesDollarMath: parent.parsesDollarMath,
                theme: parent.theme,
                alignment: parent.blockAlignment,
                selection: selection,
                traitCollection: view.traitCollection
            )
            isApplyingUpdate = true
            if view.text == styled.string {
                Self.applyAttributes(from: styled, to: view.textStorage)
                // textStorage 직접 재작성은 attributedText setter를 거치지 않아
                // 밑판(칩·인용 바)에 변경을 직접 알린다 (attribute-only 변경).
                (view as? BlockDocumentUITextView)?.inlineCodeDecoration?.invalidate()
                (view as? BlockDocumentUITextView)?.quoteBarDecoration?.invalidate()
                (view as? BlockDocumentUITextView)?.toDoCheckboxDecoration?.invalidate()
            } else {
                view.attributedText = styled
            }
            view.selectedRange = BlockDocumentTextEditor.clamped(
                selection,
                length: styled.string.utf16.count
            )
            lastCommittedSelection = view.selectedRange
            baselineText = styled.string
            lastBlocks = parent.blocks
            lastEditingEquationIDs = editingEquationIDs
            lastEditingInlineMathRanges = editingInlineMathRanges
            lastParsesDollarMath = parent.parsesDollarMath
            lastTheme = parent.theme
            lastBlockAlignment = parent.blockAlignment
            lastContentSizeCategory = parent.sizeCategory
            isApplyingUpdate = false
        }

        private static func applyAttributes(
            from source: NSAttributedString,
            to storage: NSTextStorage
        ) {
            guard source.length > 0 else { return }
            let fullRange = NSRange(location: 0, length: source.length)
            storage.beginEditing()
            storage.setAttributes([:], range: fullRange)
            source.enumerateAttributes(in: fullRange) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        }

        func applySelection(_ selection: NSRange, to view: UITextView) {
            isApplyingUpdate = true
            view.selectedRange = selection
            lastCommittedSelection = view.selectedRange
            isApplyingUpdate = false
        }

        func applyTypingAttributes(
            _ attributes: [NSAttributedString.Key: Any],
            to view: UITextView
        ) {
            let selection = view.selectedRange
            isApplyingUpdate = true
            view.typingAttributes = attributes
            if view.selectedRange != selection { view.selectedRange = selection }
            isApplyingUpdate = false
        }

        private func reconcileTextChange(in view: UITextView) {
            guard !isApplyingUpdate else { return }
            guard view.markedTextRange == nil else {
                if compositionRange == nil {
                    compositionRange = pendingTextChange?.range ?? lastCommittedSelection
                }
                pendingTextChange = nil
                return
            }
            guard view.text != baselineText else {
                pendingTextChange = nil
                compositionRange = nil
                return
            }
            let change = compositionRange.flatMap {
                Self.replacement(from: baselineText, to: view.text, at: $0)
            } ?? pendingTextChange ?? Self.singleReplacement(from: baselineText, to: view.text)
            pendingTextChange = nil
            compositionRange = nil
            guard let change else { return }
            baselineText = view.text
            if let selection = parent.onReplaceText(change.range, change.replacement) {
                applySelection(
                    BlockDocumentTextEditor.clamped(
                        selection,
                        length: view.text.utf16.count
                    ),
                    to: view
                )
            }
        }

        private static func replacement(
            from old: String,
            to new: String,
            at range: NSRange
        ) -> (range: NSRange, replacement: String)? {
            let oldText = old as NSString
            let newText = new as NSString
            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= oldText.length
            else { return nil }

            let replacementLength = newText.length - (oldText.length - range.length)
            guard replacementLength >= 0 else { return nil }
            let newRange = NSRange(location: range.location, length: replacementLength)
            guard
                  NSMaxRange(newRange) <= newText.length,
                  oldText.substring(to: range.location) == newText.substring(to: newRange.location),
                  oldText.substring(from: NSMaxRange(range))
                    == newText.substring(from: NSMaxRange(newRange))
            else { return nil }
            return (range, newText.substring(with: newRange))
        }

        /// ponytail: delegate range가 없는 외부 변경만 문서 전체를 O(n) 비교한다.
        /// 대용량 문서가 실제 병목일 때 변경 이벤트의 source를 추가로 제한한다.
        private static func singleReplacement(
            from old: String,
            to new: String
        ) -> (range: NSRange, replacement: String)? {
            let oldCharacters = Array(old)
            let newCharacters = Array(new)
            var prefixCount = 0
            while prefixCount < min(oldCharacters.count, newCharacters.count),
                  oldCharacters[prefixCount] == newCharacters[prefixCount] {
                prefixCount += 1
            }

            var suffixCount = 0
            while suffixCount < oldCharacters.count - prefixCount,
                  suffixCount < newCharacters.count - prefixCount,
                  oldCharacters[oldCharacters.count - suffixCount - 1]
                    == newCharacters[newCharacters.count - suffixCount - 1] {
                suffixCount += 1
            }

            let oldPrefix = String(oldCharacters[..<prefixCount])
            let oldChanged = oldCharacters.count - prefixCount - suffixCount
            let newEnd = newCharacters.count - suffixCount
            let replacement = String(newCharacters[prefixCount..<newEnd])
            return (
                NSRange(
                    location: oldPrefix.utf16.count,
                    length: String(oldCharacters[prefixCount..<(prefixCount + oldChanged)]).utf16.count
                ),
                replacement
            )
        }
    }

    private var activeBlock: EditorBlock? {
        guard let selection,
              let block = block(at: selection.location)
        else { return blocks.first }
        return block
    }

    private func block(at offset: Int) -> EditorBlock? {
        var location = 0
        for (index, block) in blocks.enumerated() {
            if offset <= location + block.text.utf16.count { return block }
            location += block.text.utf16.count
            if index < blocks.count - 1 { location += 1 }
        }
        return blocks.last
    }

    private static func equationBlockIDs(
        in blocks: [EditorBlock],
        selection: NSRange
    ) -> Set<UUID> {
        var location = 0
        var result: Set<UUID> = []
        for (index, block) in blocks.enumerated() {
            let range = NSRange(location: location, length: block.text.utf16.count)
            let intersects = selection.length == 0
                ? selection.location >= range.location && selection.location <= NSMaxRange(range)
                : NSIntersectionRange(selection, range).length > 0
            if block.kind == .equation, intersects { result.insert(block.id) }
            location = NSMaxRange(range)
            if index < blocks.count - 1 { location += 1 }
        }
        return result
    }

    private static func sourceAlignedSelection(
        _ selection: NSRange,
        in blocks: [EditorBlock],
        editingEquationIDs: Set<UUID>,
        editingInlineMathRanges: [NSRange]
    ) -> NSRange {
        let start = sourceAlignedOffset(
            selection.location,
            in: blocks,
            editingEquationIDs: editingEquationIDs,
            editingInlineMathRanges: editingInlineMathRanges,
            preferUpperBoundary: false
        )
        let end = sourceAlignedOffset(
            NSMaxRange(selection),
            in: blocks,
            editingEquationIDs: editingEquationIDs,
            editingInlineMathRanges: editingInlineMathRanges,
            preferUpperBoundary: selection.length > 0
        )
        return NSRange(location: start, length: max(end - start, 0))
    }

    private static func sourceAlignedOffset(
        _ offset: Int,
        in blocks: [EditorBlock],
        editingEquationIDs: Set<UUID>,
        editingInlineMathRanges: [NSRange],
        preferUpperBoundary: Bool
    ) -> Int {
        var blockStart = 0
        for (index, block) in blocks.enumerated() {
            let blockEnd = blockStart + block.text.utf16.count
            let blockRange = NSRange(location: blockStart, length: block.text.utf16.count)
            let editsInlineMath = editingInlineMathRanges.contains {
                NSIntersectionRange($0, blockRange).length > 0
            }
            if (editingEquationIDs.contains(block.id) || editsInlineMath),
               offset >= blockStart,
               offset <= blockEnd {
                var localOffset = offset - blockStart
                while !isCharacterBoundary(localOffset, in: block.text) {
                    localOffset += preferUpperBoundary ? 1 : -1
                }
                return blockStart + localOffset
            }
            blockStart = blockEnd
            if index < blocks.count - 1 { blockStart += 1 }
        }
        return offset
    }

    private static func isCharacterBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return String.Index(index, within: text) != nil
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }
}
