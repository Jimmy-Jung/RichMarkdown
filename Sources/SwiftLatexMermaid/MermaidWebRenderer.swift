import Foundation
import UIKit
import WebKit

/// Mermaid 표시 실패 사유. 어느 경우든 호출한 뷰가 원문 코드 블록으로 되돌린다.
public enum MermaidError: LocalizedError, Equatable {
    case emptySource
    case sourceTooLarge(utf8Bytes: Int, limit: Int)
    case resourceMissing
    case loadTimeout
    case webContentTerminated
    case invalidSize
    case render(String)

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            return "Mermaid 원문이 비어 있습니다."
        case .sourceTooLarge(let bytes, let limit):
            return "Mermaid 원문이 UTF-8 \(bytes)바이트로 상한 \(limit)바이트를 넘습니다."
        case .resourceMissing:
            return "번들에서 Mermaid 리소스를 찾을 수 없습니다."
        case .loadTimeout:
            return "Mermaid WebView 초기화 시간이 초과되었습니다."
        case .webContentTerminated:
            return "WebKit 콘텐츠 프로세스가 종료되었습니다."
        case .invalidSize:
            return "Mermaid가 유효한 크기를 반환하지 않았습니다."
        case .render(let message):
            return message
        }
    }
}

/// 공식 Mermaid JavaScript를 `WKWebView` 안에서 실행하고, 만들어진 SVG를 그 WebView에 그대로 표시한다.
///
/// 번들된 로컬 파일만 로드한다. 런타임에 스크립트·폰트·이미지를 내려받지 않고,
/// Mermaid 원문은 실행할 코드가 아니라 `callAsyncJavaScript`의 **인자**로만 전달한다.
/// 페이지 안에서의 이동과 링크 실행은 막는다.
@MainActor
public final class MermaidWebRenderer: NSObject, WKNavigationDelegate {
    /// 샘플이 아니라 채팅 본문에 섞이는 다이어그램을 전제로 한 상한이다.
    public static let maxSourceUTF8Bytes = 20_000

    /// 모든 다이어그램 WebView가 같은 콘텐츠 프로세스를 쓰도록 공유한다.
    /// 3 MB가 넘는 `mermaid.bundle.js`를 매번 새 프로세스에서 다시 컴파일하지 않는다.
    private static let processPool = WKProcessPool()

    public let webView: WKWebView

    private var isLoaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeout: Task<Void, Never>?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.processPool
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 세로 스크롤은 바깥 목록이 담당한다. 다이어그램은 확대·좌우 이동만 허용한다.
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 5
        webView.scrollView.showsVerticalScrollIndicator = false
    }

    deinit {
        // 진행 중이던 로드 대기 타이머를 남기지 않는다.
        loadTimeout?.cancel()
    }

    /// 원문을 그려 필요한 표시 높이를 돌려준다. 뷰는 이 높이를 intrinsic content size로 쓴다.
    /// - Parameters:
    ///   - width: 사용 가능한 폭(pt). 이보다 넓은 다이어그램은 축소하고, 좁으면 확대하지 않는다.
    ///   - fontSize: Dynamic Type으로 해석한 본문 크기. Mermaid 라벨 크기에 반영한다.
    public func render(
        source: String,
        dark: Bool,
        width: CGFloat,
        fontSize: CGFloat
    ) async throws -> CGSize {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MermaidError.emptySource
        }
        let bytes = source.utf8.count
        guard bytes <= Self.maxSourceUTF8Bytes else {
            throw MermaidError.sourceTooLarge(utf8Bytes: bytes, limit: Self.maxSourceUTF8Bytes)
        }
        let safeWidth = max(120, min(2_000, floor(width)))

        try await loadIfNeeded()
        try Task.checkCancellation()

        let value = try await webView.callAsyncJavaScript(
            "return await window.renderDiagram(source, dark, width, fontSize)",
            arguments: [
                "source": source,
                "dark": dark,
                "width": Double(safeWidth),
                "fontSize": Double(fontSize),
            ],
            in: nil,
            contentWorld: .page
        )
        guard let result = value as? [String: Any],
              let height = result["height"] as? Double,
              height.isFinite, height > 0, height <= 4_032
        else { throw MermaidError.invalidSize }

        return CGSize(width: safeWidth, height: ceil(height))
    }

    // MARK: - 로드

    private func loadIfNeeded() async throws {
        if isLoaded { return }
        guard let url = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebAssets"
        ) else { throw MermaidError.resourceMissing }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            loadTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.finishLoading(.failure(MermaidError.loadTimeout))
            }
        }
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        loadTimeout?.cancel()
        loadTimeout = nil
        let continuation = loadContinuation
        loadContinuation = nil
        if case .success = result { isLoaded = true }
        continuation?.resume(with: result)
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(error))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoading(.failure(error))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        finishLoading(.failure(MermaidError.webContentTerminated))
    }

    /// 로컬 번들 파일의 최초 로드만 허용한다. 다이어그램 안의 링크 실행과 외부 이동은 막는다.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isLocalFile = action.request.url?.isFileURL == true
        decisionHandler(isLocalFile && action.navigationType != .linkActivated ? .allow : .cancel)
    }
}
