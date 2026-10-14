// Author: JunyoungJung
// Date: 2026-10-14

import Combine
import RichMarkdown
import RichMarkdownCore
import XCTest

/// 렌더 계층(수식 raster·렌더 모델·스트리밍) 마이크로 벤치마크.
///
/// 반복마다 새 cache key를 쓴다: 수식은 색(RGBA)을, 문서는 끝의 공백 줄 길이를 바꾼다.
/// 둘 다 결과 모양을 바꾸지 않으면서 `MathRenderService`·`ParseCache` 적중을 막는다.
final class RenderBenchmarks: XCTestCase {
    private static let pointSize: CGFloat = 17
    /// 기기별 화면 배율과 무관하게 같은 작업량을 재기 위해 3x로 고정한다.
    private static let displayScale: CGFloat = 3
    private static let rendersPerIteration = 10

    @MainActor
    func testMathRasterSimple() {
        benchmarkRaster("math.raster.simple.x10", latex: BenchmarkCorpus.simpleLatex, isDisplay: false)
    }

    @MainActor
    func testMathRasterComplex() {
        benchmarkRaster("math.raster.complex.x10", latex: BenchmarkCorpus.complexLatex, isDisplay: true)
    }

    /// 제출 → worker parse → 수식 raster → 최종 게시(`hasOutstandingWork == false`)까지.
    @MainActor
    func testRenderModelLongEssay() throws {
        let markdown = try BenchmarkCorpus.document(BenchmarkCorpus.streamingDocumentID)
        var serial: UInt32 = 0
        var completed = true
        var imageCount = 0
        benchmark("render.model.longEssay") {
            serial += 1
            let model = RichMarkdownRenderModel()
            model.submit(Self.request(
                markdown + String(repeating: " ", count: Int(serial)),
                colorRGBA: Self.color(serial)
            ))
            completed = Self.spinMainRunLoop { !model.hasOutstandingWork } && completed
            imageCount = model.mathImages.count
        }
        XCTAssertTrue(completed, "렌더 모델이 제한 시간 안에 끝나지 않았다")
        XCTAssertGreaterThan(imageCount, 0)
    }

    /// 20 Hz × 64 스칼라 누적 입력을 실제 스트리밍 경로(`RichMarkdownStreamingTextBuffer` → 렌더 모델)로 흘린다.
    /// 시계 값은 tick 일정(조각 수 × 50 ms)을 포함한 전체 경과다.
    @MainActor
    func testStreaming20HzLongEssay() throws {
        let document = try BenchmarkCorpus.document(BenchmarkCorpus.streamingDocumentID)
        let chunks = BenchmarkCorpus.scalarChunks(of: document, size: BenchmarkCorpus.streamingChunkScalars)
        var serial: UInt32 = 0
        var finalMarkdown: String?
        benchmark("streaming.20Hz.longEssay") {
            serial += 1
            finalMarkdown = Self.stream(chunks, colorRGBA: Self.color(serial))
        }
        XCTAssertEqual(finalMarkdown, document, "마지막 게시가 전체 원문이어야 한다")
    }

    // MARK: - Helpers

    @MainActor
    private func benchmarkRaster(_ name: String, latex: String, isDisplay: Bool) {
        var serial: UInt32 = 0
        var failures = 0
        benchmark(name) {
            let keys = (0..<Self.rendersPerIteration).map { _ in
                serial += 1
                return MathRenderKey(
                    latex: latex,
                    pointSize: Self.pointSize,
                    colorRGBA: Self.color(serial),
                    isDisplay: isDisplay,
                    displayScale: Self.displayScale
                )
            }
            failures += Self.renderAll(keys)
        }
        XCTAssertEqual(failures, 0, "수식 raster가 실패했다")
    }

    /// actor API를 동기 `measure` 블록에서 기다린다. semaphore로 메인 스레드를 막고 기다리면 첫 반복이
    /// 87초 걸렸다(시뮬레이터 실측, 원인 미확인 — 렌더 경로 어딘가가 메인을 기다린다). 런루프를 돌리며 기다린다.
    @MainActor
    private static func renderAll(_ keys: [MathRenderKey]) -> Int {
        let result = RenderResult()
        Task { @MainActor in
            var failed = 0
            for key in keys where await MathRenderService.shared.render(key: key) == nil {
                failed += 1
            }
            result.failures = failed
        }
        _ = spinMainRunLoop { result.failures != nil }
        return result.failures ?? keys.count
    }

    @MainActor
    private static func stream(_ chunks: [String], colorRGBA: UInt32) -> String? {
        let tick = Duration.milliseconds(50)
        let buffer = RichMarkdownStreamingTextBuffer(interval: tick)
        let model = RichMarkdownRenderModel()
        // 데모 SSE 화면처럼 버퍼가 게시한 누적 전체 문자열을 렌더러에 넘긴다.
        let subscription = buffer.$text.dropFirst().sink { text in
            model.submit(request(text, colorRGBA: colorRGBA))
        }
        defer { subscription.cancel() }

        let start = ContinuousClock.now
        for (index, chunk) in chunks.enumerated() {
            buffer.append(chunk)
            let nextTick = start + tick * (index + 1)
            _ = spinMainRunLoop { ContinuousClock.now >= nextTick }
        }
        buffer.flush()
        guard spinMainRunLoop(until: { !model.hasOutstandingWork }) else { return nil }
        return model.parseIdentity?.markdown
    }

    /// 메인 런루프를 돌려 MainActor hop(worker 게시)과 trailing 게시 Task를 처리한다.
    @MainActor
    private static func spinMainRunLoop(timeout: Duration = .seconds(30), until done: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        return true
    }

    private nonisolated static func request(_ markdown: String, colorRGBA: UInt32) -> RichMarkdownRenderModel.Request {
        RichMarkdownRenderModel.Request(
            markdown: markdown,
            parsesDollarMath: false,
            pointSize: pointSize,
            colorRGBA: colorRGBA,
            displayScale: displayScale
        )
    }

    /// 반복마다 다른 불투명 색. raster 비용은 색과 무관하다.
    private nonisolated static func color(_ serial: UInt32) -> UInt32 {
        (serial << 8) | 0xFF
    }
}

@MainActor
private final class RenderResult {
    var failures: Int?
}
