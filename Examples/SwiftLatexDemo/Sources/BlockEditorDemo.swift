import SwiftUI
import SwiftLatex
import UniformTypeIdentifiers

/// Notion처럼 블록 단위 인라인 WYSIWYG 화면.
///
/// 문서를 빈 줄 기준 블록 배열로 들고, 포커스된 블록만 raw markdown
/// 편집기로 바꾼다. 나머지 블록은 렌더된 상태를 유지한다.
/// 포커스가 떠나면 그 블록을 다시 나눈다 — 편집 중 빈 줄을 넣으면 커밋
/// 시점에 블록이 분리되고, 내용을 전부 지우면 블록이 사라진다.
struct BlockEditorDemoView: View {
    struct EditorBlock: Identifiable, Equatable {
        let id = UUID()
        var text: String
    }

    @State private var blocks: [EditorBlock]
    @State private var parsesDollarMath = true
    @State private var preset = LatexThemePreset.fromLaunchArguments()
    /// 편집 중인 블록.
    @State private var selectedBlock: UUID?
    /// iOS 16의 단일 인자 `onChange`는 이전 값을 주지 않으므로 직접 기억한다.
    @State private var lastSelected: UUID?
    /// 손잡이로 드래그 중인 블록. DropDelegate가 hover 순서 교환에 쓴다.
    @State private var draggingBlock: EditorBlock?

    private static let editorFont = Font.system(.callout, design: .monospaced)

    init() {
        let seeds = Self.split(EditorDemoView.seedDocument)
        // Notion처럼 문서 끝에는 항상 빈 블록이 하나 대기한다.
        _blocks = State(initialValue: seeds.map { EditorBlock(text: $0) } + [EditorBlock(text: "")])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    row(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .navigationTitle("블록 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                    Picker("테마", selection: $preset) {
                        ForEach(LatexThemePreset.allCases) { preset in
                            Text(verbatim: preset.rawValue).tag(preset)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
            }
        }
        .onChange(of: selectedBlock) { newValue in
            if let previous = lastSelected, previous != newValue {
                commit(previous)
            }
            lastSelected = newValue
        }
    }

    // MARK: - Rows

    private func row(for block: EditorBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            gutter(for: block)
            if selectedBlock == block.id {
                editingColumn(for: block)
            } else {
                renderedRow(for: block)
            }
        }
        .onDrop(
            of: [.text],
            delegate: BlockDropDelegate(item: block, blocks: $blocks, dragging: $draggingBlock)
        )
    }

    /// 모든 행이 같은 폭의 왼쪽 여백을 갖고, 선택된 블록에만 손잡이가 보인다.
    /// 손잡이를 끌면 블록 순서를 옮길 수 있다.
    @ViewBuilder
    private func gutter(for block: EditorBlock) -> some View {
        if selectedBlock == block.id {
            // 편집기 첫 줄(body lineHeight)과 세로 중심을 맞춘다.
            DragHandleDots()
                .frame(width: 20, height: UIFont.preferredFont(forTextStyle: .body).lineHeight)
                .contentShape(Rectangle())
                .onDrag {
                    draggingBlock = block
                    return NSItemProvider(object: block.id.uuidString as NSString)
                }
                .accessibilityLabel("블록 이동 손잡이")
        } else {
            Color.clear.frame(width: 20, height: 1)
        }
    }

    @ViewBuilder
    private func renderedRow(for block: EditorBlock) -> some View {
        if block.text.isEmpty {
            // 최하단 대기 블록. 렌더할 내용이 없으므로 placeholder만 보이고,
            // 탭하면 바로 편집기로 바뀌며 onAppear 포커스로 커서가 즉시 나타난다.
            Text("여기에 입력하려면 탭하세요")
                .font(Self.editorFont)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .onTapGesture { selectedBlock = block.id }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("빈 블록")
        } else {
            filledRenderedRow(for: block)
        }
    }

    private func filledRenderedRow(for block: EditorBlock) -> some View {
        LatexMarkdownView(markdown: block.text, parsesDollarMath: parsesDollarMath)
            .latexTheme(preset.theme)
            // 탭 = 편집 진입. 이 화면에서는 렌더 뷰 내부의 링크·복사 버튼을 끈다.
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selectedBlock = block.id }
            .contextMenu {
                Button(role: .destructive) {
                    delete(block.id)
                } label: {
                    Label("블록 삭제", systemImage: "trash")
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("탭하면 편집, 길게 누르면 삭제 메뉴")
    }

    /// Notion처럼 한 뷰에서 편집한다 — 이미 쓴 텍스트와 새 입력 모두 즉시
    /// 스타일이 입혀진다. 수식만 편집 완료(commit) 시 렌더된다.
    private func editingColumn(for block: EditorBlock) -> some View {
        MarkdownTextEditor(
            text: binding(for: block.id),
            parsesDollarMath: parsesDollarMath,
            onDone: { selectedBlock = nil }
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("블록 편집기")
    }

    // MARK: - Model

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { blocks.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
                blocks[index].text = newValue
            }
        )
    }

    private func delete(_ id: UUID) {
        blocks.removeAll { $0.id == id }
        if selectedBlock == id { selectedBlock = nil }
        ensureTrailingEmptyBlock()
    }

    /// 편집이 끝난 블록을 다시 나눈다. 빈 줄이 생겼으면 여러 블록으로 분리되고,
    /// 내용이 없으면 배열에서 사라진다.
    private func commit(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let parts = Self.split(blocks[index].text)
        blocks.replaceSubrange(index...index, with: parts.map { EditorBlock(text: $0) })
        ensureTrailingEmptyBlock()
    }

    /// 문서 끝에 항상 빈 블록 하나를 유지한다 (Notion의 대기 줄).
    private func ensureTrailingEmptyBlock() {
        if blocks.last?.text.isEmpty != true {
            blocks.append(EditorBlock(text: ""))
        }
    }

    /// 빈 줄 기준 블록 분리. 코드 fence 안의 빈 줄은 경계로 치지 않는다.
    /// ponytail: 빈 줄을 품은 display math(\[...\])는 추적하지 않는다 —
    /// 필요해지면 fence와 같은 방식으로 상태를 추가한다.
    static func split(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if trimmed.isEmpty, !inFence {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }
}

/// 블록 편집용 라이브 스타일링 텍스트 뷰. SwiftUI `TextEditor`는 attributed
/// 표시가 불가능해 UITextView를 감싼다. 키 입력마다 소스를 다시 스타일링하되
/// 문자열 자체는 바꾸지 않으므로 커서 위치가 그대로 유지된다.
/// Notion식 ⠿ 드래그 손잡이. SF Symbols에 2×3 점 그리드가 없어 직접 그린다.
private struct DragHandleDots: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// 폭은 부모 레이아웃이 정하고 높이만 내용에 맞추는 UITextView.
/// 기본 intrinsic 폭(콘텐츠 폭)을 그대로 두면 줄바꿈 없는 긴 줄이
/// ScrollView 콘텐츠 전체를 화면 밖으로 밀어낸다.
private final class SelfSizingTextView: UITextView {
    private var lastWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let height = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: UIView.noIntrinsicMetric, height: max(height, 28))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

private struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    let parsesDollarMath: Bool
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = SelfSizingTextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.typingAttributes = MarkdownStyler.baseAttributes
        view.attributedText = MarkdownStyler.styled(text, dollarMath: parsesDollarMath)

        // SwiftUI keyboard toolbar는 UIKit first responder에 붙지 않으므로
        // 완료 버튼은 inputAccessoryView로 단다.
        let coordinator = context.coordinator
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "완료", primaryAction: UIAction { _ in coordinator.parent.onDone() }),
        ]
        toolbar.sizeToFit()
        view.inputAccessoryView = toolbar

        // 탭 즉시 커서: 뷰가 계층에 붙은 다음 프레임에 포커스를 주고 끝으로 보낸다.
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.text != text, view.markedTextRange == nil else { return }
        view.attributedText = MarkdownStyler.styled(text, dollarMath: parsesDollarMath)
        view.typingAttributes = MarkdownStyler.baseAttributes
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextEditor

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            // 한글 조합(marked text) 중에 attributedText를 갈아끼우면 조합이 끊긴다.
            guard view.markedTextRange == nil else { return }
            let selection = view.selectedRange
            view.attributedText = MarkdownStyler.styled(view.text, dollarMath: parent.parsesDollarMath)
            view.selectedRange = selection
            // 재스타일 후 커서 위치의 속성(수식 dim 등)이 다음 입력에 새지 않게 초기화.
            view.typingAttributes = MarkdownStyler.baseAttributes
            view.invalidateIntrinsicContentSize()
        }
    }
}

/// 편집 중 라이브 마크다운 스타일링.
///
/// 문법 마커는 지우지 않고 흐리게 남긴다 — 마커까지 숨기려면 소스 markdown과
/// 표시 텍스트 사이 커서 매핑이 필요한데, 그건 Notion의 rich text 엔진에
/// 해당하는 별도 작업이다. 수식은 여기서 흐린 소스로만 표시하고
/// 편집 완료(commit) 시점에 렌더된다.
private enum MarkdownStyler {
    /// 빈 편집기·타이핑 시작 시점의 기준 속성. 이걸 지정하지 않으면 UITextView가
    /// 기본 폰트로 커서를 그려 첫 줄 높이가 body와 어긋난다.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ]
    }

    static func styled(_ source: String, dollarMath: Bool) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize - 2, weight: .regular)
        let text = NSMutableAttributedString(string: source, attributes: baseAttributes)

        // 코드 fence 내부는 통째로 monospace.
        var inFence = false
        enumerate(#"^.*$"#, source, [.anchorsMatchLines]) { match in
            let line = (source as NSString).substring(with: match.range)
            let isFenceLine = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFenceLine || inFence {
                text.addAttribute(.font, value: mono, range: match.range)
            }
            if isFenceLine { inFence.toggle() }
        }

        // 헤딩: 줄 전체를 레벨별 크기로, # 마커는 흐리게.
        enumerate(#"^(#{1,4} )(.+)$"#, source, [.anchorsMatchLines]) { match in
            let sizes: [CGFloat] = [28, 24, 21, 19]
            let level = match.range(at: 1).length - 1
            text.addAttribute(
                .font,
                value: UIFont.systemFont(ofSize: sizes[max(0, min(level, 4) - 1)], weight: .bold),
                range: match.range
            )
            text.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: match.range(at: 1))
        }

        // 인용 마커.
        enumerate(#"^> "#, source, [.anchorsMatchLines]) { match in
            text.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: match.range)
        }

        // 굵게 / 기울임 / 취소선 / 인라인 코드. 내용에 스타일, 마커는 흐리게.
        enumerate(#"\*\*([^\n]+?)\*\*"#, source) { match in
            text.addAttribute(
                .font,
                value: UIFont.systemFont(ofSize: body.pointSize, weight: .bold),
                range: match.range(at: 1)
            )
            dimDelimiters(of: match, in: text)
        }
        enumerate(#"(?<![\*\w])\*([^\*\n]+)\*(?!\*)"#, source) { match in
            text.addAttribute(
                .font,
                value: UIFont.italicSystemFont(ofSize: body.pointSize),
                range: match.range(at: 1)
            )
            dimDelimiters(of: match, in: text)
        }
        enumerate(#"~~([^\n]+?)~~"#, source) { match in
            text.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: match.range(at: 1)
            )
            dimDelimiters(of: match, in: text)
        }
        enumerate(#"`([^`\n]+)`"#, source) { match in
            text.addAttribute(.font, value: mono, range: match.range(at: 1))
            text.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: match.range(at: 1))
            dimDelimiters(of: match, in: text)
        }

        // 수식: 편집 중에는 흐린 monospace 소스로 표시. 렌더는 커밋 시.
        var mathPatterns = [#"\\\[[\s\S]+?\\\]"#, #"\\\([\s\S]+?\\\)"#]
        if dollarMath {
            mathPatterns += [#"\$\$[\s\S]+?\$\$"#, #"\$[^\$\n]+\$"#]
        }
        for pattern in mathPatterns {
            enumerate(pattern, source) { match in
                text.addAttribute(.font, value: mono, range: match.range)
                text.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: match.range)
            }
        }
        return text
    }

    /// 여닫는 문법 마커를 흐리게 만든다.
    private static func dimDelimiters(of match: NSTextCheckingResult, in text: NSMutableAttributedString) {
        let whole = match.range
        let content = match.range(at: 1)
        let leading = NSRange(location: whole.location, length: content.location - whole.location)
        let trailingStart = content.location + content.length
        let trailing = NSRange(location: trailingStart, length: whole.location + whole.length - trailingStart)
        text.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: leading)
        text.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: trailing)
    }

    private static func enumerate(
        _ pattern: String,
        _ source: String,
        _ options: NSRegularExpression.Options = [],
        _ handler: (NSTextCheckingResult) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        regex.enumerateMatches(in: source, range: NSRange(source.startIndex..., in: source)) { match, _, _ in
            if let match { handler(match) }
        }
    }
}

/// 손잡이 드래그로 블록 순서를 바꾼다. hover 중 실시간으로 자리를 교환하고
/// drop 시점에는 드래그 상태만 정리한다.
private struct BlockDropDelegate: DropDelegate {
    let item: BlockEditorDemoView.EditorBlock
    @Binding var blocks: [BlockEditorDemoView.EditorBlock]
    @Binding var dragging: BlockEditorDemoView.EditorBlock?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id,
              let from = blocks.firstIndex(where: { $0.id == dragging.id }),
              let to = blocks.firstIndex(where: { $0.id == item.id })
        else { return }
        withAnimation {
            blocks.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
