import SwiftUI
import UIKit
import SwiftLatex

/// UIKit 네이티브 렌더러(`LatexMarkdownUIView`) 확인 화면.
///
/// `UIHostingConfiguration`을 쓰지 않는다. 확인 대상은 세 가지다.
/// 1. 메시지별 완성 뷰 재사용 — 다시 보이는 답변은 UIKit 뷰 계층을 재구성하지 않는다.
/// 2. 재사용 셀 안의 self-sizing — fallback이 수식 이미지로 바뀌면 해당 셀만
///    다시 측정해 SwiftUI 화면과 같은 progressive 표시를 유지한다.
/// 3. 테마 색·폰트 교체가 살아 있는 뷰에 즉시 반영되는지.
/// 4. 같은 fixture를 SwiftUI 화면(`ChatDemoView`)과 나란히 비교.

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
            // large title 축소 전환은 스크롤 오프셋에 연동된다. 셀 재측정이 전환 중
            // contentSize를 바꾸면 nav bar가 중간 상태로 굳어 제목이 사라지고
            // 영역만 남는다. inline로 고정해 회피한다.
            .navigationBarTitleDisplayMode(.inline)
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
    /// 화면 재진입에도 렌더된 메시지 뷰를 유지한다 (SwiftUI 화면과 같은 즉시 진입).
    /// fixture 고정 데모라 상한 없음 — 실제 피드에는 eviction 정책이 필요하다.
    private static let sharedMessageViewCache = AssistantMessageViewCache()
    private let assistantMessageViewCache = UIKitChatViewController.sharedMessageViewCache

    var configuration: UIKitChatConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            let mustDiscardCachedViews = configuration.parsesDollarMath != oldValue.parsesDollarMath
                || configuration.preset != oldValue.preset
            if mustDiscardCachedViews {
                assistantMessageViewCache.removeAll()
            }
            for case let cell as AssistantMessageCell in collectionView.visibleCells {
                cell.apply(configuration)
            }
        }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, ChatMessage>!

    init(configuration: UIKitChatConfiguration) {
        self.configuration = configuration
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfiguration.showsSeparators = false
        listConfiguration.backgroundColor = .systemGroupedBackground
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: listConfiguration))
        Self.prewarmSharedMessageViews(configuration: configuration)
    }

    /// 전 답변의 parse·render 파이프라인을 미리 돌려 완성 상태로 진입하게 한다.
    ///
    /// 셀 configure 시점에 markdown을 처음 주입하면 async 렌더가 진입 애니메이션과
    /// 겹쳐 fallback 원문이 이미지로 바뀌며 버블이 커지는 과정이 보인다.
    /// 컨트롤러 init(전환 시작 전)만으로는 콜드 스타트에서 부족하다 — SwiftMath
    /// 폰트 등록 + 12개 메시지 raster가 전환 0.35s를 넘긴다(영상 실측). 그래서
    /// 루트 화면(`ContentView`)이 앱 시작 직후에도 호출한다. 사용자가 메뉴를 탭하기
    /// 전에 파이프라인이 끝나 첫 진입도 SwiftUI 화면처럼 완성 상태다.
    /// 이미 주입된 값은 dedupe로 걸러지므로 재호출은 no-op다.
    /// detached 뷰도 predicted trait으로 기기 displayScale을 받는다(lldb 실측:
    /// DisplayScale = 3) — attach 후 재렌더가 없다.
    static func prewarmSharedMessageViews(configuration: UIKitChatConfiguration) {
        for message in ChatFixtures.conversation where message.role == .assistant {
            let entry = sharedMessageViewCache.entry(for: message)
            entry.view.theme = configuration.preset.theme
            entry.view.parsesDollarMath = configuration.parsesDollarMath
            entry.view.markdown = message.text
            entry.beginObservingContentChanges()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UIKitChatViewController는 코드로만 생성한다")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.accessibilityIdentifier = "uikitChatList"
        collectionView.selfSizingInvalidation = .enabled

        let assistantRegistration = UICollectionView.CellRegistration<AssistantMessageCell, ChatMessage> {
            [weak self] cell, _, message in
            guard let self else { return }
            cell.configure(
                message,
                configuration: self.configuration,
                entry: self.assistantMessageViewCache.entry(for: message)
            )
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
}

/// 고정 fixture 데모용 캐시다. 셀 재사용과 별개로 메시지 identity가 뷰 identity를 결정한다.
/// 실제 무한 피드에는 메모리 비용을 측정한 뒤 상한과 eviction 정책을 추가해야 한다.
/// internal: 셀 수명(늦은 prepareForReuse) 회귀 테스트가 직접 구성한다.
@MainActor
final class AssistantMessageViewCache {
    final class Entry {
        let view = LatexMarkdownUIView()
        private(set) var hasRenderedContent = false
        private weak var cell: AssistantMessageCell?
        private var observesContentChanges = false

        func attach(to cell: AssistantMessageCell) {
            self.cell = cell
        }

        func detach(from cell: AssistantMessageCell) {
            guard self.cell === cell else { return }
            self.cell = nil
        }

        /// 생성 직후의 빈 fallback 콜백은 무시하고, 현재 메시지를 넣은 뒤의 갱신만 받는다.
        func beginObservingContentChanges() {
            guard !observesContentChanges else { return }
            observesContentChanges = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.view.onContentSizeChange = { [weak self] in
                    guard let self else { return }
                    self.hasRenderedContent = true
                    self.cell?.renderedContentDidChange(for: self)
                }
            }
        }
    }

    private var entries: [ChatMessage.ID: Entry] = [:]

    func entry(for message: ChatMessage) -> Entry {
        if let entry = entries[message.id] {
            return entry
        }

        let entry = Entry()
        entries[message.id] = entry
        return entry
    }

    func removeAll() {
        entries.removeAll()
    }
}

// MARK: - 답변 셀

final class AssistantMessageCell: UICollectionViewCell {
    private let caseLabel = UILabel()
    private let caseCapsule = UIStackView()
    private let caseRow = UIStackView()
    private let bubble = UIView()

    private var caseName = ""
    private var entry: AssistantMessageViewCache.Entry?
    private var latexViewConstraints: [NSLayoutConstraint] = []

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
        // vertical hugging을 걸지 않으면 root(vertical, distribution .fill)가 셀의 남는
        // 세로 공간을 caseRow에 배분하고 캡슐이 그대로 늘어난다. 남는 공간은 버블이 먹는다.
        caseCapsule.setContentHuggingPriority(.required, for: .vertical)

        // 캡슐이 콘텐츠 폭만 갖도록 남는 폭을 빈 뷰가 먹는다.
        caseRow.axis = .horizontal
        caseRow.addArrangedSubview(caseCapsule)
        caseRow.addArrangedSubview(UIView())
        caseRow.setContentHuggingPriority(.required, for: .vertical)

        bubble.backgroundColor = .secondarySystemGroupedBackground
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AssistantMessageCell은 코드로만 생성한다")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        detachMessageView()
    }

    /// internal: 셀 수명 회귀 테스트가 collection view 없이 직접 호출한다.
    func configure(
        _ message: ChatMessage,
        configuration: UIKitChatConfiguration,
        entry: AssistantMessageViewCache.Entry
    ) {
        caseName = message.caseName
        caseLabel.text = message.caseName
        attachMessageView(entry)
        apply(configuration)
        entry.view.markdown = message.text
        entry.beginObservingContentChanges()
    }

    func apply(_ configuration: UIKitChatConfiguration) {
        caseRow.isHidden = !(configuration.showsCaseLabels && !caseName.isEmpty)
        entry?.view.theme = configuration.preset.theme
        entry?.view.parsesDollarMath = configuration.parsesDollarMath
    }

    fileprivate func renderedContentDidChange(for entry: AssistantMessageViewCache.Entry) {
        guard self.entry === entry else { return }
        entry.view.alpha = 1
        contentView.invalidateIntrinsicContentSize()
    }

    private func attachMessageView(_ newEntry: AssistantMessageViewCache.Entry) {
        guard entry !== newEntry else { return }
        detachMessageView()

        entry = newEntry
        let latexView = newEntry.view
        latexView.alpha = newEntry.hasRenderedContent ? 1 : 0
        latexView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(latexView)
        latexViewConstraints = [
            latexView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
            latexView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            latexView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            latexView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -14),
        ]
        NSLayoutConstraint.activate(latexViewConstraints)
        newEntry.attach(to: self)
        contentView.invalidateIntrinsicContentSize()
    }

    private func detachMessageView() {
        guard let entry else { return }
        entry.detach(from: self)
        NSLayoutConstraint.deactivate(latexViewConstraints)
        latexViewConstraints.removeAll()
        // 뷰가 아직 이 셀에 붙어 있을 때만 제거한다 (실측 결함).
        // 화면 밖으로 나간 셀은 prepareForReuse 없이 reuse pool에 머물다가 다음
        // dequeue 때에야 이 메서드를 탄다. 그 사이 같은 메시지가 다른 셀에 붙으면
        // `attachMessageView`의 addSubview가 뷰를 이미 이사시킨 상태다 — 여기서
        // 무조건 removeFromSuperview하면 화면에 보이는 셀에서 뷰를 뜯어내
        // 빈 버블이 남는다 (빠른 스크롤 왕복에서 재현).
        if entry.view.superview === bubble {
            entry.view.removeFromSuperview()
        }
        self.entry = nil
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
