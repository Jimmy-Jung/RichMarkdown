import Foundation
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexMermaid

/// 실제 `WKWebView`에서 번들 Mermaid를 실행해 검증한다. iOS Simulator에서만 실행된다
/// (DEVELOPMENT.md §8 CI 원칙). WebView가 전역 프로세스 풀을 공유하므로 직렬 실행한다.
@Suite(.serialized) @MainActor struct MermaidRendererTests {

    /// WKWebView는 key window에 붙기 전에는 콘텐츠 프로세스를 띄우지 않아 로드가 끝나지 않는다(실측).
    /// 테스트 번들에는 화면이 없으므로 창을 직접 만든다.
    @MainActor
    private final class Host {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let renderer = MermaidWebRenderer()

        init() {
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.addSubview(renderer.webView)
            renderer.webView.frame = controller.view.bounds
        }

        func tearDown() {
            renderer.webView.removeFromSuperview()
            window.isHidden = true
        }
    }

    // MARK: - 번들

    @Test func bundleShipsMermaidWebAssets() throws {
        let page = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets")
        let script = Bundle.module.url(forResource: "mermaid.bundle", withExtension: "js", subdirectory: "WebAssets")
        let notices = Bundle.module.url(
            forResource: "MERMAID-THIRD-PARTY-NOTICES",
            withExtension: "txt",
            subdirectory: "WebAssets"
        )

        #expect(page != nil)
        #expect(script != nil)
        #expect(notices != nil, "서드파티 고지를 함께 배포해야 한다")

        // 페이지가 외부를 향하지 않는지 확인한다. 런타임 다운로드는 하지 않는 계약이다.
        let html = try String(contentsOf: #require(page), encoding: .utf8)
        #expect(html.contains("connect-src 'none'"))
        #expect(!html.contains("https://"))
    }

    // MARK: - 입력 계약

    @Test func emptySourceFails() async {
        let renderer = MermaidWebRenderer()
        await #expect(throws: MermaidError.emptySource) {
            _ = try await renderer.render(source: "   \n  ", dark: false, width: 320, fontSize: 17)
        }
    }

    @Test func oversizeSourceFailsBeforeTouchingTheWebView() async {
        let renderer = MermaidWebRenderer()
        let source = String(repeating: "flowchart LR\n  A --> B\n", count: 2_000)
        #expect(source.utf8.count > MermaidWebRenderer.maxSourceUTF8Bytes)

        await #expect(throws: MermaidError.self) {
            _ = try await renderer.render(source: source, dark: false, width: 320, fontSize: 17)
        }
    }

    // MARK: - 실제 렌더

    @Test func flowchartRendersWithPositiveHeight() async throws {
        let host = Host()
        defer { host.tearDown() }

        let size = try await host.renderer.render(
            source: "flowchart LR\n  A[입력] --> B{판단}\n  B -->|예| C[출력]\n  B -->|아니오| A",
            dark: false,
            width: 360,
            fontSize: 17
        )

        #expect(size.width == 360)
        #expect(size.height > 0)
        #expect(size.height <= 4_032)

        // 한글 라벨이 실제로 SVG에 들어갔는지 확인한다 — 크기만으로는 내용을 보장하지 못한다.
        let labels = try await host.renderer.webView.callAsyncJavaScript(
            "return document.querySelector('#diagram svg').textContent",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect((labels as? String)?.contains("입력") == true)
    }

    @Test func sequenceDiagramRendersOnTheSameWebView() async throws {
        let host = Host()
        defer { host.tearDown() }

        // 같은 렌더러로 두 번 그린다. 두 번째 호출은 이미 로드된 WebView를 재사용한다.
        _ = try await host.renderer.render(source: "flowchart TD\n  A --> B", dark: false, width: 300, fontSize: 17)
        let size = try await host.renderer.render(
            source: "sequenceDiagram\n  사용자->>앱: 질문\n  앱-->>사용자: 답변",
            dark: true,
            width: 300,
            fontSize: 17
        )

        #expect(size.height > 0)
    }

    @Test func invalidSourceFailsThenRendererRecovers() async throws {
        let host = Host()
        defer { host.tearDown() }

        await #expect(throws: Error.self) {
            _ = try await host.renderer.render(
                source: "flowchart LR\n  A --> ((((",
                dark: false,
                width: 320,
                fontSize: 17
            )
        }

        // 실패 뒤에도 같은 WebView로 다음 다이어그램을 그릴 수 있어야 한다.
        let size = try await host.renderer.render(
            source: "flowchart LR\n  A --> B",
            dark: false,
            width: 320,
            fontSize: 17
        )
        #expect(size.height > 0)
    }

    // MARK: - SwiftLatex 확장점 연결

    @Test func rendererHandlesOnlyMermaidCodeBlocks() {
        let renderer = MermaidDiagramRenderer()
        #expect(renderer.languages == ["mermaid"])

        let options = LatexCodeBlockOptions(diagram: renderer)
        #expect(options.diagramRenderer(for: "mermaid") != nil)
        #expect(options.diagramRenderer(for: "Mermaid") != nil, "언어 이름은 대소문자를 가리지 않는다")
        #expect(options.diagramRenderer(for: "swift") == nil)
        #expect(options.diagramRenderer(for: nil) == nil)
    }

    @Test func diagramViewStartsAtPlaceholderHeight() {
        let view = MermaidDiagramUIView(source: "flowchart LR\n  A --> B")
        #expect(view.intrinsicContentSize.height == MermaidDiagramUIView.placeholderHeight)
        #expect(view.intrinsicContentSize.width == UIView.noIntrinsicMetric)
    }

    @Test func optionsCompareByRendererIdentity() {
        let a = MermaidDiagramRenderer()
        let b = MermaidDiagramRenderer()
        #expect(LatexCodeBlockOptions(diagram: a) == LatexCodeBlockOptions(diagram: a))
        #expect(LatexCodeBlockOptions(diagram: a) != LatexCodeBlockOptions(diagram: b))
        #expect(LatexCodeBlockOptions(diagram: a) != LatexCodeBlockOptions.none)
    }
}
