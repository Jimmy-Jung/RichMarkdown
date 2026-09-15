import SwiftUI
import SwiftLatex

/// 데모 화면의 본문 열 폭. iPad·가로 모드에서 코드 블록·다이어그램·문단이 화면 전폭으로
/// 늘어나지 않게 Notion(708px)·GitHub(1012px) 사이 값으로 제한하고 가운데 정렬한다.
/// 라이브러리는 폭을 정하지 않는다 — 소비 앱의 컨테이너 책임이다 (README «레이아웃 폭»).
enum DemoLayout {
    static let readableWidth: CGFloat = 720
    static let horizontalMargin: CGFloat = 16
}

extension UIView {
    /// 가운데 정렬된 본문 열 가이드. 좁은 화면에서는 좌우 여백만 남기고 폭을 채우며,
    /// 넓은 화면에서는 `DemoLayout.readableWidth`에서 멈춘다.
    func addReadableColumnGuide() -> UILayoutGuide {
        let guide = UILayoutGuide()
        addLayoutGuide(guide)
        let fill = guide.widthAnchor.constraint(
            equalTo: widthAnchor, constant: -2 * DemoLayout.horizontalMargin
        )
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: centerXAnchor),
            guide.widthAnchor.constraint(lessThanOrEqualToConstant: DemoLayout.readableWidth),
            guide.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DemoLayout.horizontalMargin),
            fill,
        ])
        return guide
    }
}

@main
struct SwiftLatexDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // UI 테스트 dark mode 매트릭스용 launch argument.
                .preferredColorScheme(
                    ProcessInfo.processInfo.arguments.contains("-swiftlatexDark") ? .dark : nil
                )
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("AI 챗봇 (SwiftUI)") {
                    ChatDemoView()
                }
                NavigationLink("AI 챗봇 (UIKit)") {
                    UIKitChatDemoView()
                }
                NavigationLink("SSE 실시간 렌더링 (SwiftUI)") {
                    SSEDemoView()
                }
                NavigationLink("SSE 실시간 렌더링 (UIKit)") {
                    UIKitSSEDemoView()
                }
                NavigationLink("라이브 편집 (분할 미리보기)") {
                    EditorDemoView()
                }
                NavigationLink("블록 편집 (Notion 스타일)") {
                    BlockEditorDemoView()
                }
                NavigationLink("코드 블록 확장 (Mermaid · Prism)") {
                    CodeBlockExtensionDemoView()
                }
                NavigationLink("수식 Attachment (읽기 전용)") {
                    AttachmentDemoView()
                }
                NavigationLink("UIKit UIHostingConfiguration") {
                    HostingConfigurationDemo()
                        .ignoresSafeArea()
                        .navigationTitle("UIKit 셀")
                }
            }
            .navigationTitle("SwiftLatex Demo")
        }
        // 앱 시작 직후 UIKit 챗 메시지 뷰를 미리 렌더한다. 콜드 스타트에서는
        // 컨트롤러 init(전환 직전) prewarm만으로 파이프라인이 전환 안에 못 끝나
        // fallback 원문 → 이미지 교체와 버블 높이 점프가 보인다.
        .task {
            UIKitChatViewController.prewarmSharedMessageViews(
                configuration: UIKitChatConfiguration(
                    preset: LatexThemePreset.fromLaunchArguments()
                )
            )
        }
    }
}

/// `UIHostingConfiguration` collection 예제 (DEVELOPMENT.md §5).
/// 고정 itemSize 대신 list layout의 estimated dimension을 사용한다.
struct HostingConfigurationDemo: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> MessagesCollectionViewController {
        MessagesCollectionViewController()
    }

    func updateUIViewController(_ controller: MessagesCollectionViewController, context: Context) {}
}

final class MessagesCollectionViewController: UICollectionViewController {
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init() {
        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, message in
            cell.contentConfiguration = UIHostingConfiguration {
                LatexMarkdownView(markdown: message)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, message in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: message)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ChatFixtures.assistantTexts)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
