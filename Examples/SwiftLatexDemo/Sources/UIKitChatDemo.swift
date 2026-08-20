import SwiftUI
import UIKit
import SwiftLatex

/// UIKit 네이티브 렌더러(`LatexMarkdownUIView`) 확인 화면.
///
/// `UIHostingConfiguration`을 쓰지 않는다. 확인 대상은 세 가지다.
/// 1. 재사용 셀 안의 self-sizing — 수식 hydration은 최초 레이아웃 뒤에 오므로
///    `onContentSizeChange`로 높이를 다시 재야 한다.
/// 2. 테마 색·폰트 교체가 살아 있는 뷰에 즉시 반영되는지.
/// 3. 같은 fixture를 SwiftUI 화면(`ChatDemoView`)과 나란히 비교.

// MARK: - 테마 프리셋

enum LatexThemePreset: String, CaseIterable, Identifiable {
    case standard = "기본"
    case large = "큰 글자"
    case serif = "Serif"
    case tinted = "색 강조"

    var id: String { rawValue }

    var theme: LatexTheme {
        switch self {
        case .standard:
            return .default

        case .large:
            return LatexTheme(
                bodyFont: LatexFont(relativeTo: .body, size: 24),
                heading1Font: LatexFont(relativeTo: .title1, size: 38, weight: .bold),
                heading2Font: LatexFont(relativeTo: .title2, size: 30, weight: .bold),
                heading3Font: LatexFont(relativeTo: .title3, size: 26, weight: .semibold),
                codeFont: LatexFont(design: .monospaced, relativeTo: .body, size: 20),
                codeLabelFont: LatexFont(design: .monospaced, relativeTo: .caption, size: 16)
            )

        case .serif:
            // 수식은 Georgia와 어울리는 Times계 서체를 쓴다.
            return LatexTheme(
                bodyFont: LatexFont(design: .custom(name: "Georgia"), relativeTo: .body),
                heading1Font: LatexFont(design: .custom(name: "Georgia-Bold"), relativeTo: .title1),
                heading2Font: LatexFont(design: .custom(name: "Georgia-Bold"), relativeTo: .title2),
                heading3Font: LatexFont(design: .custom(name: "Georgia-Bold"), relativeTo: .title3),
                heading4Font: LatexFont(design: .custom(name: "Georgia-Bold"), relativeTo: .headline),
                mathFont: .termes
            )

        case .tinted:
            return LatexTheme(
                textColor: Color(red: 0.20, green: 0.16, blue: 0.55),
                quoteBar: Color(red: 0.45, green: 0.40, blue: 0.85),
                mathFont: .xits
            )
        }
    }
}

extension LatexThemePreset {
    /// UI 테스트 스크린샷 매트릭스용. `-swiftlatexPreset Serif` 형태로 넘긴다.
    /// 기존 `-swiftlatexDark`와 같은 방식이다.
    static func fromLaunchArguments() -> LatexThemePreset {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-swiftlatexPreset"),
              index + 1 < arguments.count,
              let preset = LatexThemePreset(rawValue: arguments[index + 1])
        else { return .standard }
        return preset
    }
}

struct UIKitChatConfiguration: Equatable {
    var parsesDollarMath = false
    var showsCaseLabels = true
    var preset: LatexThemePreset = .standard
}

// MARK: - SwiftUI 껍데기

struct UIKitChatDemoView: View {
    @State private var configuration = UIKitChatConfiguration(
        preset: LatexThemePreset.fromLaunchArguments()
    )

    var body: some View {
        UIKitChatList(configuration: configuration)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("UIKit 네이티브")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("$ 수식 파싱 (opt-in)", isOn: $configuration.parsesDollarMath)
                        Toggle("케이스 라벨 표시", isOn: $configuration.showsCaseLabels)
                        Picker("테마", selection: $configuration.preset) {
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
    }
}

struct UIKitChatList: UIViewControllerRepresentable {
    let configuration: UIKitChatConfiguration

    func makeUIViewController(context: Context) -> UIKitChatViewController {
        UIKitChatViewController(configuration: configuration)
    }

    func updateUIViewController(_ controller: UIKitChatViewController, context: Context) {
        controller.configuration = configuration
    }
}

// MARK: - Collection view

final class UIKitChatViewController: UICollectionViewController {
    var configuration: UIKitChatConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            // 화면에 있는 셀은 즉시 갱신한다. 재사용될 셀은 configure에서 새 값을 받는다.
            for cell in collectionView.visibleCells {
                (cell as? AssistantMessageCell)?.apply(configuration)
            }
            invalidateHeights()
        }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, ChatMessage>!
    private var heightInvalidationScheduled = false
    private var needsHeightInvalidation = false

    init(configuration: UIKitChatConfiguration) {
        self.configuration = configuration
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.showsSeparators = false
        listConfiguration.backgroundColor = .systemGroupedBackground
        super.init(
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfiguration)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UIKitChatViewController는 코드로만 생성한다")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.accessibilityIdentifier = "uikitChatList"

        let assistantRegistration = UICollectionView.CellRegistration<AssistantMessageCell, ChatMessage> {
            [weak self] cell, _, message in
            guard let self else { return }
            cell.onHeightChange = { [weak self] in self?.invalidateHeights() }
            cell.configure(message, configuration: self.configuration)
        }
        let userRegistration = UICollectionView.CellRegistration<UserMessageCell, ChatMessage> { cell, _, message in
            cell.configure(message)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, message in
            switch message.role {
            case .assistant:
                return collectionView.dequeueConfiguredReusableCell(
                    using: assistantRegistration, for: indexPath, item: message
                )
            case .user:
                return collectionView.dequeueConfiguredReusableCell(
                    using: userRegistration, for: indexPath, item: message
                )
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, ChatMessage>()
        snapshot.appendSections([0])
        snapshot.appendItems(ChatFixtures.conversation)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 수식 이미지 hydration과 테마 교체는 최초 레이아웃 뒤에 높이를 바꾼다.
    ///
    /// `invalidateLayout()`만으로는 부족하다(실측). compositional list layout은 이미 측정한
    /// 셀에게 `preferredLayoutAttributesFitting`을 다시 묻지 않아서, 셀이 옛 높이에 묶인 채
    /// 내용이 눌리고 텍스트가 겹친다. `performBatchUpdates(nil)`이 self-sizing 셀의
    /// 재측정을 강제하는 경로다.
    ///
    /// 셀마다 즉시 호출하면 스크롤 중 과도하게 재계산되므로 runloop당 1회로 합친다.
    /// 스크롤 중에는 batch update가 제스처·감속을 방해하므로 멈춘 뒤로 미룬다.
    private func invalidateHeights() {
        guard !heightInvalidationScheduled else { return }
        heightInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightInvalidationScheduled = false
            guard !self.collectionView.isDragging, !self.collectionView.isDecelerating else {
                self.needsHeightInvalidation = true
                return
            }
            self.collectionView.performBatchUpdates(nil)
        }
    }

    private func flushHeightInvalidation() {
        guard needsHeightInvalidation else { return }
        needsHeightInvalidation = false
        collectionView.performBatchUpdates(nil)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { flushHeightInvalidation() }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushHeightInvalidation()
    }
}

// MARK: - 답변 셀

final class AssistantMessageCell: UICollectionViewCell {
    private let latexView = LatexMarkdownUIView()
    private let caseLabel = UILabel()
    private let caseCapsule = UIStackView()
    private let caseRow = UIStackView()
    private let bubble = UIView()

    private var caseName = ""
    private var hasRenderedCurrentMessage = false

    var onHeightChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        caseLabel.font = .preferredFont(forTextStyle: .caption1)
        caseLabel.adjustsFontForContentSizeCategory = true
        caseLabel.textColor = .label

        caseCapsule.addArrangedSubview(caseLabel)
        caseCapsule.isLayoutMarginsRelativeArrangement = true
        caseCapsule.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        caseCapsule.backgroundColor = .tertiarySystemFill
        caseCapsule.layer.cornerRadius = 12
        caseCapsule.layer.cornerCurve = .continuous
        caseCapsule.clipsToBounds = true
        caseCapsule.setContentHuggingPriority(.required, for: .horizontal)

        // 캡슐이 콘텐츠 폭만 갖도록 남는 폭을 빈 뷰가 먹는다.
        caseRow.axis = .horizontal
        caseRow.addArrangedSubview(caseCapsule)
        caseRow.addArrangedSubview(UIView())

        bubble.backgroundColor = .secondarySystemGroupedBackground
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true

        latexView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(latexView)
        NSLayoutConstraint.activate([
            latexView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
            latexView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            latexView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            latexView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -14),
        ])

        let root = UIStackView(arrangedSubviews: [caseRow, bubble])
        root.axis = .vertical
        root.spacing = 8
        root.alignment = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])

        latexView.onContentSizeChange = { [weak self] in
            guard let self else { return }
            if !self.hasRenderedCurrentMessage {
                self.hasRenderedCurrentMessage = true
                self.latexView.alpha = 1
            }
            self.onHeightChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AssistantMessageCell은 코드로만 생성한다")
    }

    /// 새 markdown의 parse가 끝나기 전에는 이전 문서가 남아 보인다. 스트리밍에서는 그 잔상이
    /// 의도된 동작(최신 원문 fallback)이지만 셀 재사용에서는 다른 메시지가 보이는 셈이다.
    /// 첫 렌더까지 감춰 둔다.
    override func prepareForReuse() {
        super.prepareForReuse()
        hasRenderedCurrentMessage = false
        latexView.alpha = 0
    }

    func configure(_ message: ChatMessage, configuration: UIKitChatConfiguration) {
        caseName = message.caseName
        caseLabel.text = message.caseName
        apply(configuration)
        latexView.markdown = message.text
    }

    func apply(_ configuration: UIKitChatConfiguration) {
        caseRow.isHidden = !(configuration.showsCaseLabels && !caseName.isEmpty)
        latexView.theme = configuration.preset.theme
        latexView.parsesDollarMath = configuration.parsesDollarMath
    }
}

// MARK: - 질문 셀

final class UserMessageCell: UICollectionViewCell {
    private let label = UILabel()
    private let bubble = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        bubble.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false

        bubble.addSubview(label)
        contentView.addSubview(bubble)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),

            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubble.leadingAnchor.constraint(
                greaterThanOrEqualTo: contentView.leadingAnchor, constant: 56
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UserMessageCell은 코드로만 생성한다")
    }

    func configure(_ message: ChatMessage) {
        label.text = message.text
    }
}
