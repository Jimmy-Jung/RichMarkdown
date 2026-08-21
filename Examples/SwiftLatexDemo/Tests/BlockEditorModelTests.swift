// Created by JunyoungJung on 2026-08-21.

import Foundation
import SwiftLatex
import Testing
import UIKit
@testable import SwiftLatexDemo

@Suite("Notion 스타일 블록 편집 모델")
struct BlockEditorModelTests {
    @Test("Enter는 UTF-16 커서 위치에서 블록을 나누고 ID를 보존한다")
    func splitBlockAtCaret() throws {
        let firstID = UUID()
        let followingID = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: firstID, kind: .paragraph, text: "가😀나"),
            EditorBlock(id: followingID, kind: .paragraph, text: "다음"),
        ])

        let splitSelection = model.splitBlock(id: firstID, atUTF16Offset: 3)
        let selection = try #require(splitSelection)

        #expect(model.blocks.map(\.text) == ["가😀", "나", "다음", ""])
        #expect(model.blocks[0].id == firstID)
        #expect(model.blocks[2].id == followingID)
        #expect(selection.blockID == model.blocks[1].id)
        #expect(selection.range == NSRange(location: 0, length: 0))
    }

    @Test("Enter는 선택한 텍스트를 지운 뒤 한 번만 분할한다")
    func splitReplacingSelection() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "가나다라"),
        ])

        let result = model.splitBlock(id: id, replacing: NSRange(location: 1, length: 2))
        let selection = try #require(result)

        #expect(model.blocks.map(\.text) == ["가", "라", ""])
        #expect(selection.blockID == model.blocks[1].id)
    }

    @Test("일반 블록의 줄바꿈 요청도 새 논리 블록을 만든다")
    func softBreakRequestSplitsRegularBlock() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "앞뒤"),
        ])

        let softBreakSelection = model.insertSoftBreak(id: id, atUTF16Offset: 1)
        let selection = try #require(softBreakSelection)

        #expect(model.blocks.map(\.text) == ["앞", "뒤", ""])
        #expect(model.blocks[0].id == id)
        #expect(selection == BlockSelection(
            blockID: model.blocks[1].id,
            range: NSRange(location: 0, length: 0)
        ))
    }

    @Test("초기 일반 텍스트의 줄바꿈은 블록으로 나누고 코드 줄바꿈은 보존한다")
    func initialTextNormalizesLineBreaksByBlockKind() {
        let model = BlockEditorModel(blocks: [
            EditorBlock(kind: .paragraph, text: "첫 줄\n둘째"),
            EditorBlock(kind: .code(language: "swift"), text: "let\nx"),
        ])

        #expect(model.blocks.map(\.text) == ["첫 줄", "둘째", "let\nx", ""])
        #expect(model.blocks[0].kind == .paragraph)
        #expect(model.blocks[1].kind == .paragraph)
        #expect(model.blocks[2].kind == .code(language: "swift"))
    }

    @Test("일반 블록 시작의 Backspace는 이전 블록과 합친다")
    func mergeAtBlockStart() throws {
        let firstID = UUID()
        let secondID = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: firstID, kind: .paragraph, text: "앞"),
            EditorBlock(id: secondID, kind: .paragraph, text: "뒤"),
        ])

        let mergedSelection = model.backspaceAtStart(of: secondID)
        let selection = try #require(mergedSelection)

        #expect(model.blocks.map(\.text) == ["앞뒤", ""])
        #expect(model.blocks[0].id == firstID)
        #expect(!model.blocks.contains { $0.id == secondID })
        #expect(selection == BlockSelection(blockID: firstID, range: NSRange(location: 1, length: 0)))
    }

    @Test("서식 블록 시작의 Backspace는 문단으로 변환한다")
    func convertFormattedBlockBeforeMerging() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .heading(level: 2), text: "제목"),
        ])

        let convertedSelection = model.backspaceAtStart(of: id)
        let selection = try #require(convertedSelection)

        #expect(model.blocks[0] == EditorBlock(id: id, kind: .paragraph, text: "제목"))
        #expect(selection == BlockSelection(blockID: id, range: NSRange(location: 0, length: 0)))
    }

    @Test("빈 목록에서 Enter를 누르면 같은 ID의 일반 문단이 된다")
    func emptyListBecomesParagraph() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .bulletedList, text: ""),
        ])

        let result = model.splitBlock(id: id, atUTF16Offset: 0)
        let selection = try #require(result)

        #expect(model.blocks.first == EditorBlock(id: id, kind: .paragraph, text: ""))
        #expect(selection.blockID == id)
    }

    @Test("블록 종류는 Markdown 마커와 본문을 분리한다")
    func parseAndRenderTypedBlocks() {
        let heading = EditorBlock(markdown: "## 제목")
        let code = EditorBlock(markdown: "```swift\nlet answer = 42\n```")
        let equation = EditorBlock(markdown: "\\[x^2 + y^2\\]")

        #expect(heading.kind == .heading(level: 2))
        #expect(heading.text == "제목")
        #expect(heading.markdown == "## 제목")
        #expect(code.kind == .code(language: "swift"))
        #expect(code.text == "let answer = 42")
        #expect(code.markdown == "```swift\nlet answer = 42\n```")
        #expect(equation.kind == .equation)
        #expect(equation.text == "x^2 + y^2")
        #expect(equation.markdown == "\\[x^2 + y^2\\]")
    }

    @Test("연속 목록 항목은 독립 블록이며 번호가 이어진다")
    func consecutiveListItemsBecomeBlocks() throws {
        let model = BlockEditorModel(markdown: "- 하나\n- 둘\n\n1. 첫째\n2. 둘째")

        #expect(model.blocks.map(\.text) == ["하나", "둘", "첫째", "둘째", ""])
        #expect(model.blocks[0].kind == .bulletedList)
        #expect(model.blocks[1].kind == .bulletedList)
        #expect(model.blocks[2].kind == .numberedList)
        #expect(model.blocks[3].kind == .numberedList)
        #expect(model.numberedListOrdinal(for: model.blocks[2].id) == 1)
        #expect(model.numberedListOrdinal(for: model.blocks[3].id) == 2)
        #expect(model.blocks[3].markdown(numberedListOrdinal: 2) == "2. 둘째")

        let nested = EditorBlock(markdown: "  - 하위 항목")
        #expect(nested.kind == .bulletedList)
        #expect(nested.indentLevel == 1)
        #expect(nested.text == "하위 항목")
        #expect(nested.markdown == "  - 하위 항목")
    }

    @Test("중첩 번호 목록 뒤의 같은 깊이 번호는 이어지고 같은 깊이 문단에서 초기화된다")
    func numberedListOrdinalSkipsNestedBlocksAndResetsAtPeerParagraph() {
        let first = EditorBlock(kind: .numberedList, text: "바깥 첫째")
        let nested = EditorBlock(kind: .numberedList, text: "안쪽 첫째", indentLevel: 1)
        let second = EditorBlock(kind: .numberedList, text: "바깥 둘째")
        let paragraph = EditorBlock(kind: .paragraph, text: "구분")
        let reset = EditorBlock(kind: .numberedList, text: "다시 첫째")
        let model = BlockEditorModel(blocks: [first, nested, second, paragraph, reset])

        #expect(model.numberedListOrdinal(for: first.id) == 1)
        #expect(model.numberedListOrdinal(for: nested.id) == 1)
        #expect(model.numberedListOrdinal(for: second.id) == 2)
        #expect(model.numberedListOrdinal(for: reset.id) == 1)
    }

    @Test("복제·삭제·종류 변환은 undo와 redo로 복구된다")
    func editCommandsAreUndoable() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "본문"),
        ])

        let duplicated = model.duplicate(id: id)
        let duplicateSelection = try #require(duplicated)
        #expect(model.blocks.prefix(2).map(\.text) == ["본문", "본문"])
        #expect(duplicateSelection.blockID != id)

        model.transform(id: duplicateSelection.blockID, to: .quote)
        #expect(model.blocks[1].kind == .quote)
        model.delete(id: id)
        #expect(model.blocks.first?.kind == .quote)

        let firstUndo = model.undo()
        #expect(firstUndo)
        #expect(model.blocks.first?.id == id)
        let secondUndo = model.undo()
        #expect(secondUndo)
        #expect(model.blocks[1].kind == .paragraph)
        let thirdUndo = model.undo()
        #expect(thirdUndo)
        #expect(model.blocks.map(\.text) == ["본문", ""])

        let redo = model.redo()
        #expect(redo)
        #expect(model.blocks.prefix(2).map(\.text) == ["본문", "본문"])
    }

    @Test("인라인 서식·바로가기·들여쓰기도 같은 전이 모델을 사용한다")
    func formattingShortcutAndIndent() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "본문"),
        ])

        let formatted = model.applyInlineFormat(.bold, id: id, range: NSRange(location: 0, length: 2))
        let formatSelection = try #require(formatted)
        #expect(model.blocks[0].text == "본문")
        #expect(model.blocks[0].inlineMarks == [
            InlineMark(format: .bold, range: NSRange(location: 0, length: 2)),
        ])
        #expect(formatSelection.range == NSRange(location: 0, length: 2))

        model.updateText(id: id, text: "- 본문")
        let shortcut = model.applyShortcut(id: id, kind: .bulletedList, prefixUTF16Length: 2)
        _ = try #require(shortcut)
        #expect(model.blocks[0].kind == .bulletedList)
        #expect(model.blocks[0].text == "본문")

        let indented = model.indent(id: id)
        #expect(indented)
        #expect(model.blocks[0].indentLevel == 1)
        let outdented = model.outdent(id: id)
        #expect(outdented)
        #expect(model.blocks[0].indentLevel == 0)
    }

    @Test("인라인 서식 토글은 선택한 하위 범위만 해제한다")
    func inlineFormatToggleSubtractsSelectedRange() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(
                id: id,
                kind: .paragraph,
                text: "가나다라",
                inlineMarks: [InlineMark(format: .bold, range: NSRange(location: 0, length: 4))]
            ),
        ])

        let result = model.applyInlineFormat(
            .bold,
            id: id,
            range: NSRange(location: 1, length: 2)
        )
        let selection = try #require(result)

        #expect(selection.range == NSRange(location: 1, length: 2))
        #expect(model.blocks[0].inlineMarks == [
            InlineMark(format: .bold, range: NSRange(location: 0, length: 1)),
            InlineMark(format: .bold, range: NSRange(location: 3, length: 1)),
        ])
    }

    @Test("잘못된 UTF-16 범위는 문서를 바꾸지 않는다")
    func invalidRangesAreRejected() {
        let id = UUID()
        let original = EditorBlock(id: id, kind: .paragraph, text: "본문")
        var model = BlockEditorModel(blocks: [original])

        let split = model.splitBlock(id: id, replacing: NSRange(location: -1, length: 0))
        let format = model.applyInlineFormat(.bold, id: id, range: NSRange(location: 0, length: 3))
        let shortcut = model.applyShortcut(id: id, kind: .quote, prefixUTF16Length: -1)

        #expect(split == nil)
        #expect(format == nil)
        #expect(shortcut == nil)
        #expect(model.blocks.first == original)

        let emojiID = UUID()
        var emojiModel = BlockEditorModel(blocks: [
            EditorBlock(id: emojiID, kind: .paragraph, text: "가😀나"),
        ])
        let surrogateSplit = emojiModel.splitBlock(id: emojiID, atUTF16Offset: 2)
        #expect(surrogateSplit == nil)
        #expect(emojiModel.blocks[0].text == "가😀나")
    }

    @Test("텍스트 입력은 undo 대상이고 새 입력은 redo 분기를 폐기한다")
    func textInputParticipatesInHistory() {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "A"),
        ])

        model.updateText(id: id, text: "AB")
        let firstUndo = model.undo()
        #expect(firstUndo)
        #expect(model.blocks[0].text == "A")

        model.updateText(id: id, text: "AC")
        let staleRedo = model.redo()
        #expect(!staleRedo)
        #expect(model.blocks[0].text == "AC")
    }

    @Test("undo와 redo는 문서와 함께 커서 선택을 복원한다")
    func historyRestoresSelection() {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "AB"),
        ])
        let before = BlockSelection(blockID: id, range: NSRange(location: 1, length: 0))
        let after = BlockSelection(blockID: id, range: NSRange(location: 2, length: 0))

        model.updateSelection(before)
        model.updateText(id: id, text: "AXB")
        model.updateSelection(after)

        let undo = model.undo()
        #expect(undo)
        #expect(model.blocks[0].text == "AB")
        #expect(model.currentSelection == before)

        let redo = model.redo()
        #expect(redo)
        #expect(model.blocks[0].text == "AXB")
        #expect(model.currentSelection == after)
    }

    @Test("텍스트와 커서 변경은 하나의 전이로 undo와 redo에 기록된다")
    func textAndSelectionUpdateAtomically() {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .paragraph, text: "AB"),
        ])
        let before = BlockSelection(blockID: id, range: NSRange(location: 1, length: 0))
        let after = BlockSelection(blockID: id, range: NSRange(location: 2, length: 0))

        model.updateSelection(before)
        model.updateText(id: id, text: "AXB", selection: after)

        #expect(model.blocks[0].text == "AXB")
        #expect(model.currentSelection == after)
        let undo = model.undo()
        #expect(undo)
        #expect(model.blocks[0].text == "AB")
        #expect(model.currentSelection == before)
        let redo = model.redo()
        #expect(redo)
        #expect(model.blocks[0].text == "AXB")
        #expect(model.currentSelection == after)
    }

    @Test("위아래 이동은 문서 경계를 넘지 않는다")
    func moveBoundaries() {
        let firstID = UUID()
        let secondID = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: firstID, kind: .paragraph, text: "첫째"),
            EditorBlock(id: secondID, kind: .paragraph, text: "둘째"),
        ])

        let movedFirstUp = model.moveUp(id: firstID)
        let movedSecondDown = model.moveDown(id: secondID)
        let movedFirstDown = model.moveDown(id: firstID)
        #expect(!movedFirstUp)
        #expect(!movedSecondDown)
        #expect(movedFirstDown)
        #expect(model.blocks.prefix(2).map(\.id) == [secondID, firstID])
        let undo = model.undo()
        #expect(undo)
        #expect(model.blocks.prefix(2).map(\.id) == [firstID, secondID])
    }

    @Test("블록은 ID를 유지한 채 하나의 연속 UTF-16 문서로 투영된다")
    func projectsBlocksIntoContinuousDocument() throws {
        let paragraphID = UUID()
        let codeID = UUID()
        let model = BlockEditorModel(blocks: [
            EditorBlock(id: paragraphID, kind: .paragraph, text: "가😀"),
            EditorBlock(id: codeID, kind: .code(language: "swift"), text: "let\nx"),
        ])

        #expect(model.documentText == "가😀\nlet\nx\n")
        #expect(try #require(model.documentRange(for: paragraphID)) == NSRange(location: 0, length: 3))
        #expect(try #require(model.documentRange(for: codeID)) == NSRange(location: 4, length: 5))
    }

    @Test("연속 문서 스타일은 문자열 offset을 보존하고 목록을 NSTextList로 표시한다")
    func styledDocumentPreservesOffsetsAndUsesTextLists() throws {
        let bullet = EditorBlock(kind: .bulletedList, text: "항목", indentLevel: 1)
        let firstNumber = EditorBlock(kind: .numberedList, text: "첫째")
        let secondNumber = EditorBlock(kind: .numberedList, text: "둘째")
        let unchecked = EditorBlock(kind: .toDo(isChecked: false), text: "할 일")
        let checked = EditorBlock(kind: .toDo(isChecked: true), text: "완료")
        let model = BlockEditorModel(blocks: [
            EditorBlock(kind: .heading(level: 1), text: "제목"),
            bullet,
            firstNumber,
            secondNumber,
            unchecked,
            checked,
            EditorBlock(kind: .code(language: "swift"), text: "let\nx"),
        ])

        let styled = MarkdownStyler.styledDocument(model.blocks)

        #expect(styled.string == model.documentText)
        #expect(styled.length == model.documentText.utf16.count)

        func paragraphStyle(for id: UUID) throws -> NSParagraphStyle {
            let range = try #require(model.documentRange(for: id))
            return try #require(
                styled.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )
        }

        let bulletStyle = try paragraphStyle(for: bullet.id)
        #expect(bulletStyle.textLists.count == 2)
        #expect(bulletStyle.textLists.last?.markerFormat == .disc)
        #expect(try paragraphStyle(for: firstNumber.id).textLists.last?.markerFormat == .decimal)
        #expect(try paragraphStyle(for: secondNumber.id).textLists.last?.startingItemNumber == 2)
        #expect(try paragraphStyle(for: unchecked.id).textLists.last?.markerFormat == .box)
        #expect(try paragraphStyle(for: checked.id).textLists.last?.markerFormat == .check)
    }

    @Test("의미 기반 인라인 마크를 plain text의 정확한 범위에 표시한다")
    func semanticInlineMarksDriveAttributes() throws {
        let block = EditorBlock(markdown: "**굵게** *기울임* ~~취소~~ `코드`")
        let styled = MarkdownStyler.styledDocument([block])

        #expect(styled.string == "굵게 기울임 취소 코드")
        let bold = try #require(styled.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let italic = try #require(styled.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(styled.attribute(.strikethroughStyle, at: 7, effectiveRange: nil) != nil)
        #expect(styled.attribute(.backgroundColor, at: 10, effectiveRange: nil) != nil)
    }

    @Test("비활성 수식 attachment는 TextKit 2에서 실제 수식 뷰를 만든다")
    @MainActor
    func equationAttachmentMaterializesInTextKit2() throws {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        textView.attributedText = MarkdownStyler.styledDocument([
            EditorBlock(kind: .equation, text: "E = mc^2"),
        ])

        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.isHidden = false
        let manager = try #require(textView.textLayoutManager)
        let contentManager = try #require(manager.textContentManager)
        manager.ensureLayout(for: contentManager.documentRange)
        window.layoutIfNeeded()

        func equationView(in view: UIView) -> LatexEquationUIView? {
            if let equation = view as? LatexEquationUIView { return equation }
            return view.subviews.lazy.compactMap(equationView).first
        }
        let equation = try #require(equationView(in: textView))
        #expect(equation.accessibilityLabel == "수식: E = mc^2")
        window.isHidden = true
    }

    @Test("수식 원문 전환은 surrogate 중간 caret을 유효한 UTF-16 경계로 맞춘다")
    @MainActor
    func equationSourceTransitionAlignsUnicodeCaret() {
        let block = EditorBlock(kind: .equation, text: "😀x")
        var reportedSelection: NSRange?
        let editor = BlockDocumentTextEditor(
            blocks: [block],
            selection: nil,
            canUndo: false,
            canRedo: false,
            onReplaceText: { _, _ in nil },
            onSelectionChange: { reportedSelection = $0 },
            onToolbarAction: { _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.attributedText = MarkdownStyler.styledDocument([block])
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = view.text
        coordinator.lastBlocks = [block]
        coordinator.lastEditingEquationIDs = []

        view.selectedRange = NSRange(location: 1, length: 0)
        coordinator.textViewDidChangeSelection(view)

        #expect(view.text == block.text)
        #expect(view.selectedRange == NSRange(location: 0, length: 0))
        #expect(reportedSelection == NSRange(location: 0, length: 0))
    }

    @Test("코드 블록은 리터럴이고 비활성 수식 블록은 attachment로 표시한다")
    func codeStaysLiteralAndEquationUsesAttachment() {
        let code = EditorBlock(
            kind: .code(language: "swift"),
            text: #"let value = "**literal** `code` $x$""#
        )
        let equation = EditorBlock(kind: .equation, text: #"**literal** + $x$"#)

        let styledCode = MarkdownStyler.styledDocument([code])
        let codeFont = styledCode.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(styledCode.string == code.text)
        #expect(codeFont?.pointSize ?? 0 > 1)
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
        #expect(styledCode.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)

        let styledEquation = MarkdownStyler.styledDocument([equation])
        #expect(styledEquation.length == equation.text.utf16.count)
        #expect(styledEquation.attribute(.attachment, at: 0, effectiveRange: nil) != nil)

        let editingEquation = MarkdownStyler.styledDocument(
            [equation],
            editingEquationIDs: [equation.id]
        )
        #expect(editingEquation.string == equation.text)
        #expect(editingEquation.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
    }

    @Test("접근성 Dynamic Type은 코드·수식·인라인 코드 글꼴을 확대한다")
    func dynamicTypeScalesMonospacedFonts() throws {
        let code = EditorBlock(kind: .code(language: "swift"), text: "let x = 1")
        let equation = EditorBlock(kind: .equation, text: "x + y")
        let paragraph = EditorBlock(markdown: "`inline`")
        let model = BlockEditorModel(blocks: [code, equation, paragraph])
        let normalTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let normal = MarkdownStyler.styledDocument(
            model.blocks,
            editingEquationIDs: [equation.id],
            traitCollection: normalTraits
        )
        let accessibility = MarkdownStyler.styledDocument(
            model.blocks,
            editingEquationIDs: [equation.id],
            traitCollection: accessibilityTraits
        )

        func font(
            in document: NSAttributedString,
            blockID: UUID,
            offset: Int = 0
        ) throws -> UIFont {
            let range = try #require(model.documentRange(for: blockID))
            return try #require(
                document.attribute(.font, at: range.location + offset, effectiveRange: nil)
                    as? UIFont
            )
        }

        for (blockID, offset) in [(code.id, 0), (equation.id, 0), (paragraph.id, 1)] {
            let normalFont = try font(in: normal, blockID: blockID, offset: offset)
            let accessibilityFont = try font(
                in: accessibility,
                blockID: blockID,
                offset: offset
            )
            #expect(accessibilityFont.pointSize > normalFont.pointSize)
        }
    }

    @Test("IME marked text는 조합 중 모델에 전달하지 않고 확정 시 한 번만 전달한다")
    @MainActor
    func markedTextCommitsOneReplacement() {
        let block = EditorBlock(kind: .paragraph, text: "가")
        var replacements: [(range: NSRange, text: String)] = []
        let editor = BlockDocumentTextEditor(
            blocks: [block],
            selection: NSRange(location: 1, length: 0),
            canUndo: false,
            canRedo: false,
            onReplaceText: { range, text in
                replacements.append((range, text))
                return NSRange(location: range.location + text.utf16.count, length: 0)
            },
            onSelectionChange: { _ in },
            onToolbarAction: { _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.text = block.text
        view.selectedRange = NSRange(location: 1, length: 0)
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = block.text

        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(view)
        #expect(view.markedTextRange != nil)
        #expect(replacements.isEmpty)

        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(view)
        #expect(view.markedTextRange != nil)
        #expect(replacements.isEmpty)

        view.unmarkText()
        coordinator.textViewDidChange(view)

        #expect(view.markedTextRange == nil)
        #expect(replacements.count == 1)
        #expect(replacements.first?.range == NSRange(location: 1, length: 0))
        #expect(replacements.first?.text == "한")
        #expect(view.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("IME는 반복 문자 앞에서도 실제 조합 시작 range와 caret을 보존한다")
    @MainActor
    func markedTextPreservesAmbiguousInsertionRange() {
        let block = EditorBlock(kind: .paragraph, text: "가가")
        var replacement: (range: NSRange, text: String)?
        let editor = BlockDocumentTextEditor(
            blocks: [block],
            selection: NSRange(location: 0, length: 0),
            canUndo: false,
            canRedo: false,
            onReplaceText: { range, text in
                replacement = (range, text)
                return NSRange(location: range.location + text.utf16.count, length: 0)
            },
            onSelectionChange: { _ in },
            onToolbarAction: { _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.text = block.text
        view.selectedRange = NSRange(location: 0, length: 0)
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = block.text

        view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(view)
        #expect(view.markedTextRange != nil)
        #expect(replacement == nil)

        view.unmarkText()
        coordinator.textViewDidChange(view)

        #expect(replacement?.range == NSRange(location: 0, length: 0))
        #expect(replacement?.text == "가")
        #expect(view.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("Coordinator는 반복 개행에서도 UITextView의 실제 편집 range를 전달한다")
    @MainActor
    func coordinatorUsesTextViewEditRange() {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .bulletedList, text: ""),
        ])
        var replacementRange: NSRange?
        let editor = BlockDocumentTextEditor(
            blocks: model.blocks,
            selection: NSRange(location: 0, length: 0),
            canUndo: false,
            canRedo: false,
            onReplaceText: { range, replacement in
                replacementRange = range
                return model.replaceDocumentText(in: range, with: replacement)
            },
            onSelectionChange: { _ in },
            onToolbarAction: { _, _ in }
        )
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.text = "\n"
        view.selectedRange = NSRange(location: 0, length: 0)
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = view.text

        let delegate = coordinator as UITextViewDelegate
        _ = delegate.textView?(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementText: "\n"
        )
        view.text = "\n\n"
        view.selectedRange = NSRange(location: 1, length: 0)
        coordinator.textViewDidChange(view)

        #expect(replacementRange == NSRange(location: 0, length: 0))
        #expect(model.blocks.first == EditorBlock(id: id, kind: .paragraph, text: ""))
        #expect(model.currentDocumentSelection == NSRange(location: 0, length: 0))
    }

    @Test("여러 블록을 가로지른 교체는 중간 블록을 제거하고 양끝을 병합한다")
    func replacesAcrossBlockBoundaries() throws {
        let firstID = UUID()
        let middleID = UUID()
        let lastID = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: firstID, kind: .heading(level: 2), text: "첫째"),
            EditorBlock(id: middleID, kind: .quote, text: "둘째"),
            EditorBlock(id: lastID, kind: .paragraph, text: "셋째"),
        ])
        let firstRange = try #require(model.documentRange(for: firstID))
        let lastRange = try #require(model.documentRange(for: lastID))
        let selection = NSRange(
            location: firstRange.location + 1,
            length: lastRange.location + 1 - firstRange.location - 1
        )

        let result = model.replaceDocumentText(in: selection, with: "X")

        #expect(result != nil)
        #expect(model.blocks.map(\.text) == ["첫X째", ""])
        #expect(model.blocks[0].id == firstID)
        #expect(model.blocks[0].kind == .heading(level: 2))
        #expect(!model.blocks.contains { $0.id == middleID || $0.id == lastID })
    }

    @Test("일반 줄바꿈은 새 블록이고 코드 줄바꿈은 같은 블록이다")
    func distinguishesBlockBreakFromCodeSoftBreak() throws {
        let paragraphID = UUID()
        let codeID = UUID()
        var paragraphModel = BlockEditorModel(blocks: [
            EditorBlock(id: paragraphID, kind: .paragraph, text: "앞뒤"),
        ])
        var codeModel = BlockEditorModel(blocks: [
            EditorBlock(id: codeID, kind: .code(language: "swift"), text: "let x"),
        ])

        let paragraphRange = try #require(paragraphModel.documentRange(for: paragraphID))
        let paragraphSelection = paragraphModel.replaceDocumentText(
            in: NSRange(location: paragraphRange.location + 1, length: 0),
            with: "\n"
        )
        let codeRange = try #require(codeModel.documentRange(for: codeID))
        let codeSelection = codeModel.replaceDocumentText(
            in: NSRange(location: codeRange.location + 3, length: 0),
            with: "\n"
        )

        #expect(paragraphModel.blocks.map(\.text) == ["앞", "뒤", ""])
        #expect(paragraphModel.blocks[0].id == paragraphID)
        #expect(paragraphSelection?.location == 2)
        #expect(codeModel.blocks.map(\.text) == ["let\n x", ""])
        #expect(codeModel.blocks[0].id == codeID)
        #expect(codeSelection?.location == 4)
    }

    @Test("연속 문서 Enter는 빈 목록을 같은 ID의 문단으로 바꾼다")
    func documentEnterExitsEmptyList() throws {
        let id = UUID()
        var model = BlockEditorModel(blocks: [
            EditorBlock(id: id, kind: .bulletedList, text: ""),
        ])

        let selection = model.replaceDocumentText(
            in: NSRange(location: 0, length: 0),
            with: "\n"
        )

        #expect(model.blocks.first == EditorBlock(id: id, kind: .paragraph, text: ""))
        #expect(selection == NSRange(location: 0, length: 0))
    }

    @Test("연속 문서 Backspace는 블록 시작의 서식 변환과 코드 경계를 보존한다")
    func documentBackspaceUsesBlockBoundaryRules() throws {
        let paragraphID = UUID()
        let headingID = UUID()
        var headingModel = BlockEditorModel(blocks: [
            EditorBlock(id: paragraphID, kind: .paragraph, text: "앞"),
            EditorBlock(id: headingID, kind: .heading(level: 2), text: "제목"),
        ])
        let headingRange = try #require(headingModel.documentRange(for: headingID))

        let headingSelection = headingModel.replaceDocumentText(
            in: NSRange(location: headingRange.location - 1, length: 1),
            with: ""
        )

        #expect(headingModel.blocks[1] == EditorBlock(
            id: headingID,
            kind: .paragraph,
            text: "제목"
        ))
        #expect(headingSelection == NSRange(location: headingRange.location, length: 0))

        let codeID = UUID()
        let followingID = UUID()
        var codeModel = BlockEditorModel(blocks: [
            EditorBlock(id: codeID, kind: .code(language: "swift"), text: "let x"),
            EditorBlock(id: followingID, kind: .paragraph, text: "다음"),
        ])
        let followingRange = try #require(codeModel.documentRange(for: followingID))
        let before = codeModel.blocks

        let codeBoundarySelection = codeModel.replaceDocumentText(
            in: NSRange(location: followingRange.location - 1, length: 1),
            with: ""
        )

        #expect(codeModel.blocks == before)
        #expect(codeBoundarySelection == NSRange(location: followingRange.location - 1, length: 0))
    }

    @Test("전체 선택 교체는 하나의 일반 문단과 후속 빈 문단을 만든다")
    func selectAllReplacementCreatesParagraph() {
        var model = BlockEditorModel(blocks: [
            EditorBlock(kind: .heading(level: 1), text: "제목"),
            EditorBlock(kind: .bulletedList, text: "항목"),
        ])

        let selection = model.replaceDocumentText(
            in: NSRange(location: 0, length: model.documentText.utf16.count),
            with: "새 문서"
        )

        #expect(model.blocks.map(\.text) == ["새 문서", ""])
        #expect(model.blocks[0].kind == .paragraph)
        #expect(selection == NSRange(location: 4, length: 0))
    }

    @Test("여러 블록 selection은 undo와 redo에서 전역 range로 복원된다")
    func historyRestoresCrossBlockDocumentSelection() {
        var model = BlockEditorModel(blocks: [
            EditorBlock(kind: .paragraph, text: "앞"),
            EditorBlock(kind: .paragraph, text: "뒤"),
        ])
        let before = NSRange(location: 0, length: 3)
        model.updateDocumentSelection(before)

        let replacementSelection = model.replaceDocumentText(in: before, with: "새")

        #expect(replacementSelection == NSRange(location: 1, length: 0))
        #expect(model.currentDocumentSelection == NSRange(location: 1, length: 0))
        let didUndo = model.undo()
        #expect(didUndo)
        #expect(model.documentText == "앞\n뒤\n")
        #expect(model.currentDocumentSelection == before)
        let didRedo = model.redo()
        #expect(didRedo)
        #expect(model.documentText == "새\n")
        #expect(model.currentDocumentSelection == NSRange(location: 1, length: 0))
    }

    @Test("Markdown 인라인 마커는 plain text와 의미 범위로 파싱된다")
    func parsesMarkdownInlineMarkersIntoSemanticRanges() {
        let source = #"**굵게** *기울임* ~~취소~~ `코드`"#

        let block = EditorBlock(markdown: source)
        let model = BlockEditorModel(markdown: source)

        #expect(block.kind == .paragraph)
        #expect(block.text == "굵게 기울임 취소 코드")
        #expect(!block.text.contains("**"))
        #expect(block.inlineMarks.map(\.format) == [.bold, .italic, .strikethrough, .code])
        #expect(block.inlineMarks.map(\.range) == [
            NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 3),
            NSRange(location: 7, length: 2),
            NSRange(location: 10, length: 2),
        ])
        #expect(model.documentText == "굵게 기울임 취소 코드\n")
    }

    @Test("인라인 마크 범위는 Character가 아닌 UTF-16 offset을 사용한다")
    func storesInlineMarkRangesAsUTF16Offsets() {
        let block = EditorBlock(markdown: #"😀 **굵게**"#)

        #expect(block.text == "😀 굵게")
        #expect(block.inlineMarks.map(\.range) == [NSRange(location: 3, length: 2)])
    }

    @Test("의미 인라인 마크는 canonical Markdown으로 재직렬화된다")
    func reserializesSemanticInlineMarksToMarkdown() {
        let source = #"**굵게** *기울임* ~~취소~~ `코드`"#

        let block = EditorBlock(markdown: source)

        #expect(block.markdown == #"**굵게** <em>기울임</em> ~~취소~~ `코드`"#)
    }

    @Test("교차 인라인 마크도 Markdown 왕복 시 의미 범위를 보존한다")
    func crossingInlineMarksRoundTrip() {
        let original = EditorBlock(
            text: "abcd",
            inlineMarks: [
                InlineMark(format: .bold, range: NSRange(location: 0, length: 3)),
                InlineMark(format: .italic, range: NSRange(location: 1, length: 3)),
            ]
        )

        let reparsed = EditorBlock(markdown: original.markdown)

        #expect(reparsed.text == original.text)
        #expect(reparsed.inlineMarks == original.inlineMarks)
    }

    @Test("인라인 코드는 겹친 일반 서식보다 우선한다")
    func inlineCodeClipsOverlappingMarks() {
        let block = EditorBlock(
            text: "abcd",
            inlineMarks: [
                InlineMark(format: .bold, range: NSRange(location: 0, length: 4)),
                InlineMark(format: .code, range: NSRange(location: 1, length: 2)),
            ]
        )

        #expect(block.inlineMarks == [
            InlineMark(format: .bold, range: NSRange(location: 0, length: 1)),
            InlineMark(format: .code, range: NSRange(location: 1, length: 2)),
            InlineMark(format: .bold, range: NSRange(location: 3, length: 1)),
        ])
        #expect(EditorBlock(markdown: block.markdown).inlineMarks == block.inlineMarks)
    }

    @Test("plain Markdown delimiter와 인라인 LaTeX underscore를 리터럴로 보존한다")
    func literalDelimitersRoundTrip() {
        let plain = EditorBlock(text: #"a_b_c **literal** ~~literal~~ `literal` <em>literal</em>"#)
        let plainRoundTrip = EditorBlock(markdown: plain.markdown)
        #expect(plainRoundTrip.text == plain.text)
        #expect(plainRoundTrip.inlineMarks.isEmpty)

        let latex = #"앞 $x_{i} + y_{j}$, $a*b + c*d$ 뒤 \(a_b * c_d\)"#
        let latexBlock = EditorBlock(markdown: latex)
        #expect(latexBlock.text == latex)
        #expect(latexBlock.inlineMarks.isEmpty)
        #expect(EditorBlock(markdown: latexBlock.markdown).text == latex)

        let markedLatex = EditorBlock(
            text: "앞 $x_i$ 뒤",
            inlineMarks: [
                InlineMark(format: .bold, range: NSRange(location: 3, length: 3)),
            ]
        )
        #expect(markedLatex.inlineMarks.isEmpty)
        #expect(EditorBlock(markdown: markedLatex.markdown).text == markedLatex.text)
    }

    @Test("인라인 코드 안의 backtick을 escape해 왕복한다")
    func inlineCodeBacktickRoundTrip() {
        let block = EditorBlock(
            text: "a`b",
            inlineMarks: [
                InlineMark(format: .code, range: NSRange(location: 0, length: 3)),
            ]
        )
        let reparsed = EditorBlock(markdown: block.markdown)
        #expect(reparsed.text == block.text)
        #expect(reparsed.inlineMarks == block.inlineMarks)

        let literalLatexCode = EditorBlock(markdown: #"`$x_i$`"#)
        #expect(literalLatexCode.text == "$x_i$")
        #expect(literalLatexCode.inlineMarks == [
            InlineMark(format: .code, range: NSRange(location: 0, length: 5)),
        ])
        let reparsedLatexCode = EditorBlock(markdown: literalLatexCode.markdown)
        #expect(reparsedLatexCode.kind == literalLatexCode.kind)
        #expect(reparsedLatexCode.text == literalLatexCode.text)
        #expect(reparsedLatexCode.inlineMarks == literalLatexCode.inlineMarks)
    }

    @Test("인라인 LaTeX는 수식 노드가 아닌 일반 텍스트로 보존된다")
    func keepsInlineLatexAsPlainText() {
        let source = #"앞 $x^2$ 뒤 \(\alpha + \beta\)"#

        let block = EditorBlock(markdown: source)

        #expect(block.kind == .paragraph)
        #expect(block.text == source)
        #expect(block.inlineMarks.isEmpty)
        #expect(block.markdown == source)
    }

    @Test("수식 블록은 구분자 안의 source를 손실 없이 보존한다")
    func preservesEquationBlockSource() {
        let source = "\\[\n  x^2 + y^2  \n\\]"

        let block = EditorBlock(markdown: source)

        #expect(block.kind == .equation)
        #expect(block.text == "\n  x^2 + y^2  \n")
        #expect(block.markdown == source)
    }
}

/// UIKit 챗 데모의 셀 수명 회귀 (빠른 스크롤 왕복에서 빈 버블).
///
/// 화면 밖으로 나간 셀은 `prepareForReuse` 없이 reuse pool에 머물다가 다음 dequeue
/// 때에야 정리된다. 그 사이 같은 메시지가 다른 셀에 attach되면 캐시된 뷰가 새 셀로
/// 이사하는데, 이후 pooled 셀의 늦은 `prepareForReuse`가 뷰를 무조건
/// `removeFromSuperview`하면 화면에 보이는 셀에서 뷰를 뜯어내 빈 버블이 남는다.
@MainActor
@Suite struct UIKitChatCellReuseTests {

    @Test func stalePrepareForReuseDoesNotStealMovedMessageView() {
        let message = ChatMessage.answer("케이스", "재사용 검증 본문")
        let cache = AssistantMessageViewCache()
        let entry = cache.entry(for: message)
        let configuration = UIKitChatConfiguration()

        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let cellX = AssistantMessageCell(frame: frame)
        cellX.configure(message, configuration: configuration, entry: entry)
        #expect(entry.view.isDescendant(of: cellX), "첫 셀에 뷰가 붙는다")

        // cellX가 화면 밖(reuse pool)에 있는 동안 같은 메시지가 다른 셀에 붙는다.
        let cellY = AssistantMessageCell(frame: frame)
        cellY.configure(message, configuration: configuration, entry: entry)
        #expect(entry.view.isDescendant(of: cellY), "뷰는 최신 셀로 이사한다")

        // pooled cellX가 다른 메시지용으로 재-dequeue될 때의 늦은 정리.
        cellX.prepareForReuse()

        #expect(
            entry.view.isDescendant(of: cellY),
            "늦은 prepareForReuse가 이사한 뷰를 화면의 셀에서 뜯어내면 안 된다"
        )
        #expect(entry.view.superview != nil)
    }

    /// 뷰가 아직 자기 셀에 있을 때의 prepareForReuse는 기존대로 뷰를 떼어낸다.
    @Test func prepareForReuseDetachesOwnedView() {
        let message = ChatMessage.answer("케이스", "정상 detach 본문")
        let cache = AssistantMessageViewCache()
        let entry = cache.entry(for: message)

        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(message, configuration: UIKitChatConfiguration(), entry: entry)
        #expect(entry.view.isDescendant(of: cell))

        cell.prepareForReuse()
        #expect(entry.view.superview == nil, "자기 셀의 뷰는 정상적으로 떼어낸다")
    }
}
