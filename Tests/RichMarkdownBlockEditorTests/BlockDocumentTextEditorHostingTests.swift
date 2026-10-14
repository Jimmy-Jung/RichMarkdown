// Created by JunyoungJung on 2026-10-14.

import Foundation
import RichMarkdown
import SwiftUI
import Testing
import UIKit
@testable import RichMarkdownBlockEditor

/// 데모 앱(`BlockEditorDemoView`)처럼 모델을 SwiftUI 상태로 소유하고 에디터 콜백을 기록한다.
@MainActor
private final class EditorStore: ObservableObject {
    @Published var model: BlockEditorModel
    @Published var theme: RichMarkdownTheme = .default
    private(set) var replacements: [(range: NSRange, text: String)] = []
    private(set) var selections: [NSRange] = []
    private(set) var actions: [(action: EditorToolbarAction, range: NSRange)] = []
    private(set) var pastedBlocks: [[EditorBlock]] = []

    init(_ model: BlockEditorModel) {
        self.model = model
    }

    func replaceText(in range: NSRange, with text: String) -> NSRange? {
        replacements.append((range, text))
        return model.replaceDocumentText(in: range, with: text)
    }

    func updateSelection(_ range: NSRange) {
        selections.append(range)
        model.updateDocumentSelection(range)
    }

    func replaceBlocks(in range: NSRange, with blocks: [EditorBlock]) -> NSRange? {
        pastedBlocks.append(blocks)
        return model.replaceDocumentBlocks(in: range, with: blocks)
    }

    /// 데모 앱 `perform(_:selection:)`에서 이 테스트가 쓰는 분기만 옮겼다.
    func perform(_ action: EditorToolbarAction, selection: NSRange) {
        actions.append((action, selection))
        if case .done = action { return }
        model.updateDocumentSelection(selection)
        guard let active = model.blockSelection(for: selection) else { return }
        switch action {
        case let .transform(kind): model.transform(id: active.blockID, to: kind)
        case .undo: model.undo()
        case .redo: model.redo()
        default: break
        }
    }
}

/// 에디터가 넘긴 명령 전달 함수와 `update` 호출을 기록하는 키보드 액세서리.
@MainActor
private final class RecordingAccessory: UIView, BlockEditorInputAccessory {
    var send: ((EditorToolbarAction) -> Void)?
    private(set) var states: [(kind: EditorBlockKind, canUndo: Bool, canRedo: Bool)] = []

    func update(kind: EditorBlockKind, canUndo: Bool, canRedo: Bool) {
        states.append((kind, canUndo, canRedo))
    }
}

private struct EditorHost: View {
    @ObservedObject var store: EditorStore
    let accessory: RecordingAccessory

    var body: some View {
        BlockDocumentTextEditor(
            blocks: store.model.blocks,
            selection: store.model.currentDocumentSelection,
            canUndo: store.model.canUndo,
            canRedo: store.model.canRedo,
            onReplaceText: { store.replaceText(in: $0, with: $1) },
            onSelectionChange: { store.updateSelection($0) },
            onToolbarAction: { store.perform($0, selection: $1) },
            onReplaceDocumentBlocks: { store.replaceBlocks(in: $0, with: $1) },
            theme: store.theme,
            sourceMarkdown: store.model.markdown,
            makeInputAccessory: { send in
                accessory.send = send
                return accessory
            }
        )
    }
}

/// 실제 `UIHostingController` + key window에 올린 에디터.
@MainActor
private struct HostedEditor {
    let store: EditorStore
    let accessory: RecordingAccessory
    let window: UIWindow
    let textView: BlockDocumentUITextView

    static func make(_ model: BlockEditorModel) async throws -> HostedEditor {
        let store = EditorStore(model)
        let accessory = RecordingAccessory()
        let controller = UIHostingController(rootView: EditorHost(store: store, accessory: accessory))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await waitUntil { findTextView(in: controller.view) != nil }
        let textView = try #require(findTextView(in: controller.view))
        return HostedEditor(store: store, accessory: accessory, window: window, textView: textView)
    }

    /// SwiftUI가 상태 변경을 `updateUIView`까지 반영할 때까지 기다린다.
    func settle(line: Int = #line) async throws {
        try await Self.waitUntil(line: line) {
            textView.text == store.model.documentText
                && textView.fullDocumentBlocks == store.model.blocks
        }
        try await Task.sleep(for: .milliseconds(20))
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
    }

    static func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "SwiftUI가 제한 시간 안에 갱신해야 한다 (호출 줄: \(line))")
    }

    private static func findTextView(in view: UIView) -> BlockDocumentUITextView? {
        if let textView = view as? BlockDocumentUITextView { return textView }
        return view.subviews.lazy.compactMap(findTextView(in:)).first
    }
}

private func rgba(_ color: UIColor?) -> [CGFloat]? {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard let color, color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return [red, green, blue, alpha]
}

private func isClose(_ lhs: [CGFloat]?, _ rhs: [CGFloat]) -> Bool {
    guard let lhs, lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.01 }
}

private let tintedTheme = RichMarkdownTheme(textColor: Color(red: 0.8, green: 0.1, blue: 0.1))

@MainActor
@Suite("SwiftUI 블록 문서 편집기 호스팅", .serialized)
struct BlockDocumentTextEditorHostingTests {
    @Test("SwiftUI 호스팅은 블록을 하나의 TextKit 2 문서로 투영하고 편집 환경을 구성한다")
    func hostingProjectsBlocksAndConfiguresTextView() async throws {
        var model = BlockEditorModel(blocks: [
            EditorBlock(kind: .heading(level: 1), text: "제목"),
            EditorBlock(kind: .toDo(isChecked: false), text: "할 일"),
            EditorBlock(text: "본문"),
        ])
        // "제목\n할 일\n본문\n" — caret은 할 일 블록 안.
        model.updateDocumentSelection(NSRange(location: 4, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView

        #expect(textView.text == model.documentText)
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(textView.textLayoutManager != nil, "TextKit 2 문서여야 한다")
        #expect(textView.delegate is BlockDocumentTextEditor.Coordinator)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.textContainer.lineFragmentPadding == 0)
        #expect(textView.adjustsFontForContentSizeCategory)
        #expect(textView.accessibilityIdentifier == "blockDocumentTextView")
        #expect(textView.fullDocumentMarkdown == model.markdown)
        #expect(textView.fullDocumentBlocks == model.blocks)
        #expect(textView.inputAccessoryView === editor.accessory)
        // 툴바와 다음 입력 속성이 caret이 있는 할 일 블록을 따른다.
        #expect(editor.accessory.states.first?.kind == .toDo(isChecked: false))
        #expect(editor.accessory.states.last?.canUndo == false)
        #expect(textView.typingAttributes[.toDoCheckbox] is ToDoCheckboxStyle)
        let paragraph = try #require(textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(paragraph.headIndent == ToDoCheckboxMetrics.textIndent)
    }

    @Test("키보드 입력은 모델 전이 한 번으로 전달되고 undo는 문서·caret·툴바를 함께 되돌린다")
    func typingRoundTripsThroughModelAndUndo() async throws {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "본문")])
        model.updateDocumentSelection(NSRange(location: 2, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView

        textView.insertText("!")
        try await editor.settle()

        #expect(editor.store.replacements.count == 1)
        #expect(editor.store.replacements.first?.range == NSRange(location: 2, length: 0))
        #expect(editor.store.replacements.first?.text == "!")
        #expect(editor.store.model.blocks.first?.text == "본문!")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0))
        #expect(editor.accessory.states.last?.canUndo == true)

        let send = try #require(editor.accessory.send)
        send(.undo)
        try await editor.settle()

        #expect(editor.store.model.blocks.first?.text == "본문")
        #expect(textView.text == "본문\n")
        #expect(textView.selectedRange == NSRange(location: 2, length: 0), "undo는 편집 전 caret을 복원한다")
        #expect(editor.accessory.states.last?.canUndo == false)
        #expect(editor.accessory.states.last?.canRedo == true)
    }

    @Test("블록 종류와 테마 변경은 텍스트·caret을 유지한 채 글꼴과 색만 다시 칠한다")
    func kindAndThemeChangesRestyleInPlace() async throws {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "제목이 될 문장"), EditorBlock(text: "본문")])
        model.updateDocumentSelection(NSRange(location: 2, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView
        let originalText = textView.text
        let bodyFont = try #require(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)

        let send = try #require(editor.accessory.send)
        send(.transform(.heading(level: 1)))
        try await editor.settle()

        let headingFont = try #require(
            textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        #expect(textView.text == originalText)
        #expect(textView.selectedRange == NSRange(location: 2, length: 0))
        #expect(headingFont.pointSize > bodyFont.pointSize)
        #expect(editor.accessory.states.last?.kind == .heading(level: 1))
        #expect((textView.typingAttributes[.font] as? UIFont)?.pointSize == headingFont.pointSize)

        editor.store.theme = tintedTheme
        try await HostedEditor.waitUntil {
            isClose(
                rgba(textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor),
                [0.8, 0.1, 0.1, 1]
            )
        }
        #expect(textView.text == originalText)
        #expect(isClose(rgba(textView.typingAttributes[.foregroundColor] as? UIColor), [0.8, 0.1, 0.1, 1]))
    }

    @Test("한글 조합 중에는 SwiftUI 갱신과 툴바 명령이 조합 텍스트를 건드리지 않고 확정 후 반영된다")
    func compositionDefersExternalUpdatesAndToolbar() async throws {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "본문")])
        model.updateDocumentSelection(NSRange(location: 2, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView
        let send = try #require(editor.accessory.send)

        textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
        editor.store.theme = tintedTheme
        try await Task.sleep(for: .milliseconds(50))
        editor.window.layoutIfNeeded()
        send(.format(.bold))

        #expect(textView.markedTextRange != nil)
        #expect(textView.text == "본문ㅎ\n")
        #expect(editor.store.replacements.isEmpty)
        #expect(editor.store.actions.isEmpty, "조합 중 툴바 명령은 모델에 전달하지 않는다")

        textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        textView.unmarkText()
        try await editor.settle()

        #expect(editor.store.replacements.count == 1)
        #expect(editor.store.replacements.first?.range == NSRange(location: 2, length: 0))
        #expect(editor.store.replacements.first?.text == "한")
        #expect(editor.store.model.blocks.first?.text == "본문한")
        try await HostedEditor.waitUntil {
            isClose(
                rgba(textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor),
                [0.8, 0.1, 0.1, 1]
            )
        }
    }

    @Test("사용자 caret 이동은 모델 selection·툴바 블록 종류·다음 입력 속성을 함께 갱신한다")
    func caretMovementSyncsModelToolbarAndTypingAttributes() async throws {
        var model = BlockEditorModel(blocks: [
            EditorBlock(kind: .heading(level: 1), text: "제목"),
            EditorBlock(kind: .quote, text: "인용"),
        ])
        model.updateDocumentSelection(NSRange(location: 0, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView

        // "제목\n인용\n" — offset 4는 인용 블록 안.
        textView.selectedRange = NSRange(location: 4, length: 0)
        try await HostedEditor.waitUntil { editor.accessory.states.last?.kind == .quote }

        #expect(editor.store.selections.last == NSRange(location: 4, length: 0))
        #expect(editor.store.model.currentDocumentSelection == NSRange(location: 4, length: 0))
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(textView.typingAttributes[.blockQuoteBar] is QuoteBarStyle)
    }

    @Test("모델이 바꾼 selection은 caret에 적용되고 선택 콜백으로 되돌아오지 않는다")
    func modelSelectionAppliesWithoutFeedback() async throws {
        let editor = try await HostedEditor.make(BlockEditorModel(blocks: [EditorBlock(text: "본문입니다")]))
        defer { editor.close() }
        let reportedBefore = editor.store.selections.count

        editor.store.model.updateDocumentSelection(NSRange(location: 1, length: 3))
        try await HostedEditor.waitUntil {
            editor.textView.selectedRange == NSRange(location: 1, length: 3)
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(editor.store.selections.count == reportedBefore)
    }

    @Test("완료 명령은 키보드를 내리고 현재 selection과 함께 전달된다")
    func doneResignsFirstResponderAndForwardsSelection() async throws {
        var model = BlockEditorModel(blocks: [EditorBlock(text: "본문")])
        model.updateDocumentSelection(NSRange(location: 1, length: 0))
        let editor = try await HostedEditor.make(model)
        defer { editor.close() }
        let textView = editor.textView
        try #require(textView.becomeFirstResponder())

        let send = try #require(editor.accessory.send)
        send(.done)

        #expect(!textView.isFirstResponder)
        let forwarded = try #require(editor.store.actions.first)
        guard case .done = forwarded.action else {
            Issue.record("완료 명령이 아닌 \(forwarded.action)이 전달됐다")
            return
        }
        #expect(forwarded.range == NSRange(location: 1, length: 0))
    }

    @Test("전체 선택 복사는 Markdown 원문과 블록 payload를 싣고, 붙여넣기는 블록 종류를 그대로 복원한다")
    func wholeDocumentCopyPasteRoundTripsBlocks() async throws {
        let pasteboard = try #require(UIPasteboard(
            name: UIPasteboard.Name("RichMarkdownBlockEditorTests.\(UUID().uuidString)"),
            create: true
        ))
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let source = BlockEditorModel(markdown: "# 제목\n- [x] 완료\n> 인용")
        let sourceEditor = try await HostedEditor.make(source)
        defer { sourceEditor.close() }
        // 범위가 어긋나면 UIKit 기본 복사가 general pasteboard에 쓰므로 먼저 확인한다.
        sourceEditor.textView.pasteboard = pasteboard
        sourceEditor.textView.selectedRange = NSRange(location: 0, length: sourceEditor.textView.text.utf16.count)
        try #require(sourceEditor.textView.selectedRange.length == source.documentText.utf16.count)
        sourceEditor.textView.copy(nil)

        #expect(pasteboard.string == source.markdown)
        let data = try #require(pasteboard.data(
            forPasteboardType: BlockDocumentUITextView.blockDocumentPasteboardType
        ))
        let copied = try #require(BlockDocumentPasteboardPayload.decode(data))
        #expect(copied.map(\.kind) == source.blocks.map(\.kind))
        #expect(copied.map(\.text) == source.blocks.map(\.text))

        let target = try await HostedEditor.make(BlockEditorModel(markdown: "기존"))
        defer { target.close() }
        target.textView.pasteboard = pasteboard
        target.textView.selectedRange = NSRange(location: 0, length: target.textView.text.utf16.count)
        try #require(target.textView.selectedRange.length == target.store.model.documentText.utf16.count)
        target.textView.paste(nil)
        try await target.settle()

        #expect(target.store.pastedBlocks.count == 1)
        #expect(target.store.replacements.isEmpty, "plain text 교체 경로를 타지 않는다")
        #expect(target.store.model.blocks.map(\.kind) == source.blocks.map(\.kind))
        #expect(target.store.model.blocks.map(\.text) == source.blocks.map(\.text))
    }
}

@MainActor
@Suite("블록 문서 편집기 Coordinator 입력 브리지")
struct BlockDocumentTextEditorCoordinatorTests {
    private func makeEditor(
        blocks: [EditorBlock],
        selection: NSRange? = nil,
        onReplaceText: @escaping (NSRange, String) -> NSRange? = { _, _ in nil },
        onToolbarAction: @escaping (EditorToolbarAction, NSRange) -> Void = { _, _ in },
        onReplaceDocumentBlocks: ((NSRange, [EditorBlock]) -> NSRange?)? = nil
    ) -> BlockDocumentTextEditor {
        BlockDocumentTextEditor(
            blocks: blocks,
            selection: selection,
            canUndo: false,
            canRedo: false,
            onReplaceText: onReplaceText,
            onSelectionChange: { _ in },
            onToolbarAction: onToolbarAction,
            onReplaceDocumentBlocks: onReplaceDocumentBlocks
        )
    }

    @Test("범위 정보 없는 외부 변경은 공통 접두·접미를 뺀 UTF-16 교체 하나로 환원한다",
          arguments: [
              ("본문", "본문!", 2, 0, "!"),
              ("가나다", "가나나다", 2, 0, "나"),
              ("본문입니다", "본다", 1, 3, ""),
              ("a😀b", "a😀xb", 3, 0, "x"),
              ("👍", "👍🏽", 0, 2, "👍🏽"),
              ("", "새 문단", 0, 0, "새 문단"),
          ])
    func externalChangeWithoutDelegateRangeIsDiffed(
        old: String,
        new: String,
        location: Int,
        length: Int,
        replacement: String
    ) throws {
        var reported: [(range: NSRange, text: String)] = []
        let editor = makeEditor(blocks: [EditorBlock(text: old)], onReplaceText: { range, text in
            reported.append((range, text))
            return nil
        })
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.text = old
        view.delegate = coordinator
        coordinator.editingView = view
        coordinator.baselineText = old

        // 받아쓰기·자동 수정처럼 shouldChangeTextIn 없이 텍스트만 바뀐 상황.
        view.text = new
        coordinator.textViewDidChange(view)

        try #require(reported.count == 1)
        #expect(reported[0].range == NSRange(location: location, length: length))
        #expect(reported[0].text == replacement)
        let rebuilt = (old as NSString).replacingCharacters(in: reported[0].range, with: reported[0].text)
        #expect(rebuilt == new, "보고한 교체를 원문에 적용하면 새 텍스트가 되어야 한다")
    }

    @Test("편집 뷰가 없으면 툴바 명령은 SwiftUI selection, 그것도 없으면 문서 시작 range로 전달된다")
    func toolbarActionFallsBackToBindingSelection() {
        var ranges: [NSRange] = []
        let block = EditorBlock(text: "본문")
        let withSelection = makeEditor(
            blocks: [block],
            selection: NSRange(location: 1, length: 1),
            onToolbarAction: { _, range in ranges.append(range) }
        )
        let withoutSelection = makeEditor(
            blocks: [block],
            onToolbarAction: { _, range in ranges.append(range) }
        )

        withSelection.makeCoordinator().handleToolbarAction(.indent)
        withoutSelection.makeCoordinator().handleToolbarAction(.outdent)

        #expect(ranges == [NSRange(location: 1, length: 1), NSRange(location: 0, length: 0)])
    }

    @Test("한글 조합 중 블록 붙여넣기는 거절해 조합 텍스트와 블록 교체가 섞이지 않는다")
    func blockPasteIsRejectedDuringComposition() {
        var pasted: [[EditorBlock]] = []
        let editor = makeEditor(blocks: [EditorBlock(text: "본문")], onReplaceDocumentBlocks: { _, blocks in
            pasted.append(blocks)
            return NSRange(location: 0, length: 0)
        })
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.text = "본문"
        coordinator.editingView = view
        let blocks = [EditorBlock(kind: .quote, text: "인용")]

        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
        #expect(coordinator.replaceDocumentBlocks(in: NSRange(location: 0, length: 2), with: blocks) == nil)
        #expect(pasted.isEmpty)

        view.unmarkText()
        #expect(coordinator.replaceDocumentBlocks(in: NSRange(location: 0, length: 3), with: blocks) != nil)
        #expect(pasted.count == 1)
    }
}

@Suite("블록 문서 pasteboard payload")
struct BlockDocumentPasteboardPayloadTests {
    private func payloadJSON(_ blocks: [EditorBlock]) throws -> [String: Any] {
        let data = try #require(BlockDocumentPasteboardPayload.encode(blocks))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> [EditorBlock]? {
        BlockDocumentPasteboardPayload.decode(try JSONSerialization.data(withJSONObject: json))
    }

    @Test("payload는 블록 종류·텍스트·인라인 마크·들여쓰기를 손실 없이 왕복한다")
    func payloadRoundTripsBlocks() throws {
        let blocks = [
            EditorBlock(kind: .heading(level: 2), text: "제목"),
            EditorBlock(
                kind: .bulletedList,
                text: "굵은 항목",
                inlineMarks: [InlineMark(format: .bold, range: NSRange(location: 0, length: 2))],
                indentLevel: 2
            ),
            EditorBlock(kind: .code(language: "swift"), text: "let x = 1\nprint(x)"),
        ]
        let data = try #require(BlockDocumentPasteboardPayload.encode(blocks))
        let decoded = try #require(BlockDocumentPasteboardPayload.decode(data))

        #expect(decoded.map(\.kind) == blocks.map(\.kind))
        #expect(decoded.map(\.text) == blocks.map(\.text))
        #expect(decoded.map(\.inlineMarks) == blocks.map(\.inlineMarks))
        #expect(decoded.map(\.indentLevel) == blocks.map(\.indentLevel))
        #expect(Set(decoded.map(\.id)).isDisjoint(with: blocks.map(\.id)), "붙여넣은 블록은 새 ID를 받는다")
    }

    @Test("조작된 payload의 제목 레벨과 들여쓰기는 허용 범위로 제한한다",
          arguments: [(9, 99, 3, 3), (-5, -2, 1, 0), (2, 1, 2, 1)])
    func tamperedPayloadIsClamped(level: Int, indent: Int, expectedLevel: Int, expectedIndent: Int) throws {
        var json = try payloadJSON([EditorBlock(kind: .heading(level: 1), text: "제목")])
        var blocks = try #require(json["blocks"] as? [[String: Any]])
        var kind = try #require(blocks[0]["kind"] as? [String: Any])
        var heading = try #require(kind["heading"] as? [String: Any])
        heading["level"] = level
        kind["heading"] = heading
        blocks[0]["kind"] = kind
        blocks[0]["indentLevel"] = indent
        json["blocks"] = blocks

        let decoded = try #require(try decode(json))
        #expect(decoded.first?.kind == .heading(level: expectedLevel))
        #expect(decoded.first?.indentLevel == expectedIndent)
    }

    @Test("모르는 버전·빈 블록 목록·손상된 데이터·크기 상한 초과 payload는 거절한다")
    func invalidPayloadsAreRejected() throws {
        var futureVersion = try payloadJSON([EditorBlock(text: "본문")])
        futureVersion["version"] = 2
        var empty = try payloadJSON([EditorBlock(text: "본문")])
        empty["blocks"] = [[String: Any]]()

        #expect(try decode(futureVersion) == nil)
        #expect(try decode(empty) == nil)
        #expect(BlockDocumentPasteboardPayload.decode(Data("not json".utf8)) == nil)
        #expect(BlockDocumentPasteboardPayload.decode(Data(repeating: 0x20, count: 256 * 1_024 + 1)) == nil)
    }

    @Test("빈 문서나 크기 상한을 넘는 문서는 payload를 만들지 않는다")
    func oversizedOrEmptyDocumentsAreNotEncoded() {
        #expect(BlockDocumentPasteboardPayload.encode([]) == nil)
        // 한글은 UTF-8 3바이트라 100,000자는 256KiB 상한을 넘는다.
        let huge = EditorBlock(text: String(repeating: "가", count: 100_000))
        #expect(BlockDocumentPasteboardPayload.encode([huge]) == nil)
    }
}
