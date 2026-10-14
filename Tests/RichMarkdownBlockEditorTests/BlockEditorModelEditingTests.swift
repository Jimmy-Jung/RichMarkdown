// Created by JunyoungJung on 2026-10-14.

import Foundation
import RichMarkdown
import Testing
import UIKit
@testable import RichMarkdownBlockEditor

@Suite("블록 편집 모델 — 삽입·블록 내부 교체·이동·selection 기록")
struct BlockEditorModelEditingTests {
    @Test("insert(after:)는 지정 블록 바로 뒤에 빈 블록을 만들고 caret을 옮기며 undo로 되돌린다")
    func insertAfterBlock() throws {
        let first = EditorBlock(text: "첫째")
        var model = BlockEditorModel(blocks: [first, EditorBlock(text: "둘째")])

        let inserted = model.insert(after: first.id, kind: .toDo(isChecked: false))
        let selection = try #require(inserted)

        #expect(model.blocks.map(\.text) == ["첫째", "", "둘째", ""])
        #expect(model.blocks[1].kind == .toDo(isChecked: false))
        #expect(selection == BlockSelection(blockID: model.blocks[1].id, range: NSRange(location: 0, length: 0)))
        let undone = model.undo()
        #expect(undone)
        #expect(model.blocks.map(\.text) == ["첫째", "둘째", ""])
    }

    @Test("기준 블록이 없거나 찾을 수 없으면 끝의 빈 문단 앞(마지막 내용 뒤)에 삽입한다",
          arguments: [nil, UUID()] as [UUID?])
    func insertWithoutAnchorAppendsBeforeTrailingParagraph(anchor: UUID?) throws {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "첫째"), EditorBlock(text: "둘째")])

        let inserted = model.insert(after: anchor, kind: .quote)
        let selection = try #require(inserted)

        #expect(model.blocks.map(\.text) == ["첫째", "둘째", "", ""])
        #expect(model.blocks.map(\.kind) == [.paragraph, .paragraph, .quote, .paragraph])
        #expect(selection.blockID == model.blocks[2].id)
    }

    @Test("블록 내부 교체는 뒤쪽 인라인 마크를 밀고 겹친 마크는 교체분까지 넓히며 undo로 되돌린다")
    func replaceTextShiftsAndExtendsInlineMarks() throws {
        let block = EditorBlock(
            text: "앞 굵게 뒤",
            inlineMarks: [InlineMark(format: .bold, range: NSRange(location: 2, length: 2))]
        )
        var model = BlockEditorModel(blocks: [block])

        let prefixResult = model.replaceText(id: block.id, range: NSRange(location: 0, length: 1), with: "맨 앞")
        let prefixed = try #require(prefixResult)
        #expect(model.blocks[0].text == "맨 앞 굵게 뒤")
        #expect(model.blocks[0].inlineMarks == [InlineMark(format: .bold, range: NSRange(location: 4, length: 2))])
        #expect(prefixed == BlockSelection(blockID: block.id, range: NSRange(location: 3, length: 0)))

        // "굵게"의 "게"를 바꾸면 굵게 마크가 교체 문자열까지 덮는다.
        let extended = model.replaceText(id: block.id, range: NSRange(location: 5, length: 1), with: "은 글씨")
        #expect(extended != nil)
        #expect(model.blocks[0].markdown == "맨 앞 **굵은 글씨** 뒤")

        let undid = [model.undo(), model.undo()]
        #expect(undid == [true, true])
        #expect(model.blocks[0] == block)
    }

    @Test("없는 블록 ID로 교체하면 문서와 undo 기록을 바꾸지 않는다")
    func replaceTextWithUnknownIDIsRejected() {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "본문")])
        let original = model.blocks

        let result = model.replaceText(id: UUID(), range: NSRange(location: 0, length: 0), with: "x")
        #expect(result == nil)
        #expect(model.blocks == original)
        #expect(!model.canUndo)
    }

    @Test("move(id:toPositionOf:)는 내용 블록끼리만 옮기고 자기 자신·끝의 빈 문단·없는 ID는 거절한다")
    func moveToPositionOfTarget() {
        let first = EditorBlock(text: "가")
        let second = EditorBlock(text: "나")
        let third = EditorBlock(text: "다")
        var model = BlockEditorModel(blocks: [first, second, third])
        let trailing = model.blocks[3].id

        let moved = model.move(id: first.id, toPositionOf: third.id)
        #expect(moved)
        #expect(model.blocks.map(\.text) == ["나", "다", "가", ""])
        let rejected = [
            model.move(id: first.id, toPositionOf: first.id),
            model.move(id: first.id, toPositionOf: trailing),
            model.move(id: UUID(), toPositionOf: second.id),
        ]
        #expect(rejected == [false, false, false])
        #expect(model.blocks.map(\.text) == ["나", "다", "가", ""])
        let undone = model.undo()
        #expect(undone)
        #expect(model.blocks.map(\.text) == ["가", "나", "다", ""])
    }

    @Test("undo·redo에 넘긴 현재 selection은 반대 방향 기록에 남아 되돌아올 때 복원된다")
    func undoRedoRecordCurrentSelection() throws {
        let block = EditorBlock(text: "본문")
        var model = BlockEditorModel(blocks: [block])
        let edited = model.replaceText(id: block.id, range: NSRange(location: 2, length: 0), with: " 추가")
        #expect(edited != nil)
        #expect(model.canUndo && !model.canRedo)

        let afterEdit = BlockSelection(blockID: block.id, range: NSRange(location: 1, length: 2))
        let undone = model.undo(currentSelection: afterEdit)
        #expect(undone)
        #expect(model.blocks[0].text == "본문")
        #expect(model.canRedo)
        let redone = model.redo()
        #expect(redone)
        #expect(model.blocks[0].text == "본문 추가")
        #expect(model.currentSelection == afterEdit)

        let beforeRedo = BlockSelection(blockID: block.id, range: NSRange(location: 0, length: 0))
        let steps = [model.undo(), model.redo(currentSelection: beforeRedo), model.undo()]
        #expect(steps == [true, true, true])
        #expect(model.currentSelection == beforeRedo)
    }

    @Test("렌더된 caret은 문단·제목에서만 지원한다",
          arguments: [
              (EditorBlockKind.paragraph, true), (.heading(level: 2), true),
              (.bulletedList, false), (.numberedList, false), (.toDo(isChecked: true), false),
              (.quote, false), (.code(language: "swift"), false), (.equation, false),
          ])
    func renderedCaretSupport(kind: EditorBlockKind, expected: Bool) {
        #expect(kind.supportsRenderedCaret == expected)
    }
}

@MainActor
@Suite("다음 입력 속성")
struct TypingAttributesTests {
    @Test("블록이 없으면 빈 문단의 본문 글꼴과 장식 없는 속성을 쓴다")
    func missingBlockFallsBackToParagraph() throws {
        let attributes = MarkdownStyler.typingAttributes(for: nil)
        let font = try #require(attributes[.font] as? UIFont)
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)

        #expect(font == RichMarkdownTheme.default.bodyFont.resolvedUIFont(compatibleWith: nil))
        #expect(attributes[.toDoCheckbox] == nil)
        #expect(attributes[.blockQuoteBar] == nil)
        #expect(attributes[.strikethroughStyle] == nil)
        #expect(paragraph.headIndent == 0)
    }

    @Test("완료 할 일은 체크 상태·취소선·흐린 색과 들여쓰기를 다음 입력에 넘긴다")
    func checkedToDoCarriesDecorationAndIndent() throws {
        let block = EditorBlock(kind: .toDo(isChecked: true), text: "", indentLevel: 1)
        let attributes = MarkdownStyler.typingAttributes(for: block)
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)

        #expect((attributes[.toDoCheckbox] as? ToDoCheckboxStyle)?.isChecked == true)
        #expect(attributes[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attributes[.foregroundColor] as? UIColor == UIColor.secondaryLabel)
        // 박스 자리(28) + 들여쓰기 1단(20).
        #expect(paragraph.firstLineHeadIndent == ToDoCheckboxMetrics.textIndent + 20)
        #expect(paragraph.headIndent == ToDoCheckboxMetrics.textIndent + 20)
    }

    @Test("코드 블록은 고정폭 글꼴과 주입한 정렬, 인용은 세로 바 attribute를 넘긴다")
    func codeAndQuoteTypingAttributes() throws {
        let code = MarkdownStyler.typingAttributes(
            for: EditorBlock(kind: .code(language: "swift"), text: ""),
            alignment: BlockAlignmentConfiguration(code: .right)
        )
        let codeParagraph = try #require(code[.paragraphStyle] as? NSParagraphStyle)
        let codeFont = try #require(code[.font] as? UIFont)
        let quote = MarkdownStyler.typingAttributes(for: EditorBlock(kind: .quote, text: ""))

        #expect(codeParagraph.alignment == .right)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #expect(quote[.blockQuoteBar] is QuoteBarStyle)
        #expect((quote[.paragraphStyle] as? NSParagraphStyle)?.headIndent == 16)
    }
}
