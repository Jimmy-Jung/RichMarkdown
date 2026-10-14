// Author: JunyoungJung
// Date: 2026-10-14

import CryptoKit
import Foundation
import Testing
import UIKit
import WebKit
@testable import RichMarkdownMermaid

/// Mermaid 보안 페이로드(Tests/Fixtures/README.md §8)와 WebView 보안 설정 기준표 고정.
///
/// 페이로드는 실행되면 `window.__richmarkdownPwned`를 1로 만든다. 통과 조건은 렌더 완료(또는
/// 거부) 뒤 값이 0, 최초 로컬 로드 외 네비게이션 0건, 로컬 파일 외 리소스 로드 0건이다.
/// 렌더 뒤 다이어그램의 모든 요소에 클릭을 흘려 `click` 콜백·링크 페이로드도 시도한다.
@Suite(.serialized) @MainActor struct MermaidSecurityPayloadTests {

    /// `#filePath` 두 단계 위의 `Fixtures/security/mermaid`.
    nonisolated static let payloadDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/security/mermaid", isDirectory: true)

    nonisolated static let payloads: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: payloadDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".mmd") }.sorted()
    }()

    /// 기준표의 CSP. 바꾸려면 이 문자열과 Android `index.html`을 함께 갱신한다.
    static let expectedContentSecurityPolicy = "default-src 'none'; "
        + "script-src 'self' 'sha256-owS6vspznh+XfsKdMf/uPhpgCs0AR1cHc7Qqzp3EtJI='; "
        + "style-src 'self' 'unsafe-inline'; img-src data:; font-src 'self' data:; "
        + "connect-src 'none'; object-src 'none'; base-uri 'none'"

    /// fixture의 `expect`와 실제 결과가 다른 항목(Tests/Fixtures는 이 suite가 고치지 않는다).
    /// 보안 검사(실행·네비게이션·외부 요청)는 그대로 적용한다. fixture가 고쳐지면 아래
    /// "더는 재현되지 않는다" 실패로 목록 정리를 요구한다.
    static let knownExpectationMismatches: [String: String] = [:]

    // MARK: - 하네스

    /// WKWebView는 key window에 붙어야 로드가 끝난다(MermaidRendererTests와 같은 이유).
    @MainActor private final class Host {
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

    /// 렌더러 앞에 끼워 네비게이션 판정을 기록하는 프록시. 판정 자체는 렌더러가 내린다.
    @MainActor private final class NavigationRecorder: NSObject, WKNavigationDelegate {
        struct Decision {
            let url: URL?
            let type: WKNavigationType
            let policy: WKNavigationActionPolicy
        }

        private let renderer: MermaidWebRenderer
        private(set) var decisions: [Decision] = []
        private(set) var provisionalStarts = 0

        init(renderer: MermaidWebRenderer) {
            self.renderer = renderer
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = action.request.url
            let type = action.navigationType
            renderer.webView(webView, decidePolicyFor: action) { policy in
                self.decisions.append(Decision(url: url, type: type, policy: policy))
                decisionHandler(policy)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            provisionalStarts += 1
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            renderer.webView(webView, didFinish: navigation)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            renderer.webView(webView, didFail: navigation, withError: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            renderer.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            renderer.webViewWebContentProcessDidTerminate(webView)
        }
    }

    private enum Expectation: String {
        case rendered, rejected
    }

    private func expectation(of source: String) throws -> Expectation {
        let firstLine = String(source.prefix { $0 != "\n" })
        let marker = "%% expect: "
        try #require(firstLine.hasPrefix(marker), "첫 줄에 `%% expect:` 주석이 있어야 한다")
        return try #require(Expectation(rawValue: String(firstLine.dropFirst(marker.count))))
    }

    /// 렌더러가 원문을 거부한 오류인가. 로드·응답 시간 초과나 프로세스 종료는 인프라 실패다.
    private func isRejection(_ error: Error) -> Bool {
        if let error = error as? MermaidError {
            switch error {
            case .sourceTooLarge, .render, .invalidSize: return true
            default: return false
            }
        }
        if let error = error as? WKError {
            // callAsyncJavaScript는 throw와 rejected Promise를 모두 이 코드로 올린다.
            return error.code == .javaScriptExceptionOccurred
        }
        return false
    }

    private func evaluate(_ webView: WKWebView, _ body: String) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        return try #require(value as? [String: Any])
    }

    // MARK: - 페이로드

    @Test func payloadFixturesArePresent() {
        #expect(Self.payloads.count == 18, "security/mermaid 페이로드 18종을 읽어야 한다: \(Self.payloads)")
    }

    @Test(arguments: payloads)
    func payloadNeitherExecutesNorLeavesTheBundle(_ file: String) async throws {
        let source = try String(contentsOf: Self.payloadDirectory.appendingPathComponent(file), encoding: .utf8)
        let expected = try expectation(of: source)

        let host = Host()
        defer { host.tearDown() }
        let webView = host.renderer.webView
        let recorder = NavigationRecorder(renderer: host.renderer)
        webView.navigationDelegate = recorder
        defer { webView.navigationDelegate = host.renderer }

        // 페이지를 먼저 로드해 감시 장치를 건다. `__richmarkdownPwn`은 click callback 페이로드가
        // 부르는 이름이다 — 호출되면 실행된 것이다.
        _ = try await host.renderer.render(source: "graph TD\n  A --> B", dark: false, width: 320, fontSize: 17)
        let armed = try await evaluate(webView, """
            window.__richmarkdownPwned = 0;
            window.__richmarkdownPwn = () => { window.__richmarkdownPwned = 1; };
            window.__richmarkdownViolations = [];
            document.addEventListener('securitypolicyviolation', event => {
                window.__richmarkdownViolations.push(event.violatedDirective + ' ' + event.blockedURI);
            });
            return {href: location.href};
            """)
        let initialHref = try #require(armed["href"] as? String)

        let outcome: Result<CGSize, Error>
        do {
            outcome = .success(try await host.renderer.render(source: source, dark: false, width: 320, fontSize: 17))
        } catch {
            outcome = .failure(error)
        }
        let mismatch: String?
        switch (expected, outcome) {
        case (.rendered, .success(let size)):
            #expect(size.height > 0)
            mismatch = nil
        case (.rejected, .failure(let error)):
            #expect(isRejection(error), "거부는 렌더러 오류여야 한다: \(error)")
            mismatch = nil
        case (.rendered, .failure(let error)):
            mismatch = "rendered 예상인데 실패했다: \(error)"
        case (.rejected, .success(let size)):
            mismatch = "rejected 예상인데 그려졌다: \(size)"
        }
        switch (mismatch, Self.knownExpectationMismatches[file]) {
        case (let mismatch?, let reason?):
            withKnownIssue(Comment(rawValue: reason)) { Issue.record(Comment(rawValue: mismatch)) }
        case (let mismatch?, nil):
            Issue.record(Comment(rawValue: mismatch))
        case (nil, _?):
            Issue.record("\(file)의 known mismatch가 더는 재현되지 않는다 — 목록에서 지운다")
        case (nil, nil):
            break
        }

        // 사용자가 다이어그램을 누른 것처럼 모든 요소에 click을 보낸다(링크 기본 동작 포함).
        let state = try await evaluate(webView, """
            for (const element of document.querySelectorAll('#diagram *')) {
                element.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}));
            }
            await new Promise(resolve => setTimeout(resolve, 300));
            return {
                pwned: window.__richmarkdownPwned,
                href: location.href,
                resources: performance.getEntriesByType('resource').map(entry => entry.name),
                navigations: performance.getEntriesByType('navigation').map(entry => entry.name),
                violations: window.__richmarkdownViolations
            };
            """)

        #expect((state["pwned"] as? NSNumber)?.intValue == 0, "페이로드가 실행됐다")
        #expect(state["href"] as? String == initialHref, "페이지가 다른 곳으로 이동했다")
        let resources = state["resources"] as? [String] ?? []
        #expect(resources.allSatisfy { $0.hasPrefix("file:") }, "로컬 파일이 아닌 리소스를 불렀다: \(resources)")
        #expect((state["navigations"] as? [String])?.count == 1, "네비게이션은 최초 로드 1건이다")
        #expect(
            (state["violations"] as? [String] ?? []).isEmpty,
            "살균을 통과해 CSP에서야 막힌 시도가 있다: \(String(describing: state["violations"]))"
        )

        Attachment.record(
            recorder.decisions.map { "\($0.policy == .allow ? "allow" : "cancel") \($0.type.rawValue) \($0.url?.absoluteString ?? "nil")" }
                .joined(separator: "\n"),
            named: "\(file).navigation.txt"
        )
        let allowed = recorder.decisions.filter { $0.policy == .allow }
        #expect(allowed.count == 1, "허용된 네비게이션은 최초 로컬 로드 1건이다: \(allowed.map(\.url))")
        #expect(allowed.first?.url?.isFileURL == true)
        #expect(recorder.provisionalStarts == 1, "최초 로드 외 네비게이션이 시작됐다")
        if source.contains("click A href") {
            // strict 모드도 https 링크는 SVG `<a>`로 남긴다. click sweep이 실제 링크 이동을 시도했고
            // 판정 함수가 그것을 막았음을 확인한다 — 시도가 없으면 이 검사 자체가 무력하다.
            #expect(
                recorder.decisions.contains { $0.type == .linkActivated && $0.policy == .cancel },
                "외부 링크 클릭 시도가 기록되지 않았다"
            )
        }
    }

    // MARK: - 보안 설정 기준표

    @Test func webViewConfigurationMatchesHardeningTable() {
        let renderer = MermaidWebRenderer()
        let webView = renderer.webView
        let configuration = webView.configuration

        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false, "새 창 금지")
        #expect(configuration.websiteDataStore.isPersistent == false, "비영속 저장소")
        #expect(configuration.userContentController.userScripts.isEmpty, "주입 스크립트 없음")
        #expect(webView.uiDelegate == nil, "새 창·alert를 받아 줄 UI delegate가 없다")
        #expect(webView.navigationDelegate === renderer, "네비게이션 판정은 렌더러가 한다")
        if #available(iOS 16.4, *) {
            #expect(webView.isInspectable == false, "Web Inspector 비활성")
        }
    }

    @Test func contentSecurityPolicyMatchesTheTableAndHashesTheInlineScript() throws {
        let page = try #require(Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets"))
        let html = try String(contentsOf: page, encoding: .utf8)

        let metaPrefix = #"<meta http-equiv="Content-Security-Policy" content=""#
        let afterMeta = try #require(html.range(of: metaPrefix)).upperBound
        let policyEnd = try #require(html[afterMeta...].firstIndex(of: "\""))
        #expect(String(html[afterMeta..<policyEnd]) == Self.expectedContentSecurityPolicy)
        #expect(html.components(separatedBy: "Content-Security-Policy").count == 2, "CSP meta는 하나다")

        // 정책의 sha256은 유일한 인라인 스크립트의 해시여야 한다. 스크립트만 고치고 정책을
        // 갱신하지 않으면 렌더가 깨지고, 정책을 다른 스크립트로 넓히면 여기서 드러난다.
        let inlineOpen = try #require(html.range(of: "<script>"))
        let inlineClose = try #require(html.range(of: "</script>", range: inlineOpen.upperBound..<html.endIndex))
        let inline = html[inlineOpen.upperBound..<inlineClose.lowerBound]
        let digest = Data(SHA256.hash(data: Data(inline.utf8))).base64EncodedString()
        #expect(Self.expectedContentSecurityPolicy.contains("'sha256-\(digest)'"))
        #expect(html.components(separatedBy: "<script").count == 3, "외부 번들 1개 + 인라인 1개")
    }

    @MainActor private final class StubNavigationAction: WKNavigationAction {
        private let stubRequest: URLRequest
        private let stubType: WKNavigationType

        init(url: URL, type: WKNavigationType) {
            stubRequest = URLRequest(url: url)
            stubType = type
            super.init()
        }

        override var request: URLRequest { stubRequest }
        override var navigationType: WKNavigationType { stubType }
    }

    @MainActor private final class PolicyBox {
        var policy: WKNavigationActionPolicy?
    }

    /// 판정 함수 단위 고정: 로컬 파일이면서 링크 클릭이 아닐 때만 허용한다.
    @Test(arguments: [
        ("file:///bundle/WebAssets/index.html", WKNavigationType.other, true),
        ("file:///bundle/WebAssets/index.html", WKNavigationType.reload, true),
        ("file:///bundle/WebAssets/index.html", WKNavigationType.linkActivated, false),
        ("file:///etc/passwd", WKNavigationType.linkActivated, false),
        ("https://evil.example/exfil", WKNavigationType.linkActivated, false),
        ("https://evil.example/exfil", WKNavigationType.other, false),
        ("javascript:window.__richmarkdownPwned=1", WKNavigationType.other, false),
        // `<`·`>`를 인코딩해 둔다: iOS 16 `URL(string:)`은 규격 밖 글자가 있으면 nil이라 테스트가 URL을 만들지 못한다.
        ("data:text/html,%3Cscript%3E1%3C/script%3E", WKNavigationType.other, false),
        ("about:blank", WKNavigationType.other, false),
    ])
    func navigationPolicyAllowsOnlyNonLinkLocalLoads(_ url: String, _ type: WKNavigationType, _ allowed: Bool) throws {
        let renderer = MermaidWebRenderer()
        let action = StubNavigationAction(url: try #require(URL(string: url)), type: type)
        let box = PolicyBox()
        renderer.webView(renderer.webView, decidePolicyFor: action) { box.policy = $0 }
        #expect(box.policy == (allowed ? .allow : .cancel), "\(url) [\(type.rawValue)]")
    }
}
