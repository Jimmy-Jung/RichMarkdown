// Author: JunyoungJung
// Date: 2026-10-15

import SwiftUI
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// SwiftUI 스트리밍 갱신 1회의 동기 비용(시뮬레이터 마이크로 벤치마크). 기본은 건너뛴다.
///
/// ```
/// TEST_RUNNER_RICHMARKDOWN_MICRO_SWIFTUI=1 xcodebuild test -scheme RichMarkdown-Package \
///   -configuration Release ENABLE_TESTABILITY=YES \
///   -only-testing:RichMarkdownTests/SwiftUIStreamingUpdateBenchmarks …
/// ```
///
/// 루트 대입 + `layoutIfNeeded()`(body·Text 해석·CoreText·레이아웃)만 잰다. CA commit·렌더 서버는
/// 빠진다. 결과는 로그의 `MICRO` 줄(중앙값·p90, ms)이다. 판정은 기기 측정이 한다.
@MainActor
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RICHMARKDOWN_MICRO_SWIFTUI"] == "1")
)
struct SwiftUIStreamingUpdateBenchmarks {
    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// SSE 데모 본문과 같은 구조(ScrollView 안 카드)에 스트리밍 중인 `RichMarkdownView`.
    private struct TranscriptHarness: View {
        let markdown: String

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RichMarkdownView(markdown: markdown)
                        .richMarkdownStreaming(.default)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Color.clear.frame(height: 1)
                }
                .padding(16)
            }
        }
    }

    /// 꼬리 문단 블록 하나. 문서 하위 뷰가 tail 블록에 넘기는 것과 같은 입력이다.
    private struct TailHarness: View {
        static let tail = RichMarkdownStreamingTailContext(options: .default, dollarMath: [])
        let block: ParsedBlock

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RichMarkdownBlockView(block: block, images: [:], tail: Self.tail)
                        .equatable()
                }
                .padding(16)
            }
        }
    }

    private func host<Content: View>(_ view: Content) -> (UIHostingController<Content>, UIWindow) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// `chunk` grapheme씩 자른 누적 prefix.
    private func prefixes(of text: String, chunk: Int) -> [String] {
        let characters = Array(text)
        return stride(from: chunk, through: characters.count, by: chunk).map { String(characters[..<$0]) }
    }

    private func report(_ name: String, _ samples: [Duration]) {
        let ms = samples.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1e3 }
            .sorted()
        guard !ms.isEmpty else { return }
        let median = ms[ms.count / 2]
        let p90 = ms[min(ms.count - 1, Int(Double(ms.count) * 0.9))]
        print(String(format: "MICRO %@ n=%d median=%.3fms p90=%.3fms", name, ms.count, median, p90))
    }

    /// 부모가 새 누적 markdown을 넘긴 직후, parse 결과가 게시되기 전의 갱신(`pre`).
    /// 틱마다 40 ms를 쉬어 parse 게시(`post`)가 다음 틱 전에 끝나게 한다.
    @Test func preUpdateOfLongDocument() async throws {
        let markdown = try String(
            contentsOf: Self.fixturesDirectory.appendingPathComponent("samples/long-essay-mixed.md"),
            encoding: .utf8
        )
        let steps = prefixes(of: markdown, chunk: 12)
        let start = steps.count / 2
        let (controller, window) = host(TranscriptHarness(markdown: steps[start]))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))

        var samples: [Duration] = []
        for (index, step) in steps[(start + 1)...].enumerated() {
            let begin = ContinuousClock.now
            controller.rootView = TranscriptHarness(markdown: step)
            controller.view.layoutIfNeeded()
            if index >= 10 { samples.append(ContinuousClock.now - begin) }
            try await Task.sleep(for: .milliseconds(40))
        }
        report("pre-update long-essay-mixed", samples)

        // 바닥값: 같은 markdown을 다시 넘기는 갱신(루트 대입·호스팅 레이아웃 비용).
        var floor: [Duration] = []
        for _ in 0..<100 {
            let begin = ContinuousClock.now
            controller.rootView = TranscriptHarness(markdown: markdown)
            controller.view.layoutIfNeeded()
            floor.append(ContinuousClock.now - begin)
            try await Task.sleep(for: .milliseconds(5))
        }
        report("same-markdown floor long-essay-mixed", floor)
    }

    private static let plainParagraph = String(repeating: """
    선형 회귀는 입력과 출력의 관계를 직선으로 근사하는 가장 기본적인 지도 학습 모델입니다. \
    계산이 빠르고 계수를 그대로 해석할 수 있어서, 복잡한 모델을 시도하기 전에 기준선으로 먼저 학습해 보는 \
    경우가 많습니다. It is surprisingly hard to beat on small tabular datasets.
    """, count: 3)

    private static let styledParagraph = String(repeating: """
    선형 회귀는 **입력과 출력**의 관계를 *직선*으로 근사하는 모델이며 `fit(x, y)` 한 줄로 학습합니다. \
    자세한 내용은 [문서](https://example.com/docs)를 보고, ~~예전 방식~~ 대신 **표준화**를 먼저 합니다. \
    It is surprisingly hard to beat on small tabular datasets.
    """, count: 3)

    /// 꼬리 문단이 12자씩 자랄 때 tail 블록 한 개의 갱신(`post`의 블록 몫).
    @Test(arguments: ["plain", "styled"])
    func tailParagraphUpdate(_ kind: String) async throws {
        let paragraph = kind == "plain" ? Self.plainParagraph : Self.styledParagraph
        let blocks = prefixes(of: paragraph, chunk: 12).compactMap {
            RichMarkdownParser.parse(markdown: $0, parsesDollarMath: false).blocks.last
        }
        let (controller, window) = host(TailHarness(block: blocks[0]))
        defer { window.isHidden = true }

        var samples: [Duration] = []
        for round in 0..<3 {
            for (index, block) in blocks.enumerated() {
                let begin = ContinuousClock.now
                controller.rootView = TailHarness(block: block)
                controller.view.layoutIfNeeded()
                if round > 0 || index >= 5 { samples.append(ContinuousClock.now - begin) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        report("tail-paragraph \(kind) chars=\(paragraph.count)", samples)
    }
}
