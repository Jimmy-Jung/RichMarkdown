// Author: JunyoungJung
// Date: 2026-10-14

import RichMarkdown
import SwiftUI
import UIKit
import XCTest

/// UIKit 렌더러가 스트리밍 중 다이어그램 뷰를 몇 번 새로 만드는가 (DEVELOPMENT.md §7 «미검증»).
///
/// 실제 `MermaidDiagramRenderer.makeUIView`는 호출마다 `MermaidDiagramUIView`(WKWebView)를 만든다.
/// 여기서는 같은 프로토콜의 계수기를 꽂아 호출 수 = WKWebView 생성 수로 센다(WebKit 비용은 빠진 하한).
/// 입력은 `samples/mermaid-and-code.md` 뒤에 `long-essay-mixed.md`를 이어(다이어그램이 닫힌 뒤에도 스트림이
/// 80 tick 넘게 이어지도록) 20 Hz × 64 스칼라로 누적한다. 재사용되면 생성 수는 1이어야 한다.
final class DiagramStreamingBenchmarks: XCTestCase {

    @MainActor
    func testUIKitStreamingMermaidDiagramViewChurn() throws {
        let document = try BenchmarkCorpus.document("mermaid-and-code") + "\n\n"
            + BenchmarkCorpus.document(BenchmarkCorpus.streamingDocumentID)
        // 데모 SSE처럼 더 잘게 보낼 때의 생성 수를 보려면 RICHMARKDOWN_BENCH_CHUNK_SCALARS로 조각 크기를 바꾼다.
        let size = ProcessInfo.processInfo.environment["RICHMARKDOWN_BENCH_CHUNK_SCALARS"].flatMap(Int.init)
            ?? BenchmarkCorpus.streamingChunkScalars
        let chunks = BenchmarkCorpus.scalarChunks(of: document, size: size)
        let renderer = CountingDiagramRenderer()
        var creations: [Int] = []
        benchmark("streaming.uikit.mermaid.20Hz") {
            renderer.created = 0
            Self.stream(chunks, renderer: renderer)
            creations.append(renderer.created)
        }
        BenchmarkOutput.print(tag: "BENCH_EVIDENCE", [
            "name": "streaming.uikit.mermaid.20Hz",
            "chunkScalars": size,
            "chunks": chunks.count,
            "diagramViewCreationsPerRun": creations,
        ])
        XCTAssertGreaterThan(creations.last ?? 0, 0, "다이어그램 뷰가 한 번도 만들어지지 않았다")
    }

    @MainActor
    private static func stream(_ chunks: [String], renderer: CountingDiagramRenderer) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let view = RichMarkdownUIView()
        view.codeBlocks = RichMarkdownCodeBlockOptions(diagram: renderer)
        view.streaming = .default
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: window.topAnchor),
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
        ])
        window.isHidden = false

        let tick = Duration.milliseconds(50)
        let start = ContinuousClock.now
        var markdown = ""
        for (index, chunk) in chunks.enumerated() {
            markdown += chunk
            view.markdown = markdown
            window.layoutIfNeeded()
            let nextTick = start + tick * (index + 1)
            while ContinuousClock.now < nextTick {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
        }
        // 스트림 종료: 표시 옵션을 끄고 마지막 게시·rebuild가 끝나도록 잠깐 돌린다.
        view.streaming = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        window.isHidden = true
    }
}

/// 생성 횟수를 센다. 높이는 고정이라 `onSizeChange`를 부르지 않는다.
@MainActor
private final class CountingDiagramRenderer: RichMarkdownDiagramRendering {
    nonisolated let languages: Set<String> = ["mermaid"]
    var created = 0

    func makeUIView(
        source: String,
        theme: RichMarkdownTheme,
        onSizeChange: @escaping @MainActor () -> Void
    ) -> UIView {
        created += 1
        let view = UIView()
        view.accessibilityIdentifier = Self.viewIdentifier
        view.heightAnchor.constraint(equalToConstant: 200).isActive = true
        return view
    }

    /// 실제 `MermaidDiagramRenderer`처럼 자기 뷰는 원문만 바꿔 재사용한다(WKWebView 생성 없음).
    func updateUIView(_ view: UIView, source: String, theme: RichMarkdownTheme) -> Bool {
        view.accessibilityIdentifier == Self.viewIdentifier
    }

    func makeSwiftUIView(source: String, theme: RichMarkdownTheme) -> AnyView {
        AnyView(EmptyView())
    }

    private static let viewIdentifier = "bench.diagram"
}
