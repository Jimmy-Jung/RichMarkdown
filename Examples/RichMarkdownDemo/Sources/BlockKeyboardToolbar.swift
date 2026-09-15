// Created by JunyoungJung on 2026-08-24.

import RichMarkdownBlockEditor
import UIKit

/// 블록 종류의 표시용 문자열·아이콘. package 엔진은 표시 문자열을 갖지 않으므로
/// UI 레이어(demo)가 책임진다.
extension EditorBlockKind {
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

/// package 에디터의 주입점 계약. `update(kind:canUndo:canRedo:)`는 이미 시그니처가 같다.
extension BlockKeyboardToolbar: BlockEditorInputAccessory {}
