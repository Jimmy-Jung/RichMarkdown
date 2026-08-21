import Foundation
import Testing
@testable import SwiftLatex
@testable import SwiftLatexCore

/// stale generation / latest-wins 게시 계약 (DEVELOPMENT.md §4, §8).
@MainActor
@Suite struct LatexRenderModelTests {

    private func request(_ markdown: String) -> LatexRenderModel.Request {
        LatexRenderModel.Request(
            markdown: markdown,
            parsesDollarMath: false,
            pointSize: 17,
            colorRGBA: 0x000000FF,
            displayScale: 3
        )
    }

    private func waitForIdle(_ model: LatexRenderModel, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.hasOutstandingWork {
            #expect(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 마지막 게시 hop 여유.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test func latestSubmissionWinsPublication() async throws {
        let model = LatexRenderModel()
        for i in 1...20 {
            model.submit(request("버전 \(i) \\(x_{\(i)}\\)"))
        }
        try await waitForIdle(model)

        let document = try #require(model.document)
        #expect(flatText(document).contains("버전 20"), "최신 제출만 게시되어야 한다")
    }

    @Test func twoStagePublicationHydratesMath() async throws {
        let model = LatexRenderModel()
        let submitted = request(#"인라인 \(a+b\) 수식"#)
        model.submit(submitted)
        try await waitForIdle(model)

        let document = try #require(model.document)
        #expect(model.imageRequest == submitted)
        let segments = document.allMathSegments
        #expect(segments.count == 1)
        if let segment = segments.first {
            #expect(model.mathImages[segment] != nil, "hydration 게시 후 수식 이미지가 있어야 한다")
        }
    }

    @Test func mathRenderFailureKeepsSourceOnly() async throws {
        let model = LatexRenderModel()
        model.submit(request(#"고장 \(\frac{\) 수식"#))
        try await waitForIdle(model)

        let document = try #require(model.document)
        for segment in document.allMathSegments where model.mathImages[segment] == nil {
            // 렌더 실패 노드는 이미지 없이 원문 source 유지.
            #expect(!segment.source.isEmpty)
        }
    }

    @Test func cacheMissImmediatelyClearsPreviousDocumentAndExposesLatestFallback() async throws {
        let model = LatexRenderModel()
        model.submit(request(#"이전 문서 \(x^2\)"#))
        try await waitForIdle(model)
        #expect(model.document != nil)

        model.submit(request("최신 원문"))

        #expect(model.document == nil, "cache miss 중에는 이전 문서를 보이면 안 된다")
        #expect(model.parseIdentity == nil)
        #expect(model.mathImages.isEmpty, "이전 수식 이미지도 함께 무효화해야 한다")
        #expect(model.imageRequest == nil)
        #expect(model.fallbackMarkdown == "최신 원문")
    }

    @Test func renderConfigurationChangeKeepsMatchingDocumentAndClearsImages() async throws {
        let model = LatexRenderModel()
        let markdown = #"같은 문서 \(a+b\)"#
        let first = request(markdown)
        model.submit(first)
        try await waitForIdle(model)
        let original = try #require(model.document)
        #expect(model.parseIdentity == first.parseIdentity)

        let reconfigured = LatexRenderModel.Request(
            markdown: markdown,
            parsesDollarMath: false,
            pointSize: 24,
            colorRGBA: 0xFF0000FF,
            displayScale: 2
        )
        model.submit(reconfigured)

        #expect(model.document == original, "parse identity가 같으면 문서를 다시 숨기면 안 된다")
        #expect(model.parseIdentity == reconfigured.parseIdentity)
        #expect(model.mathImages.isEmpty, "새 raster 설정 전에는 이전 이미지를 쓰면 안 된다")
        #expect(model.imageRequest == nil)
        try await waitForIdle(model)
        #expect(model.imageRequest == reconfigured)
    }

    @Test func oversizedRequestUsesBoundedFallbackAsItsParseCacheKey() async throws {
        let model = LatexRenderModel()
        let rawMarkdown = "large-\(UUID().uuidString)\n" + String(
            repeating: "x",
            count: InputLimits.maxInputUTF8Bytes
        )
        model.submit(request(rawMarkdown))

        let fallback = model.fallbackMarkdown
        #expect(fallback.contains(InputLimits.truncationMarker))
        #expect(fallback.utf8.count <= InputLimits.displayPrefixUTF8Bytes + 64)

        try await waitForIdle(model)
        #expect(
            ParseCache.shared.document(
                markdown: fallback,
                parsesDollarMath: false,
                wasTruncated: true
            ) != nil,
            "cache key에는 원본 전체가 아니라 제한된 입력만 사용해야 한다"
        )
    }

    @Test func cacheHitPreservesTruncationState() async throws {
        let rawMarkdown = "truncated-\(UUID().uuidString)\n" + String(
            repeating: "x",
            count: InputLimits.maxInputUTF8Bytes
        )

        let first = LatexRenderModel()
        first.submit(request(rawMarkdown))
        try await waitForIdle(first)
        #expect(first.document?.wasTruncated == true)

        let cached = LatexRenderModel()
        cached.submit(request(rawMarkdown))
        try await waitForIdle(cached)
        #expect(cached.document?.wasTruncated == true, "cache hit도 입력 제한 상태를 보존해야 한다")
    }

    @Test func parseCacheSeparatesTruncationFlagForIdenticalVisibleText() async throws {
        let rawMarkdown = "collision-\(UUID().uuidString)\n" + String(
            repeating: "x",
            count: InputLimits.maxInputUTF8Bytes
        )
        let bounded = InputLimits.bound(rawMarkdown)

        let literal = LatexRenderModel()
        literal.submit(request(bounded.text))
        try await waitForIdle(literal)
        #expect(literal.document?.wasTruncated == false)

        let truncated = LatexRenderModel()
        truncated.submit(request(rawMarkdown))
        try await waitForIdle(truncated)
        #expect(
            truncated.document?.wasTruncated == true,
            "같은 표시 문자열이어도 입력 제한 flag가 다른 cache entry여야 한다"
        )
    }

    @Test func parseCacheCostIncludesDocumentStructureAndSaturates() {
        let markdown = "문단 \\(a+b\\)\n\n또 다른 문단 \\(c+d\\)"
        let document = SwiftLatexParser.parse(markdown: markdown, parsesDollarMath: false)

        let estimated = ParseCache.estimatedCost(for: document, sourceByteCount: markdown.utf8.count)
        #expect(estimated > markdown.utf8.count * 3)
        #expect(ParseCache.estimatedCost(for: document, sourceByteCount: .max) == .max)

        let sameBaseCost = 1_024
        let oneBlock = SwiftLatexParser.parse(markdown: "plain", parsesDollarMath: false)
        let threeBlocks = SwiftLatexParser.parse(markdown: "a\n\nb\n\nc", parsesDollarMath: false)
        let math = SwiftLatexParser.parse(markdown: #"\(a\) \(b\)"#, parsesDollarMath: false)
        #expect(
            ParseCache.estimatedCost(for: threeBlocks, sourceByteCount: sameBaseCost)
                > ParseCache.estimatedCost(for: oneBlock, sourceByteCount: sameBaseCost)
        )
        #expect(
            ParseCache.estimatedCost(for: math, sourceByteCount: sameBaseCost)
                > ParseCache.estimatedCost(for: oneBlock, sourceByteCount: sameBaseCost)
        )
    }

    @Test func stalePreparedParseEntryIsNotStoredInCache() async throws {
        let model = LatexRenderModel()
        let staleMarkdown = "stale-\(UUID().uuidString)\n" + String(repeating: "stale ", count: 20_000)
        let latestMarkdown = "latest-\(UUID().uuidString)"
        model.submit(request(staleMarkdown))
        model.submit(request(latestMarkdown))

        let staleInput = InputLimits.bound(staleMarkdown)
        let staleDocument = SwiftLatexParser.parse(staleInput, parsesDollarMath: false)
        let staleKey = ParseCache.shared.key(
            markdown: staleInput.text,
            parsesDollarMath: false,
            wasTruncated: staleInput.wasTruncated
        )
        let staleEntry = ParseCache.shared.preparedEntry(staleDocument, for: staleKey)

        // generation 1의 parse가 끝난 직후 generation 2가 이미 제출된 상황을 직접 만든다.
        // sleep으로 worker가 parser에 진입했기를 기대하지 않으므로 false-green이 없다.
        model.storeParsedDocumentIfCurrent(staleEntry, generation: 1)

        #expect(
            ParseCache.shared.document(for: staleKey) == nil,
            "stale generation의 parse 결과는 cache에 남으면 안 된다"
        )

        let latestInput = InputLimits.bound(latestMarkdown)
        let latestDocument = SwiftLatexParser.parse(latestInput, parsesDollarMath: false)
        let latestKey = ParseCache.shared.key(
            markdown: latestInput.text,
            parsesDollarMath: false,
            wasTruncated: latestInput.wasTruncated
        )
        let latestEntry = ParseCache.shared.preparedEntry(latestDocument, for: latestKey)
        model.storeParsedDocumentIfCurrent(latestEntry, generation: 2)
        #expect(ParseCache.shared.document(for: latestKey) != nil, "현재 generation은 cache에 저장해야 한다")

        // `submit`이 만든 unstructured worker가 끝난 뒤에도 stale cache entry가 없어야 한다.
        // 다음 테스트가 같은 shared cache/worker 작업을 물려받지 않도록 이 테스트 안에서 배수한다.
        try await waitForIdle(model)
        #expect(ParseCache.shared.document(for: staleKey) == nil)
    }

    /// UIKit 렌더러 요청(`rastersDisplayMath: false`)은 블록 수식을 raster하지 않는다
    /// (Docs/RENDERING_PERFORMANCE_PLAN.md §9.4 부채 해소). 인라인 raster는 유지된다.
    @Test func skipsDisplayMathRasterWhenRequestOptsOut() async throws {
        let model = LatexRenderModel()
        // 처음 보는 latex — raster 캐시가 비어 있어, "raster가 실행되지 않았다"를
        // idle 후에도 캐시가 차지 않았다는 사실로 판정할 수 있다.
        let inlineLatex = "x_{\(UUID().uuidString.prefix(8))}+1"
        let blockLatex = "y_{\(UUID().uuidString.prefix(8))}+2"
        let submitted = LatexRenderModel.Request(
            markdown: "본문 \\(\(inlineLatex)\\) 수식\n\n\\[\(blockLatex)\\]",
            parsesDollarMath: false,
            pointSize: 17,
            colorRGBA: 0x000000FF,
            displayScale: 3,
            rastersDisplayMath: false
        )
        model.submit(submitted)
        try await waitForIdle(model)

        let document = try #require(model.document)
        #expect(model.imageRequest == submitted, "hydration 게시 계약은 그대로다")

        let segments = document.allMathSegments
        let inline = try #require(segments.first { !$0.kind.isDisplay })
        let block = try #require(segments.first { $0.kind.isDisplay })
        #expect(model.mathImages[inline] != nil, "인라인 수식 raster는 유지된다")
        #expect(model.mathImages[block] == nil, "블록 수식 이미지는 게시되지 않는다")

        let blockKey = MathRenderKey(
            latex: block.latex,
            mathFont: submitted.mathFont,
            pointSize: submitted.pointSize,
            colorRGBA: submitted.colorRGBA,
            isDisplay: true,
            displayScale: submitted.displayScale
        )
        #expect(
            MathRenderService.shared.cachedImage(for: blockKey) == nil,
            "블록 수식 raster 자체가 실행되지 않아야 한다 — 캐시가 계속 비어 있다"
        )
    }

    /// 블록 수식만 있는 문서는 기다릴 raster가 없다 — 원문 fallback 단계 없이
    /// 단일 게시(publishComplete)로 끝난다.
    @Test func blockMathOnlyDocumentCompletesWithoutRasterWhenOptedOut() async throws {
        let model = LatexRenderModel()
        let submitted = LatexRenderModel.Request(
            markdown: "\\[z_{\(UUID().uuidString.prefix(8))}+3\\]",
            parsesDollarMath: false,
            pointSize: 17,
            colorRGBA: 0x000000FF,
            displayScale: 3,
            rastersDisplayMath: false
        )
        model.submit(submitted)
        try await waitForIdle(model)

        #expect(model.document != nil)
        #expect(model.mathImages.isEmpty, "필요한 raster가 없으므로 이미지 사전은 빈 채로 완결된다")
        #expect(model.imageRequest == submitted, "빈 사전으로도 완결 게시가 와야 한다")
    }

    private func flatText(_ document: ParsedDocument) -> String {
        document.blocks.map { block -> String in
            if case .paragraph(let runs) = block {
                return runs.map { run -> String in
                    switch run.content {
                    case .text(let s): return s
                    case .math(let seg): return seg.source
                    default: return ""
                    }
                }.joined()
            }
            return ""
        }.joined(separator: "\n")
    }
}
