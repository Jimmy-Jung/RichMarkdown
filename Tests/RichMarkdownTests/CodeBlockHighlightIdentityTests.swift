// 2026-10-06
import SwiftUI
import Testing
import UIKit
@testable import RichMarkdown

/// 실제 SwiftUI state를 유지한 채 요청 입력을 바꾼다. 반환 시점은 continuation으로 제어한다.
@MainActor
@Suite(.serialized)
struct CodeBlockHighlightIdentityTests {
    @MainActor
    private final class GatedHighlighter: RichMarkdownSyntaxHighlighting {
        private(set) var languages: [String] = []
        private(set) var completed = 0
        private var pending: [Int: CheckedContinuation<[RichMarkdownHighlightSpan], Never>] = [:]

        nonisolated func spans(for code: String, language: String) async -> [RichMarkdownHighlightSpan] {
            await request(language: language)
        }

        private func request(language: String) async -> [RichMarkdownHighlightSpan] {
            let index = languages.count
            languages.append(language)
            let spans = await withCheckedContinuation { pending[index] = $0 }
            completed += 1
            return spans
        }

        func finish(_ index: Int, spans: [RichMarkdownHighlightSpan]) {
            pending.removeValue(forKey: index)?.resume(returning: spans)
        }

        func finishPending() {
            let continuations = Array(pending.values)
            pending.removeAll()
            continuations.forEach { $0.resume(returning: []) }
        }
    }

    private let code = "let value = 1"
    private var colored: [RichMarkdownHighlightSpan] {
        [.init(range: NSRange(location: 0, length: code.utf16.count), kind: .keyword)]
    }

    private func content(language: String, highlighter: GatedHighlighter?) -> AnyView {
        var theme = RichMarkdownTheme.default
        theme.textColor = .black
        theme.syntax.keyword = Color(red: 1, green: 0, blue: 1)
        return AnyView(CodeBlockView(language: language, code: code)
            .richMarkdownTheme(theme)
            .richMarkdownCodeBlocks(.init(highlighter: highlighter)))
    }

    private func host(_ content: AnyView) -> (UIHostingController<AnyView>, UIWindow) {
        let controller = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// 글꼴·header는 검은색이고 keyword만 magenta라 이전 결과의 표시를 직접 구별한다.
    private func hasHighlight(in view: UIView) -> Bool {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
            view.layer.render(in: $0.cgContext)
        }
        guard let cgImage = image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] > 220 && pixels[$0 + 1] < 40 && pixels[$0 + 2] > 220
        }
    }

    private func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "SwiftUI가 요청 또는 표시를 제한 시간 안에 갱신해야 한다 (호출 줄: \(line))")
    }

    @Test func languageProviderAndRemovalResetActualSwiftUIHighlight() async throws {
        let first = GatedHighlighter()
        let second = GatedHighlighter()
        let (controller, window) = host(content(language: "swift", highlighter: first))
        defer {
            first.finishPending()
            second.finishPending()
            window.isHidden = true
        }
        try await waitUntil { first.languages == ["swift"] }
        first.finish(0, spans: colored)
        try await waitUntil { hasHighlight(in: controller.view) }

        controller.rootView = content(language: "unsupported", highlighter: first)
        try await waitUntil { first.languages == ["swift", "unsupported"] }
        #expect(!hasHighlight(in: controller.view), "새 언어의 결과가 오기 전에도 이전 색은 사라져야 한다")
        first.finish(1, spans: [])
        try await waitUntil { !hasHighlight(in: controller.view) }

        controller.rootView = content(language: "unsupported", highlighter: second)
        try await waitUntil { second.languages == ["unsupported"] }
        second.finish(0, spans: colored)
        try await waitUntil { hasHighlight(in: controller.view) }

        controller.rootView = content(language: "unsupported", highlighter: nil)
        try await waitUntil { !hasHighlight(in: controller.view) }
    }

    @Test func oldProviderCannotPublishAfterReplacement() async throws {
        let first = GatedHighlighter()
        let second = GatedHighlighter()
        let (controller, window) = host(content(language: "swift", highlighter: first))
        defer {
            first.finishPending()
            second.finishPending()
            window.isHidden = true
        }
        try await waitUntil { first.languages == ["swift"] }
        controller.rootView = content(language: "swift", highlighter: second)
        try await waitUntil { second.languages == ["swift"] }
        second.finish(0, spans: [])
        first.finish(0, spans: colored)
        try await waitUntil { first.completed == 1 && second.completed == 1 }
        try await waitUntil { !hasHighlight(in: controller.view) }
        #expect(!hasHighlight(in: controller.view))
    }
}
