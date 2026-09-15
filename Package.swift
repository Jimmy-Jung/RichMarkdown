// swift-tools-version: 6.0
import PackageDescription

// DEVELOPMENT.md §2: 공개 product는 RichMarkdown + RichMarkdownBlockEditor. Core는 비공개 target.
// P0 재현성: SwiftMath exact 1.7.3, swift-markdown exact 0.4.0.
// P0 확인: SwiftMath 1.7.2는 MTMathListBuilder의 scope 버그(typo)로 Xcode 26.6에서 컴파일되지 않는다.
//          1.7.3이 수정 버전이며 MathImage.asImage()의 (NSError?, MTImage?, LayoutInfo?) API는 동일하다.
// tools 6.0: Swift Testing 사용을 위해 필요. 우리 target은 Swift 6 language mode로 빌드된다.
// swift-markdown을 from:으로 열면 Swift tools 6.2가 필요한 이후 0.x가 선택될 수 있어 exact로 고정한다.
let package = Package(
    name: "RichMarkdown",
    platforms: [
        .iOS(.v16),
        // macOS UI는 비목표. host에서 `swift build --target RichMarkdownCore`를 돌리기 위한
        // 최소 선언일 뿐이다 (SwiftMath가 macOS 12를 요구).
        .macOS(.v12),
    ],
    products: [
        .library(name: "RichMarkdown", targets: ["RichMarkdown"]),
        // Notion 스타일 블록 편집기. 렌더 라이브러리와 관심사가 달라 별도 product다.
        .library(name: "RichMarkdownBlockEditor", targets: ["RichMarkdownBlockEditor"]),
        // 코드 블록 확장. opt-in product다 — 코어는 JavaScriptCore도 WebKit도,
        // 3 MB가 넘는 JavaScript 번들도 링크하지 않는다.
        .library(name: "RichMarkdownHighlight", targets: ["RichMarkdownHighlight"]),
        .library(name: "RichMarkdownMermaid", targets: ["RichMarkdownMermaid"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.4.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
    ],
    targets: [
        // Foundation-only. host에서 `swift build --target RichMarkdownCore`로 우선 검증한다.
        .target(
            name: "RichMarkdownCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .target(
            name: "RichMarkdown",
            dependencies: [
                "RichMarkdownCore",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]
        ),
        // UIKit 의존 (TextKit 2 편집기). iOS에서만 빌드된다.
        .target(
            name: "RichMarkdownBlockEditor",
            dependencies: ["RichMarkdown"]
        ),
        // Prism v1.30.0 + JavaScriptCore. 번들 문법 원본과 SHA-256은
        // Docs/CODE_BLOCK_EXTENSIONS.md에 기록한다.
        // `.process`가 아니라 `.copy`를 쓴다: Prism 문법은 이름으로 찾는 스크립트라
        // 빌드 단계가 파일명을 바꾸거나 최적화하면 로드 순서가 깨진다.
        .target(
            name: "RichMarkdownHighlight",
            dependencies: ["RichMarkdown"],
            resources: [.copy("Resources/Prism")],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        // 공식 Mermaid 11.17.2를 WKWebView에서 실행한다. 번들 재생성은
        // Sources/RichMarkdownMermaid/Web (npm ci && npm run build).
        .target(
            name: "RichMarkdownMermaid",
            dependencies: ["RichMarkdown"],
            exclude: ["Web"],
            resources: [.copy("Resources/WebAssets")],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(
            name: "RichMarkdownCoreTests",
            dependencies: ["RichMarkdownCore"]
        ),
        // UIKit 의존 테스트. iOS Simulator의 package scheme에서만 실행한다 (DEVELOPMENT.md §8 CI 원칙).
        .testTarget(
            name: "RichMarkdownTests",
            dependencies: ["RichMarkdown"]
        ),
        .testTarget(
            name: "RichMarkdownBlockEditorTests",
            dependencies: ["RichMarkdownBlockEditor"]
        ),
        // JavaScriptCore·WebKit 의존 테스트. iOS Simulator의 package scheme에서만 실행한다.
        .testTarget(
            name: "RichMarkdownHighlightTests",
            dependencies: ["RichMarkdownHighlight"]
        ),
        .testTarget(
            name: "RichMarkdownMermaidTests",
            dependencies: ["RichMarkdownMermaid"]
        ),
    ]
)
