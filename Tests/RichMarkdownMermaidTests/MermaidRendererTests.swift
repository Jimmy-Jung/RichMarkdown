import Foundation
import Testing
import UIKit
import WebKit
@testable import RichMarkdown
@testable import RichMarkdownMermaid

/// 실제 `WKWebView`에서 번들 Mermaid를 실행해 검증한다. iOS Simulator에서만 실행된다
/// (DEVELOPMENT.md §8 CI 원칙). 실제 Window와 WebView의 수명 순서를 확인하므로 직렬 실행한다.
@Suite(.serialized) @MainActor struct MermaidRendererTests {

    @Test func navigationPolicyDelegateSelectorIsImplemented() {
        let renderer = MermaidWebRenderer()
        #expect(renderer.responds(to: NSSelectorFromString(
            "webView:decidePolicyForNavigationAction:decisionHandler:"
        )))
    }

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

    @MainActor private final class HeldNavigation: NSObject, WKNavigationDelegate {
        var starts = 0
        var finished: WKNavigation?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            starts += 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = navigation
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { throw MermaidError.loadTimeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForJavaScript(_ webView: WKWebView, expression: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let value = try await webView.callAsyncJavaScript("return " + expression, arguments: [:], in: nil, contentWorld: .page)
            if value as? Bool == true { return }
            if Date() > deadline { throw MermaidError.loadTimeout }
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

    @Test func nonFiniteDimensionsFailBeforeLoading() async {
        let renderer = MermaidWebRenderer()
        await #expect(throws: MermaidError.invalidSize) {
            _ = try await renderer.render(source: "flowchart LR; A-->B", dark: false, width: .nan, fontSize: 17)
        }
        await #expect(throws: MermaidError.invalidSize) {
            _ = try await renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: .infinity)
        }
    }

    // MARK: - 실제 렌더

    @Test func concurrentLoadWaitersCancelIndependentlyAndShareOneNavigation() async throws {
        let host = Host()
        defer { host.tearDown() }
        let held = HeldNavigation()
        host.renderer.webView.navigationDelegate = held
        var firstCancelled = false
        let first = Task {
            do {
                _ = try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
            } catch is CancellationError {
                firstCancelled = true
            } catch {
                Issue.record(error)
            }
        }
        defer { first.cancel() }
        try await waitUntil { held.starts == 1 }
        var secondEntered = false
        let second = Task {
            secondEntered = true
            return try await host.renderer.render(source: "flowchart LR; C-->D", dark: true, width: 320, fontSize: 17)
        }
        defer { second.cancel() }
        try await waitUntil { secondEntered }
        first.cancel()
        try await waitUntil { firstCancelled }
        try await waitUntil { held.finished != nil }
        #expect(held.starts == 1)
        host.renderer.webView.navigationDelegate = host.renderer
        host.renderer.webView(host.renderer.webView, didFinish: try #require(held.finished))
        let size = try await second.value
        #expect(size.height > 0)
    }

    @Test func renderDeadlineEndsNativeWaitAndNextRequestReloadsThePage() async throws {
        let host = Host()
        defer { host.tearDown() }
        _ = try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
        _ = try await host.renderer.webView.callAsyncJavaScript(
            "window.renderDiagram = () => new Promise(() => {}); return true",
            arguments: [:], in: nil, contentWorld: .page
        )
        host.renderer.renderTimeoutNanoseconds = 50_000_000
        await #expect(throws: MermaidError.renderTimeout) {
            _ = try await host.renderer.render(source: "flowchart LR; C-->D", dark: false, width: 320, fontSize: 17)
        }
        host.renderer.renderTimeoutNanoseconds = 15_000_000_000
        let size = try await host.renderer.render(source: "flowchart LR; E-->F", dark: false, width: 320, fontSize: 17)
        #expect(size.height > 0)
    }

    @Test func terminationAfterLoadSuccessIsReportedBeforeJavaScriptDispatch() async throws {
        let host = Host()
        defer { host.tearDown() }
        let held = HeldNavigation()
        host.renderer.webView.navigationDelegate = held
        let task = Task {
            try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
        }
        defer { task.cancel() }
        try await waitUntil { held.finished != nil }
        host.renderer.webView.navigationDelegate = host.renderer
        host.renderer.webView(host.renderer.webView, didFinish: try #require(held.finished))
        host.renderer.webViewWebContentProcessDidTerminate(host.renderer.webView)
        await #expect(throws: MermaidError.webContentTerminated) { _ = try await task.value }
    }

    @Test func webKitTerminationErrorMapsToTheRecoverableDomainError() {
        let error = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue)
        #expect(MermaidWebRenderer.normalizeWebError(error) as? MermaidError == .webContentTerminated)
        let unrelated = NSError(domain: "Other", code: error.code)
        #expect(MermaidWebRenderer.normalizeWebError(unrelated) as? MermaidError == nil)
    }

    @Test func cancelledJavaScriptWaitEndsWithoutWaitingForTheDeadline() async throws {
        let host = Host()
        defer { host.tearDown() }
        _ = try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
        _ = try await host.renderer.webView.callAsyncJavaScript(
            "window.renderDiagram = () => { window.cancelTestStarted = true; return new Promise(() => {}); }; return true",
            arguments: [:], in: nil, contentWorld: .page
        )
        var cancelled = false
        let task = Task {
            do {
                _ = try await host.renderer.render(source: "flowchart LR; C-->D", dark: false, width: 320, fontSize: 17)
            } catch is CancellationError { cancelled = true } catch { Issue.record(error) }
        }
        defer { task.cancel() }
        try await waitForJavaScript(host.renderer.webView, expression: "window.cancelTestStarted === true")
        task.cancel()
        try await waitUntil { cancelled }
        let recovered = try await host.renderer.render(source: "flowchart LR; E-->F", dark: false, width: 320, fontSize: 17)
        #expect(recovered.height > 0)
    }

    @Test func displayedViewRecoversFromIndependentAndPendingTerminations() async throws {
        let host = Host()
        defer { host.tearDown() }
        let view = MermaidDiagramUIView(source: "flowchart LR; A-->B")
        host.window.rootViewController?.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
        view.layoutIfNeeded()
        let webView = try #require(view.subviews.compactMap { $0 as? WKWebView }.first)
        let renderer = try #require(webView.navigationDelegate as? MermaidWebRenderer)
        try await waitUntil { webView.alpha == 1 && !webView.isHidden }
        for _ in 0..<2 {
            renderer.webViewWebContentProcessDidTerminate(webView)
            #expect(webView.alpha == 0)
            view.layoutIfNeeded()
            try await waitUntil { webView.alpha == 1 && !webView.isHidden }
        }
        _ = try await webView.callAsyncJavaScript(
            "window.renderDiagram = () => { window.pendingViewStarted = true; return new Promise(() => {}); }; return true",
            arguments: [:], in: nil, contentWorld: .page
        )
        view.source = "flowchart LR; C-->D"
        #expect(webView.alpha == 0)
        view.layoutIfNeeded()
        try await waitForJavaScript(webView, expression: "window.pendingViewStarted === true")
        renderer.webViewWebContentProcessDidTerminate(webView)
        view.layoutIfNeeded()
        try await waitUntil { webView.alpha == 1 && !webView.isHidden }
        view.removeFromSuperview()
    }

    @Test func sourceReplacementHidesTheCommittedDiagramUntilTheNewResult() async throws {
        let host = Host()
        defer { host.tearDown() }
        let view = MermaidDiagramUIView(source: "flowchart LR; A-->B")
        host.window.rootViewController?.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
        view.layoutIfNeeded()
        let webView = try #require(view.subviews.compactMap { $0 as? WKWebView }.first)
        try await waitUntil { webView.alpha == 1 && !webView.isHidden }
        _ = try await webView.callAsyncJavaScript(
            """
            window.renderDiagram = () => new Promise(resolve => window.finishReplacement = () => {
                document.getElementById('diagram').innerHTML = '<svg viewBox="0 0 100 100"><text>newer</text></svg>';
                resolve({width: 320, height: 100});
            }); return true;
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        view.source = "flowchart LR; C-->D"
        #expect(webView.alpha == 0)
        #expect(webView.accessibilityElementsHidden)
        view.layoutIfNeeded()
        try await waitForJavaScript(webView, expression: "typeof window.finishReplacement === 'function'")
        #expect(webView.alpha == 0)
        _ = try await webView.callAsyncJavaScript("window.finishReplacement(); return true", arguments: [:], in: nil, contentWorld: .page)
        try await waitUntil { webView.alpha == 1 && !webView.isHidden }
        #expect(!webView.accessibilityElementsHidden)
        #expect(view.intrinsicContentSize.height == 100)
        view.removeFromSuperview()
    }

    @Test func oversizedViewFallbackIsBoundedAndPreservesTheSource() async throws {
        let host = Host()
        defer { host.tearDown() }
        let source = String(repeating: "가👩‍💻", count: 10_000)
        let view = MermaidDiagramUIView(source: source)
        host.window.rootViewController?.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 64)
        view.layoutIfNeeded()
        let stack = try #require(view.subviews.compactMap { $0 as? UIStackView }.first)
        let text = try #require(stack.arrangedSubviews.compactMap { $0 as? UITextView }.first)
        try await waitUntil { text.text.contains("생략") }
        let prefix = String(text.text.split(separator: "\n", maxSplits: 1)[0])
        #expect(prefix.utf8.count <= MermaidWebRenderer.maxSourceUTF8Bytes)
        #expect(source.hasPrefix(prefix))
        #expect(view.source == source)
        view.removeFromSuperview()
    }

    @Test func concurrentJavaScriptOnlyCommitsLatestDiagram() async throws {
        let host = Host()
        defer { host.tearDown() }
        _ = try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
        let result = try await host.renderer.webView.callAsyncJavaScript(
            """
            const engine = window.mermaid;
            const originalRender = engine.render;
            const originalInitialize = engine.initialize;
            const releases = {};
            let active = 0, maximumActive = 0;
            engine.initialize = () => {};
            engine.render = (id, source) => {
                active++;
                maximumActive = Math.max(maximumActive, active);
                return new Promise(resolve => releases[source] = () => {
                    active--;
                    resolve({svg: '<svg viewBox="0 0 100 100"><text>' + source + '</text></svg>'});
                });
            };
            const tick = () => new Promise(resolve => setTimeout(resolve, 0));
            try {
                const first = window.renderDiagram('older', false, 320, 17).catch(() => null);
                while (!releases.older) await tick();
                const second = window.renderDiagram('newer', true, 320, 17);
                await tick();
                if (releases.newer) {
                    releases.newer();
                    await second;
                    releases.older();
                } else {
                    releases.older();
                    while (!releases.newer) await tick();
                    releases.newer();
                }
                await Promise.all([first, second]);
                return {label: document.querySelector('#diagram svg').textContent, maximumActive};
            } finally {
                engine.render = originalRender;
                engine.initialize = originalInitialize;
            }
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any]
        #expect(result?["label"] as? String == "newer")
        #expect(result?["maximumActive"] as? Int == 1)
    }

    @Test(arguments: ["directive", "frontmatter"])
    func sourceCannotExecuteJavaScriptOrRelaxStrictSecurity(variant: String) async throws {
        let host = Host()
        defer { host.tearDown() }
        let source = variant == "directive" ? """
        %%{init: {"securityLevel":"loose","htmlLabels":true,"flowchart":{"htmlLabels":true},"dompurifyConfig":{"ADD_ATTR":["onerror"]}}}%%
        flowchart LR
          A["<img src=x onerror=window.injected=true>"] --> B["');window.injected=true;//"]
        """
        : """
        ---
        config:
          securityLevel: loose
          htmlLabels: true
          flowchart:
            htmlLabels: true
          dompurifyConfig:
            ADD_ATTR: [onerror]
        ---
        flowchart LR
          A["<img src=x onerror=window.injected=true>"] --> B["');window.injected=true;//"]
        """
        let size = try await host.renderer.render(source: source, dark: false, width: 320, fontSize: 17)
        #expect(size.height > 0)
        let secure = try await host.renderer.webView.callAsyncJavaScript(
            """
            const config = mermaid.mermaidAPI.getConfig();
            return {svg: !!document.querySelector('#diagram svg'), injected: window.injected === true,
              securityLevel: config.securityLevel, htmlLabels: config.htmlLabels, flowchartHTMLLabels: config.flowchart.htmlLabels,
              purifierOverridden: !!config.dompurifyConfig?.ADD_ATTR?.includes('onerror')};
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? [String: Any]
        #expect(secure?["svg"] as? Bool == true)
        #expect(secure?["injected"] as? Bool == false)
        #expect(secure?["securityLevel"] as? String == "strict")
        #expect(secure?["htmlLabels"] as? Bool == false)
        #expect(secure?["flowchartHTMLLabels"] as? Bool == false)
        #expect(secure?["purifierOverridden"] as? Bool == false)
    }

    @Test func contentSecurityPolicyBlocksInlineEventHandlers() async throws {
        let host = Host()
        defer { host.tearDown() }
        _ = try await host.renderer.render(source: "flowchart LR; A-->B", dark: false, width: 320, fontSize: 17)
        let blocked = try await host.renderer.webView.callAsyncJavaScript(
            """
            window.cspProbe = false;
            const image = new Image();
            image.setAttribute('onerror', 'window.cspProbe = true');
            const error = new Promise(resolve => image.addEventListener('error', resolve, {once: true}));
            image.src = 'data:image/png;base64,invalid';
            document.body.appendChild(image);
            await error;
            image.remove();
            return window.cspProbe === false;
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(blocked as? Bool == true)
    }

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

    /// 좁은 다이어그램은 남는 폭을 좌우로 나눠 가진다.
    /// `useMaxWidth: false`라 확대하지 않으므로 세로형 플로우차트는 컨테이너보다 좁아지는데,
    /// 중앙 정렬이 없으면 남는 폭이 전부 오른쪽으로 몰려 왼쪽 끝에 붙는다.
    @Test func narrowDiagramIsHorizontallyCentered() async throws {
        let host = Host()
        defer { host.tearDown() }

        let width: CGFloat = 900
        _ = try await host.renderer.render(
            source: "flowchart TD\n  A[시작] --> B[끝]",
            dark: false,
            width: width,
            fontSize: 17
        )

        let measured = try await host.renderer.webView.callAsyncJavaScript(
            """
            const box = document.getElementById('diagram').getBoundingClientRect();
            const svg = document.querySelector('#diagram svg').getBoundingClientRect();
            return {
                leading: svg.left - box.left,
                trailing: box.right - svg.right,
                svgWidth: svg.width
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String: Any]

        let leading = try #require(measured?["leading"] as? Double)
        let trailing = try #require(measured?["trailing"] as? Double)
        let svgWidth = try #require(measured?["svgWidth"] as? Double)

        // 전제: 이 원문은 컨테이너보다 확실히 좁다. 좁지 않으면 정렬을 검증할 수 없다.
        #expect(svgWidth < Double(width) - 32)
        #expect(abs(leading - trailing) <= 1)
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

    // MARK: - RichMarkdown 확장점 연결

    @Test func rendererHandlesOnlyMermaidCodeBlocks() {
        let renderer = MermaidDiagramRenderer()
        #expect(renderer.languages == ["mermaid"])

        let options = RichMarkdownCodeBlockOptions(diagram: renderer)
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
        #expect(RichMarkdownCodeBlockOptions(diagram: a) == RichMarkdownCodeBlockOptions(diagram: a))
        #expect(RichMarkdownCodeBlockOptions(diagram: a) != RichMarkdownCodeBlockOptions(diagram: b))
        #expect(RichMarkdownCodeBlockOptions(diagram: a) != RichMarkdownCodeBlockOptions.none)
    }
}
