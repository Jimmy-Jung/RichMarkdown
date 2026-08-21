import SwiftUI

/// 논리 블록은 유지하면서 화면에는 하나의 연속 문서만 노출한다.
struct BlockEditorDemoView: View {
    @State private var model: BlockEditorModel
    @State private var parsesDollarMath = true

    init() {
        _model = State(initialValue: BlockEditorModel(markdown: EditorDemoView.seedDocument))
    }

    var body: some View {
        BlockDocumentTextEditor(
            blocks: model.blocks,
            parsesDollarMath: parsesDollarMath,
            selection: model.currentDocumentSelection,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            onReplaceText: replaceDocumentText,
            onSelectionChange: { model.updateDocumentSelection($0) },
            onToolbarAction: perform
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle("블록 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
            }
        }
    }

    private func replaceDocumentText(
        in range: NSRange,
        with replacement: String
    ) -> NSRange? {
        model.replaceDocumentText(in: range, with: replacement)
    }

    private func perform(_ action: EditorToolbarAction, selection: NSRange) {
        if case .done = action { return }

        model.updateDocumentSelection(selection)
        guard let active = model.blockSelection(for: selection) else { return }

        switch action {
        case .insert:
            updateSelection(model.insert(after: active.blockID))
        case let .transform(kind):
            model.transform(id: active.blockID, to: kind)
        case let .format(format):
            let next = model.applyInlineFormat(format, id: active.blockID, range: active.range)
            if active.range.length == selection.length { updateSelection(next) }
        case .indent:
            _ = model.indent(id: active.blockID)
        case .outdent:
            _ = model.outdent(id: active.blockID)
        case .undo:
            _ = model.undo()
        case .redo:
            _ = model.redo()
        case .duplicate:
            updateSelection(model.duplicate(id: active.blockID))
        case .delete:
            updateSelection(model.delete(id: active.blockID))
        case .moveUp:
            restoreCaret(active, after: model.moveUp(id: active.blockID), selection: selection)
        case .moveDown:
            restoreCaret(active, after: model.moveDown(id: active.blockID), selection: selection)
        case .done:
            break
        }
    }

    private func updateSelection(_ selection: BlockSelection?) {
        guard let selection else { return }
        model.updateSelection(selection)
    }

    private func restoreCaret(
        _ selection: BlockSelection,
        after didMove: Bool,
        selection documentSelection: NSRange
    ) {
        guard didMove, documentSelection.length == 0 else { return }
        model.updateSelection(selection)
    }
}
