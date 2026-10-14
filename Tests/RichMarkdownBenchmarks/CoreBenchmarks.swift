// Author: JunyoungJung
// Date: 2026-10-14

import CryptoKit
import RichMarkdownCore
import XCTest

/// Core(Foundation-only) 파이프라인 마이크로 벤치마크.
final class CoreBenchmarks: XCTestCase {

    /// 입력 규칙 자체의 검사. 크기·SHA-256을 `BENCH_INPUT` 줄로 남겨 Android 입력과 대조한다.
    @MainActor
    func testCorpusMatchesSizeRule() throws {
        for kib in BenchmarkCorpus.sizesKiB {
            let text = try BenchmarkCorpus.corpus(kib: kib)
            let bytes = text.utf8.count
            XCTAssertLessThanOrEqual(bytes, kib * 1024)
            XCTAssertGreaterThan(bytes, kib * 1024 - 4, "스칼라 경계에서만 잘려야 한다")
            BenchmarkOutput.print(tag: "BENCH_INPUT", [
                "name": "corpus.\(kib)KiB",
                "bytes": bytes,
                "sha256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            ])
        }
        let chunks = BenchmarkCorpus.scalarChunks(
            of: try BenchmarkCorpus.document(BenchmarkCorpus.streamingDocumentID),
            size: BenchmarkCorpus.streamingChunkScalars
        )
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.unicodeScalars.count == BenchmarkCorpus.streamingChunkScalars })
    }

    @MainActor func testParse1KiB() throws { try benchmarkParse(kib: 1, dollarMath: false) }
    @MainActor func testParse10KiB() throws { try benchmarkParse(kib: 10, dollarMath: false) }
    @MainActor func testParse50KiB() throws { try benchmarkParse(kib: 50, dollarMath: false) }
    @MainActor func testParse256KiB() throws { try benchmarkParse(kib: 256, dollarMath: false) }
    @MainActor func testParse50KiBDollarMath() throws { try benchmarkParse(kib: 50, dollarMath: true) }

    /// 원문 수식 스캔만. 기존 `MaskRoundTripTests`처럼 barrier 없이 문서 전체를 한 paragraph로 넘긴다
    /// (1차 Markdown 파싱 비용 제외).
    @MainActor
    func testMathScanner50KiB() throws {
        let bytes = Array(try BenchmarkCorpus.corpus(kib: 50).utf8)
        var spanCount = 0
        benchmark("core.mathScanner.50KiB") {
            spanCount = scanSpans(bytes).count
        }
        XCTAssertGreaterThan(spanCount, 0)
    }

    @MainActor
    func testProtectRestore50KiB() throws {
        let bytes = Array(try BenchmarkCorpus.corpus(kib: 50).utf8)
        let spans = scanSpans(bytes)
        var restored: [UInt8] = []
        benchmark("core.protectRestore.50KiB") {
            let masked = MathProtector.protect(bytes: bytes, spans: spans)
            restored = MathProtector.restore(masked: masked, original: bytes, spans: spans)
        }
        XCTAssertEqual(restored, bytes)
    }

    // MARK: - Helpers

    @MainActor
    private func benchmarkParse(kib: Int, dollarMath: Bool) throws {
        let markdown = try BenchmarkCorpus.corpus(kib: kib)
        var blockCount = 0
        benchmark("core.parse.\(kib)KiB.dollar\(dollarMath ? "On" : "Off")") {
            blockCount = RichMarkdownParser.parse(markdown: markdown, parsesDollarMath: dollarMath).blocks.count
        }
        XCTAssertGreaterThan(blockCount, 0)
    }

    private func scanSpans(_ bytes: [UInt8]) -> [ProtectedMathSpan] {
        MathScanner(
            bytes: bytes,
            forbiddenRanges: [],
            paragraphRanges: [0..<bytes.count],
            dollarMath: []
        ).scan().spans
    }
}
