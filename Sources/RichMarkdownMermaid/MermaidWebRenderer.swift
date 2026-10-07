import Foundation
import UIKit
import WebKit

/// Mermaid 표시 실패 사유. 어느 경우든 호출한 뷰가 원문 코드 블록으로 되돌린다.
public enum MermaidError: LocalizedError, Equatable {
    case emptySource
    case sourceTooLarge(utf8Bytes: Int, limit: Int)
    case resourceMissing
    case loadTimeout
    case renderTimeout
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
        case .renderTimeout:
            return "Mermaid 렌더 응답 시간이 초과되었습니다."
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

    public let webView: WKWebView

    private var isLoaded = false
    private var loadWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var loadGeneration: UUID?
    private var loadNavigation: WKNavigation?
    private var loadTimeout: Task<Void, Never>?
    private var serial = 0
    private var pendingRender: (id: Int, continuation: CheckedContinuation<CGSize, Error>)?
    private var renderTimeout: Task<Void, Never>?
    var onContentProcessTermination: (@MainActor () -> Void)?
    private var reportedTermination = false
    // 공개 설정은 추가하지 않는다. 테스트는 완료되지 않는 JS 응답의 deadline만 짧게 주입한다.
    var renderTimeoutNanoseconds: UInt64 = 15_000_000_000

    public override init() {
        let configuration = WKWebViewConfiguration()
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
        renderTimeout?.cancel()
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
        guard width.isFinite, fontSize.isFinite, fontSize > 0 else { throw MermaidError.invalidSize }
        try Task.checkCancellation()
        serial += 1
        let id = serial
        if let previous = pendingRender?.id { finishRender(previous, result: .failure(CancellationError())) }
        let safeWidth = max(120, min(2_000, floor(width)))

        try await loadIfNeeded()
        try Task.checkCancellation()
        guard isLoaded else { throw MermaidError.webContentTerminated }
        guard id == serial else { throw CancellationError() }
        let size = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGSize, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRender = (id, continuation)
                renderTimeout = Task { [weak self] in
                    guard let deadline = self?.renderTimeoutNanoseconds else { return }
                    do { try await Task.sleep(nanoseconds: deadline) } catch { return }
                    guard self?.pendingRender?.id == id else { return }
                    self?.isLoaded = false
                    self?.finishRender(id, result: .failure(MermaidError.renderTimeout))
                }
                webView.callAsyncJavaScript(
                    "return await window.renderDiagram(source, dark, width, fontSize, request)",
                    arguments: ["source": source, "dark": dark, "width": Double(safeWidth), "fontSize": Double(fontSize), "request": id],
                    in: nil, in: .page
                ) { [weak self] result in
                    guard let self, self.pendingRender?.id == id else { return }
                    switch result {
                    case .failure(let error):
                        self.finishRender(id, result: .failure(Self.normalizeWebError(error)))
                    case .success(let value):
                        guard let object = value as? [String: Any],
                              let height = object["height"] as? Double,
                              height.isFinite, height > 0, height <= 4_032 else {
                            self.finishRender(id, result: .failure(MermaidError.invalidSize))
                            return
                        }
                        self.finishRender(id, result: .success(CGSize(width: safeWidth, height: ceil(height))))
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finishRender(id, result: .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return size
    }

    private func finishRender(_ id: Int, result: Result<CGSize, Error>) {
        guard let pending = pendingRender, pending.id == id else { return }
        pendingRender = nil
        renderTimeout?.cancel()
        renderTimeout = nil
        if case .failure(let error) = result {
            if error is CancellationError { isLoaded = false }
            if case MermaidError.webContentTerminated = error { notifyTermination() }
            webView.callAsyncJavaScript("window.cancelDiagram && window.cancelDiagram(request)", arguments: ["request": id], in: nil, in: .page) { _ in }
        }
        pending.continuation.resume(with: result)
    }

    static func normalizeWebError(_ error: Error) -> Error {
        if let webError = error as? WKError, webError.code == .webContentProcessTerminated {
            return MermaidError.webContentTerminated
        }
        return error
    }

    private func notifyTermination() {
        isLoaded = false
        guard !reportedTermination else { return }
        reportedTermination = true
        onContentProcessTermination?()
    }

    // MARK: - 로드

    private func loadIfNeeded() async throws {
        try Task.checkCancellation()
        if isLoaded { return }
        guard let url = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebAssets"
        ) else { throw MermaidError.resourceMissing }

        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loadWaiters[waiter] = continuation
                guard loadGeneration == nil else { return }
                let generation = UUID()
                loadGeneration = generation
                loadNavigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                loadTimeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard self?.loadGeneration == generation else { return }
                    self?.finishLoading(.failure(MermaidError.loadTimeout))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.loadWaiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
                if self.loadWaiters.isEmpty, self.loadGeneration != nil {
                    self.finishLoading(.failure(CancellationError()))
                    self.webView.stopLoading()
                }
            }
        }
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        loadTimeout?.cancel()
        loadTimeout = nil
        loadGeneration = nil
        loadNavigation = nil
        let waiters = loadWaiters
        loadWaiters.removeAll()
        if case .success = result {
            isLoaded = true
            reportedTermination = false
        } else if case .failure(let error) = result,
                  case MermaidError.webContentTerminated = error {
            notifyTermination()
        }
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === loadNavigation else { return }
        finishLoading(.success(()))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === loadNavigation else { return }
        finishLoading(.failure(Self.normalizeWebError(error)))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard let navigation, navigation === loadNavigation else { return }
        finishLoading(.failure(Self.normalizeWebError(error)))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        finishLoading(.failure(MermaidError.webContentTerminated))
        if let pending = pendingRender?.id { finishRender(pending, result: .failure(MermaidError.webContentTerminated)) }
        notifyTermination()
    }

    /// 로컬 번들 파일의 최초 로드만 허용한다. 다이어그램 안의 링크 실행과 외부 이동은 막는다.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let isLocalFile = action.request.url?.isFileURL == true
        decisionHandler(isLocalFile && action.navigationType != .linkActivated ? .allow : .cancel)
    }
}
