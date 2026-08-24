// Created by JunyoungJung on 2026-08-21.

import SwiftUI
import SwiftLatex
import UIKit
import UniformTypeIdentifiers

enum EditorToolbarAction {
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

final class BlockDocumentUITextView: UITextView {
    static let blockDocumentPasteboardType = "com.swiftlatex.demo.block-document"

    var fullDocumentMarkdown: String?
    var fullDocumentBlocks: [EditorBlock] = []
    var onPasteDocumentBlocks: ((NSRange, [EditorBlock]) -> Bool)?
    private let ownedContentStorage: NSTextContentStorage

    init() {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
        ownedContentStorage = contentStorage
        super.init(frame: .zero, textContainer: textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlockDocumentUITextView는 코드로만 생성합니다")
    }

    override func copy(_ sender: Any?) {
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

    override func paste(_ sender: Any?) {
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

private struct BlockDocumentPasteboardPayload: Codable {
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

    static func encode(_ blocks: [EditorBlock]) -> Data? {
        guard !blocks.isEmpty else { return nil }
        let payload = Self(version: 1, blocks: blocks.map(Block.init))
        guard let data = try? JSONEncoder().encode(payload), data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    static func decode(_ data: Data) -> [EditorBlock]? {
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
struct BlockDocumentTextEditor: UIViewRepresentable {
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
    var preset: LatexThemePreset = .standard
    var sourceMarkdown: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BlockDocumentUITextView {
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
            preset: preset,
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
        coordinator.lastPreset = preset
        coordinator.lastContentSizeCategory = sizeCategory
        let block = activeBlock
        let kind = block?.kind ?? .paragraph
        let accessory = BlockKeyboardToolbar(
            kind: kind,
            canUndo: canUndo,
            canRedo: canRedo,
            onAction: coordinator.handleToolbarAction
        )
        coordinator.accessory = accessory
        view.inputAccessoryView = accessory
        coordinator.applyTypingAttributes(
            MarkdownStyler.typingAttributes(
                for: block,
                preset: preset,
                traitCollection: view.traitCollection
            ),
            to: view
        )
        return view
    }

    func updateUIView(_ view: BlockDocumentUITextView, context: Context) {
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
            || coordinator.lastPreset != preset
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
                preset: preset,
                traitCollection: view.traitCollection
            ),
            to: view
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BlockDocumentTextEditor
        weak var editingView: UITextView? {
            didSet {
                if let editingView {
                    lastCommittedSelection = editingView.selectedRange
                }
            }
        }
        fileprivate weak var accessory: BlockKeyboardToolbar?
        var isApplyingUpdate = false
        var baselineText = ""
        var lastBlocks: [EditorBlock] = []
        var lastEditingEquationIDs: Set<UUID> = []
        var lastEditingInlineMathRanges: [NSRange] = []
        var lastParsesDollarMath = false
        var lastPreset: LatexThemePreset = .standard
        var lastContentSizeCategory: ContentSizeCategory?
        private var pendingTextChange: (range: NSRange, replacement: String)?
        private var compositionRange: NSRange?
        private var lastCommittedSelection = NSRange(location: 0, length: 0)

        init(_ parent: BlockDocumentTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            reconcileTextChange(in: view)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard !isApplyingUpdate else { return true }
            pendingTextChange = (range, text)
            return true
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
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
                preset: parent.preset,
                selection: selection,
                traitCollection: view.traitCollection
            )
            isApplyingUpdate = true
            if view.text == styled.string {
                Self.applyAttributes(from: styled, to: view.textStorage)
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
            lastPreset = parent.preset
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
                NSRange(location: oldPrefix.utf16.count, length: String(oldCharacters[prefixCount..<(prefixCount + oldChanged)]).utf16.count),
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

/// Notion 모바일의 키보드 위 가로 스크롤 명령 막대.
final class BlockKeyboardToolbar: UIView {
    private let surfaceView = BlockKeyboardToolbar.makeSurfaceView()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let addButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private var formattingButtons: [UIButton] = []
    private var isFormattingVisible = false
    private let onAction: (EditorToolbarAction) -> Void

    init(
        kind: EditorBlockKind,
        canUndo: Bool,
        canRedo: Bool,
        onAction: @escaping (EditorToolbarAction) -> Void
    ) {
        self.onAction = onAction
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 64))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        tintColor = .label
        accessibilityIdentifier = "blockKeyboardToolbar"
        addInteraction(UILargeContentViewerInteraction(delegate: nil))

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.layer.cornerRadius = 28
        surfaceView.layer.cornerCurve = .continuous
        surfaceView.clipsToBounds = true
        addSubview(surfaceView)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.accessibilityIdentifier = "blockKeyboardToolbarScroll"
        surfaceView.contentView.addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            surfaceView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: surfaceView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: surfaceView.contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: surfaceView.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: surfaceView.contentView.bottomAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 4
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -4
            ),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        configureButton(addButton, image: "plus", label: "블록 추가", identifier: "blockToolbar.add")
        addButton.showsMenuAsPrimaryAction = true
        addButton.menu = blockMenu()
        stackView.addArrangedSubview(addButton)

        configureButton(formatButton, image: "textformat", label: "서식", identifier: "blockToolbar.format")
        formatButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            setFormattingVisible(!isFormattingVisible)
        }, for: .touchUpInside)
        stackView.addArrangedSubview(formatButton)

        formattingButtons = [
            button("bold", "굵게", "blockToolbar.bold", .format(.bold)),
            button("italic", "기울임", "blockToolbar.italic", .format(.italic)),
            button("strikethrough", "취소선", "blockToolbar.strike", .format(.strikethrough)),
            button(
                "chevron.left.forwardslash.chevron.right",
                "인라인 코드",
                "blockToolbar.code",
                .format(.code)
            ),
        ]
        formattingButtons.forEach {
            $0.isHidden = true
            stackView.addArrangedSubview($0)
        }
        stackView.addArrangedSubview(button("decrease.indent", "내어쓰기", "blockToolbar.outdent", .outdent))
        stackView.addArrangedSubview(button("increase.indent", "들여쓰기", "blockToolbar.indent", .indent))
        configureButton(undoButton, image: "arrow.uturn.backward", label: "실행 취소", identifier: "blockToolbar.undo")
        undoButton.addAction(UIAction { [weak self] _ in self?.onAction(.undo) }, for: .touchUpInside)
        stackView.addArrangedSubview(undoButton)
        configureButton(redoButton, image: "arrow.uturn.forward", label: "다시 실행", identifier: "blockToolbar.redo")
        redoButton.addAction(UIAction { [weak self] _ in self?.onAction(.redo) }, for: .touchUpInside)
        stackView.addArrangedSubview(redoButton)

        let more = UIButton(type: .system)
        configureButton(more, image: "ellipsis", label: "블록 더보기", identifier: "blockToolbar.more")
        more.showsMenuAsPrimaryAction = true
        more.menu = moreMenu()
        stackView.addArrangedSubview(more)
        stackView.addArrangedSubview(button("keyboard.chevron.compact.down", "키보드 닫기", "blockToolbar.done", .done))
        update(kind: kind, canUndo: canUndo, canRedo: canRedo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 64)
    }

    func update(kind: EditorBlockKind, canUndo: Bool, canRedo: Bool) {
        addButton.accessibilityValue = "현재 블록: \(kind.title)"
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private func setFormattingVisible(_ isVisible: Bool) {
        guard isFormattingVisible != isVisible else { return }
        isFormattingVisible = isVisible
        formattingButtons.forEach { $0.isHidden = !isVisible }
        formatButton.isSelected = isVisible
        formatButton.accessibilityLabel = isVisible ? "서식 도구 닫기" : "서식"
        layoutIfNeeded()
        if !isVisible {
            scrollView.setContentOffset(.zero, animated: true)
        }
        UIAccessibility.post(
            notification: .layoutChanged,
            argument: isVisible ? formattingButtons.first : formatButton
        )
    }

    private func button(
        _ image: String,
        _ label: String,
        _ identifier: String,
        _ action: EditorToolbarAction
    ) -> UIButton {
        let button = UIButton(type: .system)
        configureButton(button, image: image, label: label, identifier: identifier)
        button.addAction(UIAction { [weak self] _ in self?.onAction(action) }, for: .touchUpInside)
        return button
    }

    private func configureButton(_ button: UIButton, image: String, label: String, identifier: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: image)
        button.configuration = configuration
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
    }

    private static func makeSurfaceView() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            return UIVisualEffectView(effect: effect)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }

    private func blockMenu() -> UIMenu {
        let kinds: [EditorBlockKind] = [
            .paragraph,
            .heading(level: 1),
            .heading(level: 2),
            .heading(level: 3),
            .bulletedList,
            .numberedList,
            .toDo(isChecked: false),
            .quote,
            .code(language: nil),
            .equation,
        ]
        return UIMenu(children: kinds.map { kind in
            UIAction(
                title: kind.title,
                image: UIImage(systemName: kind.systemImage),
            ) { [weak self] _ in
                self?.onAction(.insert(kind))
            }
        })
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.onAction(.duplicate)
            },
            UIAction(title: "위로 이동", image: UIImage(systemName: "arrow.up")) { [weak self] _ in
                self?.onAction(.moveUp)
            },
            UIAction(title: "아래로 이동", image: UIImage(systemName: "arrow.down")) { [weak self] _ in
                self?.onAction(.moveDown)
            },
            UIAction(
                title: "블록 삭제",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.onAction(.delete)
            },
        ])
    }
}

final class EquationTextAttachment: NSTextAttachment {
    let latex: String
    let source: String
    let theme: LatexTheme
    let isDisplay: Bool
    let pointSize: CGFloat

    init(
        latex: String,
        source: String,
        theme: LatexTheme,
        isDisplay: Bool,
        pointSize: CGFloat
    ) {
        self.latex = latex
        self.source = source
        self.theme = theme
        self.isDisplay = isDisplay
        self.pointSize = pointSize
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        lineLayoutPadding = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EquationTextAttachment는 코드로만 생성합니다")
    }

    override func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        EquationAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}

private final class EquationAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        super.loadView()
        guard let attachment = textAttachment as? EquationTextAttachment else { return }
        let equationView = LatexEquationUIView(
            latex: attachment.latex,
            source: attachment.source,
            theme: attachment.theme,
            isDisplay: attachment.isDisplay,
            pointSize: attachment.pointSize
        )
        equationView.isUserInteractionEnabled = false
        view = equationView
        tracksTextAttachmentViewBounds = true
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let equationView = view as? LatexEquationUIView else {
            return super.attachmentBounds(
                for: attributes,
                location: location,
                textContainer: textContainer,
                proposedLineFragment: proposedLineFragment,
                position: position
            )
        }
        let intrinsic = equationView.intrinsicContentSize
        let availableWidth = max(proposedLineFragment.width - position.x, 1)
        let width = min(max(intrinsic.width, 1), availableWidth)
        let font = attributes[.font] as? UIFont
        return CGRect(
            x: 0,
            y: font?.descender ?? 0,
            width: width,
            height: max(intrinsic.height, font?.lineHeight ?? 1)
        )
    }
}

/// 블록 마커는 모델로 분리하고, 인라인 Markdown만 라이브 스타일링한다.
enum MarkdownStyler {
    static func baseAttributes(
        for kind: EditorBlockKind,
        preset: LatexThemePreset = .standard,
        traitCollection: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: kind, preset: preset, traitCollection: traitCollection),
            .foregroundColor: kind == .quote
                ? UIColor.secondaryLabel
                : UIColor(preset.theme.textColor),
        ]
    }

    static func typingAttributes(
        for block: EditorBlock?,
        preset: LatexThemePreset = .standard,
        traitCollection: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        let block = block ?? EditorBlock(text: "")
        var attributes = baseAttributes(
            for: block.kind,
            preset: preset,
            traitCollection: traitCollection
        )
        attributes[.paragraphStyle] = paragraphStyle(for: block, numberedListOrdinal: 1)
        return attributes
    }

    static func styledDocument(
        _ blocks: [EditorBlock],
        editingEquationIDs: Set<UUID> = [],
        parsesDollarMath: Bool = false,
        preset: LatexThemePreset = .standard,
        selection: NSRange? = nil,
        traitCollection: UITraitCollection? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var numberedCounts: [Int: Int] = [:]
        var previousKinds: [Int: EditorBlockKind] = [:]

        for (index, block) in blocks.enumerated() {
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

            let start = result.length
            if block.kind == .equation,
               !editingEquationIDs.contains(block.id),
               !block.text.isEmpty {
                result.append(equationAttachment(
                    for: block,
                    preset: preset,
                    traitCollection: traitCollection
                ))
            } else {
                let localSelection = selection.flatMap {
                    selectionWithinBlock($0, blockStart: start, blockLength: block.text.utf16.count)
                }
                result.append(styled(
                    block,
                    parsesDollarMath: parsesDollarMath,
                    preset: preset,
                    selection: localSelection,
                    traitCollection: traitCollection
                ))
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: baseAttributes(
                        for: block.kind,
                        preset: preset,
                        traitCollection: traitCollection
                    )
                ))
            }
            let range = NSRange(location: start, length: result.length - start)
            if range.length > 0 {
                result.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(for: block, numberedListOrdinal: ordinal),
                    range: range
                )
            }
        }

        assert(result.length == blocks.map(\.text).joined(separator: "\n").utf16.count)
        return result
    }

    static func inlineMathRanges(
        in blocks: [EditorBlock],
        intersecting selection: NSRange,
        parsesDollarMath: Bool
    ) -> [NSRange] {
        var blockStart = 0
        var result: [NSRange] = []
        for (index, block) in blocks.enumerated() {
            let blockRange = NSRange(location: blockStart, length: block.text.utf16.count)
            if intersects(blockRange, selection: selection) {
                for span in inlineMathSpans(in: block, parsesDollarMath: parsesDollarMath) {
                    let documentRange = NSRange(
                        location: blockStart + span.range.location,
                        length: span.range.length
                    )
                    if intersects(documentRange, selection: selection) {
                        result.append(documentRange)
                    }
                }
            }
            blockStart += block.text.utf16.count
            if index < blocks.count - 1 { blockStart += 1 }
        }
        return result
    }

    static func styled(
        _ block: EditorBlock,
        parsesDollarMath: Bool = false,
        preset: LatexThemePreset = .standard,
        selection: NSRange? = nil,
        traitCollection: UITraitCollection? = nil
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: block.text,
            attributes: baseAttributes(
                for: block.kind,
                preset: preset,
                traitCollection: traitCollection
            )
        )
        guard !block.kind.preservesLineBreaks else { return text }
        let mono = inlineCodeFont(preset: preset, traitCollection: traitCollection)

        for format in InlineFormat.allCases {
            for mark in block.inlineMarks where mark.format == format && mark.range.length > 0 {
                guard mark.range.location >= 0, NSMaxRange(mark.range) <= text.length else { continue }
                switch mark.format {
                case .bold:
                    applyFontTraits(.traitBold, range: mark.range, to: text)
                case .italic:
                    applyFontTraits(.traitItalic, range: mark.range, to: text)
                case .strikethrough:
                    text.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: mark.range
                    )
                case .code:
                    text.addAttribute(.font, value: mono, range: mark.range)
                    text.addAttribute(
                        .backgroundColor,
                        value: UIColor(preset.theme.inlineCodeBackground),
                        range: mark.range
                    )
                }
            }
        }

        let inlineMathSpans = inlineMathSpans(in: block, parsesDollarMath: parsesDollarMath)
        for span in inlineMathSpans where !intersects(span.range, selection: selection) {
            text.replaceCharacters(
                in: span.range,
                with: equationAttachment(
                    latex: span.latex,
                    source: span.source,
                    sourceLength: span.range.length,
                    kind: block.kind,
                    preset: preset,
                    isDisplay: false,
                    traitCollection: traitCollection
                )
            )
        }
        return text
    }

    private static func equationAttachment(
        for block: EditorBlock,
        preset: LatexThemePreset,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        equationAttachment(
            latex: block.text,
            source: block.text,
            sourceLength: block.text.utf16.count,
            kind: block.kind,
            preset: preset,
            isDisplay: true,
            traitCollection: traitCollection
        )
    }

    private static func equationAttachment(
        latex: String,
        source: String,
        sourceLength: Int,
        kind: EditorBlockKind,
        preset: LatexThemePreset,
        isDisplay: Bool,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        let attributes = baseAttributes(
            for: kind,
            preset: preset,
            traitCollection: traitCollection
        )
        let pointSize = (attributes[.font] as? UIFont)?.pointSize
            ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        let attachment = EquationTextAttachment(
            latex: latex,
            source: source,
            theme: preset.theme,
            isDisplay: isDisplay,
            pointSize: pointSize
        )
        let result = NSMutableAttributedString(attachment: attachment)
        if sourceLength > 1 {
            result.append(NSAttributedString(
                string: String(repeating: "\u{2063}", count: sourceLength - 1)
            ))
        }
        result.addAttributes(
            attributes,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func inlineMathSpans(
        in block: EditorBlock,
        parsesDollarMath: Bool
    ) -> [LatexInlineMathSpan] {
        guard !block.kind.preservesLineBreaks else { return [] }
        let codeRanges = block.inlineMarks.compactMap { mark in
            mark.format == .code ? mark.range : nil
        }
        return LatexInlineMathScanner.scan(
            block.text,
            parsesDollarMath: parsesDollarMath,
            excluding: codeRanges
        )
    }

    private static func selectionWithinBlock(
        _ selection: NSRange,
        blockStart: Int,
        blockLength: Int
    ) -> NSRange? {
        let blockRange = NSRange(location: blockStart, length: blockLength)
        if selection.length == 0 {
            guard selection.location >= blockStart,
                  selection.location <= NSMaxRange(blockRange)
            else { return nil }
            return NSRange(location: selection.location - blockStart, length: 0)
        }
        let intersection = NSIntersectionRange(selection, blockRange)
        guard intersection.length > 0 else { return nil }
        return NSRange(
            location: intersection.location - blockStart,
            length: intersection.length
        )
    }

    private static func intersects(_ range: NSRange, selection: NSRange?) -> Bool {
        guard let selection else { return false }
        if selection.length == 0 {
            return selection.location >= range.location
                && selection.location < NSMaxRange(range)
        }
        return NSIntersectionRange(range, selection).length > 0
    }

    private static func paragraphStyle(
        for block: EditorBlock,
        numberedListOrdinal: Int
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = block.kind == .paragraph ? 8 : 10

        switch block.kind {
        case .bulletedList, .numberedList, .toDo:
            style.textLists = (0...block.indentLevel).map { depth in
                textList(
                    for: block.kind,
                    startingItemNumber: depth == block.indentLevel ? numberedListOrdinal : 1
                )
            }
        case .quote:
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            style.tailIndent = -16
        case .code:
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
        case .equation:
            style.alignment = .center
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
        case .paragraph, .heading:
            break
        }
        let nestingIndent = CGFloat(block.indentLevel) * 20
        style.firstLineHeadIndent += nestingIndent
        style.headIndent += nestingIndent
        return style
    }

    private static func textList(
        for kind: EditorBlockKind,
        startingItemNumber: Int
    ) -> NSTextList {
        switch kind {
        case .bulletedList:
            NSTextList(markerFormat: .disc, options: [], startingItemNumber: 1)
        case .numberedList:
            NSTextList(
                markerFormat: .decimal,
                options: [],
                startingItemNumber: max(startingItemNumber, 1)
            )
        case let .toDo(isChecked):
            NSTextList(
                markerFormat: isChecked ? .check : .box,
                options: [],
                startingItemNumber: 1
            )
        default:
            preconditionFailure("목록 블록만 NSTextList를 만들 수 있습니다")
        }
    }

    private static func font(
        for kind: EditorBlockKind,
        preset: LatexThemePreset,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        if case .code = kind {
            return scaledMonospacedFont(
                forTextStyle: .body,
                referencePointSize: preset == .large ? 20 : nil,
                traitCollection: traitCollection
            )
        }
        if case .equation = kind {
            return scaledMonospacedFont(
                forTextStyle: .body,
                referencePointSize: preset == .large ? 20 : nil,
                traitCollection: traitCollection
            )
        }

        let style: UIFont.TextStyle
        let largeSize: CGFloat
        let serifName: String
        let isHeading: Bool
        if case let .heading(level) = kind {
            style = switch level {
            case 1: .title1
            case 2: .title2
            default: .title3
            }
            largeSize = switch level {
            case 1: 38
            case 2: 30
            default: 26
            }
            serifName = "Georgia-Bold"
            isHeading = true
        } else {
            style = .body
            largeSize = 24
            serifName = "Georgia"
            isHeading = false
        }

        switch preset {
        case .standard, .tinted:
            let font = UIFont.preferredFont(
                forTextStyle: style,
                compatibleWith: traitCollection
            )
            return isHeading ? withTraits(.traitBold, font: font) : font
        case .large:
            return scaledSystemFont(
                pointSize: largeSize,
                weight: isHeading ? .bold : .regular,
                textStyle: style,
                traitCollection: traitCollection
            )
        case .serif:
            return scaledCustomFont(
                name: serifName,
                textStyle: style,
                traitCollection: traitCollection
            )
        }
    }

    private static func inlineCodeFont(
        preset: LatexThemePreset,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        scaledMonospacedFont(
            forTextStyle: .body,
            referencePointSize: preset == .large ? 20 : nil,
            pointSizeAdjustment: preset == .large ? 0 : -2,
            traitCollection: traitCollection
        )
    }

    private static func scaledSystemFont(
        pointSize: CGFloat,
        weight: UIFont.Weight,
        textStyle: UIFont.TextStyle,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: .systemFont(ofSize: pointSize, weight: weight),
            compatibleWith: traitCollection
        )
    }

    private static func scaledCustomFont(
        name: String,
        textStyle: UIFont.TextStyle,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        let referenceTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let referenceSize = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: referenceTraits
        ).pointSize
        let base = UIFont(name: name, size: referenceSize)
            ?? UIFont.systemFont(ofSize: referenceSize)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: base,
            compatibleWith: traitCollection
        )
    }

    private static func scaledMonospacedFont(
        forTextStyle textStyle: UIFont.TextStyle,
        referencePointSize: CGFloat? = nil,
        pointSizeAdjustment: CGFloat = 0,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        let referenceTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let referenceSize = UIFont.preferredFont(
            forTextStyle: textStyle,
            compatibleWith: referenceTraits
        ).pointSize
        let base = UIFont.monospacedSystemFont(
            ofSize: max((referencePointSize ?? referenceSize) + pointSizeAdjustment, 1),
            weight: .regular
        )
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: base,
            compatibleWith: traitCollection
        )
    }

    private static func withTraits(_ traits: UIFontDescriptor.SymbolicTraits, font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(traits)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func applyFontTraits(
        _ traits: UIFontDescriptor.SymbolicTraits,
        range: NSRange,
        to text: NSMutableAttributedString
    ) {
        var runs: [(UIFont, NSRange)] = []
        text.enumerateAttribute(.font, in: range) { value, runRange, _ in
            if let font = value as? UIFont { runs.append((font, runRange)) }
        }
        for (font, runRange) in runs {
            text.addAttribute(.font, value: withTraits(traits, font: font), range: runRange)
        }
    }
}
