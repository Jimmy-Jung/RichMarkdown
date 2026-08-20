import SwiftUI
import SwiftLatex

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
                NavigationLink("UIKit UIHostingConfiguration") {
                    HostingConfigurationDemo()
                        .ignoresSafeArea()
                        .navigationTitle("UIKit 셀")
                }
            }
            .navigationTitle("SwiftLatex Demo")
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
