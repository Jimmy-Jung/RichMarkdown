import SwiftUI
import SwiftLatex
import SwiftLatexHighlight
import SwiftLatexMermaid

/// 코드 블록 확장 두 가지를 같은 원문에 적용해 비교하는 화면.
///
/// - **Prism + JavaScriptCore**: ```` ```swift ```` 같은 코드 블록에 색 범위를 입힌다.
/// - **공식 Mermaid + WKWebView**: ```` ```mermaid ```` 블록을 다이어그램으로 대체한다.
///
/// 두 확장 모두 `LatexCodeBlockOptions` 주입으로만 켜진다. 끄면 라이브러리 기본 동작
/// (plain monospace 코드 블록)으로 돌아가는 것을 토글로 바로 확인할 수 있다.
struct CodeBlockExtensionDemoView: View {
    enum Renderer: String, CaseIterable, Identifiable {
        case swiftUI = "SwiftUI"
        case uiKit = "UIKit"

        var id: String { rawValue }
    }

    @State private var renderer: Renderer = .swiftUI
    @State private var highlightsCode = true
    @State private var drawsDiagrams = true
    @State private var preset = LatexThemePreset.fromLaunchArguments()

    private var options: LatexCodeBlockOptions {
        LatexCodeBlockOptions(
            highlighter: highlightsCode ? PrismHighlighter.shared : nil,
            diagram: drawsDiagrams ? MermaidDiagramRenderer.shared : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("렌더러", selection: $renderer) {
                ForEach(Renderer.allCases) { value in
                    Text(verbatim: value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("codeblock.renderer.picker")

            content
                .background(Color(.systemBackground))
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("코드 블록 확장")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("신택스 하이라이팅 (Prism)", isOn: $highlightsCode)
                    Toggle("Mermaid 다이어그램", isOn: $drawsDiagrams)
                    Picker("테마", selection: $preset) {
                        ForEach(LatexThemePreset.allCases) { value in
                            Text(verbatim: value.rawValue).tag(value)
                        }
                    }
                } label: {
                    Label("설정", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("codeblock.settings")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch renderer {
        case .swiftUI:
            ScrollView {
                LatexMarkdownView(markdown: Self.sample, parsesDollarMath: true)
                    .latexTheme(preset.theme)
                    .latexCodeBlocks(options)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("codeblock.swiftui")
        case .uiKit:
            // UIKit 렌더러는 SwiftUI ScrollView에 넣지 않는다. 다이어그램 높이가 렌더 뒤에
            // 정해지는데 `UIViewRepresentable`은 intrinsic content size 변화를 따라오지 않아
            // 뷰가 0 높이로 접힌다(실측). 저장소의 다른 UIKit 데모와 같이 전용 UIScrollView에 넣는다.
            CodeBlockExtensionUIKitContainer(
                markdown: Self.sample,
                theme: preset.theme,
                options: options
            )
            .accessibilityIdentifier("codeblock.uikit")
        }
    }

    /// 수식·표·코드·다이어그램이 한 메시지에 섞인 실제 어시스턴트 답변 형태.
    static let sample = #"""
    # 검색 파이프라인

    질의 하나가 응답까지 가는 경로입니다. 색인 크기가 \(n\)일 때 이진 탐색 비용은
    \(O(\log n)\)입니다.

    ```mermaid
    flowchart TD
        Q[사용자 질의] --> N[정규화]
        N --> R{캐시 적중?}
        R -->|예| C[캐시 응답]
        R -->|아니오| S[색인 검색]
        S --> K[상위 k개 재순위]
        K --> A[응답 생성]
        C --> A
    ```

    재순위 단계는 아래처럼 구현합니다.

    ```swift
    // 상위 k개만 남기고 점수 순으로 정렬한다.
    func rerank(_ hits: [Hit], limit: Int = 20) -> [Hit] {
        hits.sorted { $0.score > $1.score }
            .prefix(limit)
            .map { Hit(id: $0.id, score: $0.score) }
    }
    ```

    호출 예시와 응답 형식은 다음과 같습니다.

    ```bash
    curl -sS "https://example.com/search?q=검색&k=20" | jq '.hits[0]'
    ```

    ```json
    {
      "query": "검색",
      "took_ms": 12,
      "hits": [{ "id": "doc-1", "score": 0.94, "title": "색인 설계" }]
    }
    ```

    ```python
    def normalize(query: str) -> str:
        # 공백과 대소문자를 정리한다.
        return " ".join(query.strip().lower().split())
    ```

    ## 응답 시간 예산

    | 단계 | 예산(ms) | 비고 |
    | --- | ---: | --- |
    | 정규화 | 1 | 문자열만 |
    | 색인 검색 | 8 | \(O(\log n)\) |
    | 재순위 | 3 | 상위 k개 |

    다음은 시퀀스로 본 같은 흐름입니다.

    ```mermaid
    sequenceDiagram
        participant 사용자
        participant 앱
        participant 색인
        사용자->>앱: 질의 전송
        앱->>색인: 검색 요청
        색인-->>앱: 상위 k개
        앱-->>사용자: 응답 생성
    ```

    지원하지 않는 언어는 원문 그대로 표시합니다.

    ```brainfuck
    ++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]
    ```
    """#
}

/// UIKit 네이티브 렌더러에 같은 확장을 주입한 비교 화면.
///
/// 세로 스크롤은 소비 앱 책임이라는 라이브러리 계약대로, 전용 `UIScrollView` 안에
/// `LatexMarkdownUIView`를 넣고 높이는 자동 레이아웃이 결정하게 둔다.
private struct CodeBlockExtensionUIKitContainer: UIViewControllerRepresentable {
    let markdown: String
    let theme: LatexTheme
    let options: LatexCodeBlockOptions

    func makeUIViewController(context: Context) -> CodeBlockExtensionUIKitController {
        CodeBlockExtensionUIKitController(markdown: markdown, theme: theme, options: options)
    }

    func updateUIViewController(_ controller: CodeBlockExtensionUIKitController, context: Context) {
        controller.theme = theme
        controller.options = options
    }
}

final class CodeBlockExtensionUIKitController: UIViewController {
    var theme: LatexTheme {
        didSet { messageView.theme = theme }
    }

    var options: LatexCodeBlockOptions {
        didSet { messageView.codeBlocks = options }
    }

    private let scrollView = UIScrollView()
    private let messageView: LatexMarkdownUIView

    init(markdown: String, theme: LatexTheme, options: LatexCodeBlockOptions) {
        self.theme = theme
        self.options = options
        self.messageView = LatexMarkdownUIView(markdown: markdown, parsesDollarMath: true, theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CodeBlockExtensionUIKitController는 코드로만 생성한다")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        messageView.codeBlocks = options
        messageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(messageView)
        view.addSubview(scrollView)

        let guide = scrollView.contentLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            messageView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            messageView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            messageView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            messageView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            messageView.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -32
            ),
        ])
    }
}
