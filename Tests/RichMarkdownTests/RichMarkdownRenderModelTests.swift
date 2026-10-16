import Combine
import Foundation
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// stale generation / latest-wins 게시 계약 (DEVELOPMENT.md §4, §8).
@MainActor
@Suite struct RichMarkdownRenderModelTests {

    private func request(_ markdown: String) -> RichMarkdownRenderModel.Request {
        RichMarkdownRenderModel.Request(
            markdown: markdown,
            parsesDollarMath: false,
            pointSize: 17,
            colorRGBA: 0x000000FF,
            displayScale: 3
        )
    }

    private func waitForIdle(_ model: RichMarkdownRenderModel, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.hasOutstandingWork {
            #expect(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // 마지막 게시 hop 여유.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    /// 스트리밍 prefix 판정은 `String.hasPrefix`와 같다 — 바이트 지름길이 grapheme·정규화 경계에서 갈리지 않는다.
    @Test(arguments: [
        ("가나다", "가나다라"),
        ("", "abc"),
        ("abc", "abd"),
        ("abc", "ab"),
        ("e", "e\u{301}x"),            // 결합 문자가 붙어 grapheme 중간에서 잘린다
        ("e\u{301}", "\u{e9}x"),        // 바이트는 다르지만 정규화 동치
        ("\u{1100}", "\u{1100}\u{1161}"), // 한글 자모 L+V가 한 grapheme
        ("👨‍👩", "👨‍👩‍👧"),              // ZWJ 시퀀스 중간
        ("👍", "👍🏽"),                   // 피부색 수식자
    ])
    func streamingPrefixMatchesHasPrefix(_ older: String, _ newer: String) {
        func identity(_ markdown: String) -> RichMarkdownRenderModel.ParseIdentity {
            request(markdown).parseIdentity
        }
        #expect(identity(older).isStreamingPrefix(of: identity(newer)) == newer.hasPrefix(older))
    }

    @Test func latestSubmissionWinsPublication() async throws {
        let model = RichMarkdownRenderModel()
        for i in 1...20 {
            model.submit(request("버전 \(i) \\(x_{\(i)}\\)"))
        }
        try await waitForIdle(model)

        let document = try #require(model.document)
        #expect(flatText(document).contains("버전 20"), "최신 제출만 게시되어야 한다")
    }

    @Test func twoStagePublicationHydratesMath() async throws {
        let model = RichMarkdownRenderModel()
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
        let model = RichMarkdownRenderModel()
        model.submit(request(#"고장 \(\frac{\) 수식"#))
        try await waitForIdle(model)

        let document = try #require(model.document)
        for segment in document.allMathSegments where model.mathImages[segment] == nil {
            // 렌더 실패 노드는 이미지 없이 원문 source 유지.
            #expect(!segment.source.isEmpty)
        }
    }

    @Test func cacheMissImmediatelyClearsPreviousDocumentAndExposesLatestFallback() async throws {
        let model = RichMarkdownRenderModel()
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

    /// 스트리밍 append 계약: 표시 중인 문서가 새 markdown의 prefix면 새 parse가 게시될
    /// 때까지 이전 렌더(문서 + 이미지)를 유지한다. 매 갱신 fallback으로 되돌리면
    /// 스트리밍 화면 전체가 원문 ↔ 렌더를 오가며 출렁인다.
    @Test func streamingAppendKeepsPreviousDocumentUntilNewParseLands() async throws {
        let model = RichMarkdownRenderModel()
        let first = request(#"첫 문단 \(a+b\) 수식"#)
        model.submit(first)
        try await waitForIdle(model)
        let original = try #require(model.document)
        #expect(!model.mathImages.isEmpty)

        model.submit(request(#"첫 문단 \(a+b\) 수식 그리고 이어지는 답변"#))

        #expect(model.document == original, "append 중에는 이전 문서를 유지한다")
        #expect(model.parseIdentity == first.parseIdentity)
        #expect(!model.mathImages.isEmpty, "이전 수식 이미지도 유지한다")
        #expect(model.fallbackMarkdown.contains("이어지는 답변"), "fallback 원문은 최신이다")

        try await waitForIdle(model)
        let updated = try #require(model.document)
        #expect(flatText(updated).contains("이어지는 답변"), "새 parse가 게시되면 문서가 교체된다")
    }

    /// 스트리밍 append 제출은 parse가 게시될 때까지 objectWillChange를 내지 않는다.
    ///
    /// append 중에는 두 렌더러 모두 이전 문서를 표시하고 fallback 원문을 읽지 않는다.
    /// 제출 시점에 게시하면 tick마다 SwiftUI transaction·UIKit rebuild가 한 번씩 더 생긴다.
    @Test func streamingAppendDoesNotPublishUntilParseLands() async throws {
        let model = RichMarkdownRenderModel()
        model.submit(request("첫 문단"))
        try await waitForIdle(model)

        var changes = 0
        let sink = model.objectWillChange.sink { _ in changes += 1 }
        defer { sink.cancel() }

        model.submit(request("첫 문단 그리고 이어지는 답변"))
        #expect(changes == 0, "append 제출 자체는 게시하지 않는다")
        #expect(model.fallbackMarkdown == "첫 문단 그리고 이어지는 답변", "fallback 원문은 게시 없이도 최신이다")

        try await waitForIdle(model)
        #expect(changes > 0, "새 parse는 게시된다")
        let updated = try #require(model.document)
        #expect(flatText(updated).contains("이어지는 답변"))
    }

    /// fallback을 표시해야 하는 제출은 계속 즉시 게시한다.
    /// `document = nil` 대입은 값이 이미 nil이어도 objectWillChange를 낸다.
    @Test func submissionsThatShowFallbackStillPublishImmediately() async throws {
        let model = RichMarkdownRenderModel()
        var changes = 0
        let sink = model.objectWillChange.sink { _ in changes += 1 }
        defer { sink.cancel() }

        model.submit(request("스트림 시작"))
        #expect(changes > 0, "첫 제출은 fallback 표시를 위해 게시한다")

        // 첫 parse 전 누적: 표시 중인 문서가 없어 append가 아니다.
        changes = 0
        model.submit(request("스트림 시작 그리고"))
        #expect(changes > 0, "첫 parse 전 누적 제출도 최신 fallback을 위해 게시한다")
        #expect(model.fallbackMarkdown == "스트림 시작 그리고")
        try await waitForIdle(model)
        #expect(model.document != nil)

        changes = 0
        model.submit(request("전혀 다른 문서"))
        #expect(changes > 0, "교체 제출은 이전 문서를 숨기고 fallback을 보이도록 즉시 게시한다")
        #expect(model.document == nil)
        #expect(model.fallbackMarkdown == "전혀 다른 문서")
        try await waitForIdle(model)
    }

    @Test func renderConfigurationChangeKeepsMatchingDocumentAndClearsImages() async throws {
        let model = RichMarkdownRenderModel()
        let markdown = #"같은 문서 \(a+b\)"#
        let first = request(markdown)
        model.submit(first)
        try await waitForIdle(model)
        let original = try #require(model.document)
        #expect(model.parseIdentity == first.parseIdentity)

        let reconfigured = RichMarkdownRenderModel.Request(
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
        let model = RichMarkdownRenderModel()
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

        let first = RichMarkdownRenderModel()
        first.submit(request(rawMarkdown))
        try await waitForIdle(first)
        #expect(first.document?.wasTruncated == true)

        let cached = RichMarkdownRenderModel()
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

        let literal = RichMarkdownRenderModel()
        literal.submit(request(bounded.text))
        try await waitForIdle(literal)
        #expect(literal.document?.wasTruncated == false)

        let truncated = RichMarkdownRenderModel()
        truncated.submit(request(rawMarkdown))
        try await waitForIdle(truncated)
        #expect(
            truncated.document?.wasTruncated == true,
            "같은 표시 문자열이어도 입력 제한 flag가 다른 cache entry여야 한다"
        )
    }

    @Test func parseCacheCostIncludesDocumentStructureAndSaturates() {
        let markdown = "문단 \\(a+b\\)\n\n또 다른 문단 \\(c+d\\)"
        let document = RichMarkdownParser.parse(markdown: markdown, parsesDollarMath: false)

        let estimated = ParseCache.estimatedCost(for: document, sourceByteCount: markdown.utf8.count)
        #expect(estimated > markdown.utf8.count * 3)
        #expect(ParseCache.estimatedCost(for: document, sourceByteCount: .max) == .max)

        let sameBaseCost = 1_024
        let oneBlock = RichMarkdownParser.parse(markdown: "plain", parsesDollarMath: false)
        let threeBlocks = RichMarkdownParser.parse(markdown: "a\n\nb\n\nc", parsesDollarMath: false)
        let math = RichMarkdownParser.parse(markdown: #"\(a\) \(b\)"#, parsesDollarMath: false)
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
        let model = RichMarkdownRenderModel()
        let staleMarkdown = "stale-\(UUID().uuidString)\n" + String(repeating: "stale ", count: 20_000)
        let latestMarkdown = "latest-\(UUID().uuidString)"
        model.submit(request(staleMarkdown))
        model.submit(request(latestMarkdown))

        let staleInput = InputLimits.bound(staleMarkdown)
        let staleDocument = RichMarkdownParser.parse(staleInput, parsesDollarMath: false)
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
        let latestDocument = RichMarkdownParser.parse(latestInput, parsesDollarMath: false)
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

    /// UIKit 렌더러 요청(`rastersDisplayMath: false`)은 블록 수식을 raster하지 않는다.
    /// 인라인 raster는 유지된다.
    @Test func skipsDisplayMathRasterWhenRequestOptsOut() async throws {
        let model = RichMarkdownRenderModel()
        // 처음 보는 latex — raster 캐시가 비어 있어, "raster가 실행되지 않았다"를
        // idle 후에도 캐시가 차지 않았다는 사실로 판정할 수 있다.
        let inlineLatex = "x_{\(UUID().uuidString.prefix(8))}+1"
        let blockLatex = "y_{\(UUID().uuidString.prefix(8))}+2"
        let submitted = RichMarkdownRenderModel.Request(
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
        let model = RichMarkdownRenderModel()
        let submitted = RichMarkdownRenderModel.Request(
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

    @Test func parsesTableStructureAlignmentAndInlineContent() throws {
        let document = RichMarkdownParser.parse(
            markdown: #"""
            | 항목 | 수식 | 상태 |
            | :--- | :---: | ---: |
            | **하나** | \(x+1\) | `완료` |
            """#,
            parsesDollarMath: false
        )

        let block = try #require(document.blocks.first)
        guard case .table(let table) = block else {
            Issue.record("GFM 표를 plain text 문단으로 강등하면 안 된다")
            return
        }

        #expect(table.columnAlignments == [.left, .center, .right])
        #expect(table.header.count == 3)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].count == 3)
        #expect(table.rows[0][0].first?.bold == true)
        #expect(table.rows[0][2].first?.content == .code("완료"))
        #expect(document.allMathSegments.map(\.latex) == ["x+1"])
    }

    @Test func oversizedTableFallsBackToReadableText() throws {
        let markdown = "| 항목 |\n| --- |\n"
            + String(repeating: #"| \(x+1\) |"# + "\n", count: InputLimits.maxTableCells)
        let document = RichMarkdownParser.parse(
            markdown: markdown,
            parsesDollarMath: false
        )

        let block = try #require(document.blocks.first)
        guard case .paragraph(let runs) = block else {
            Issue.record("렌더 상한을 넘는 표는 plain text로 낮춰야 한다")
            return
        }
        let text = runs.compactMap { run -> String? in
            if case .text(let text) = run.content { return text }
            return nil
        }.joined()
        #expect(text == markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(text.contains(#"\(x+1\)"#), "masked AST가 아니라 원본 수식 source를 보존해야 한다")
    }

    @Test func streamingAppendDoesNotStoreParseCacheEntry() async throws {
        let model = RichMarkdownRenderModel()
        let base = "스트리밍 캐시 검증 \(UUID().uuidString)"
        model.submit(request(base))
        try await waitForIdle(model)
        #expect(
            ParseCache.shared.document(markdown: base, parsesDollarMath: false) != nil,
            "스트림의 첫 제출은 캐시한다"
        )

        let appended = base + " 그리고 이어지는 답변"
        model.submit(request(appended))
        try await waitForIdle(model)
        let updated = try #require(model.document)
        #expect(flatText(updated).contains("이어지는 답변"), "append parse는 게시된다")
        #expect(
            ParseCache.shared.document(markdown: appended, parsesDollarMath: false) == nil,
            "append 요청은 누적 원문을 새 키로 저장하지 않는다"
        )

        let replaced = "전혀 다른 문서 \(UUID().uuidString)"
        model.submit(request(replaced))
        try await waitForIdle(model)
        #expect(
            ParseCache.shared.document(markdown: replaced, parsesDollarMath: false) != nil,
            "교체 제출은 다시 캐시한다"
        )
    }

    // MARK: - 프레임 정렬 게시

    /// 수동 프레임 model의 idle 대기. 프레임을 기다리는 게시가 있으면 프레임을 한 번 흘린다.
    private func drain(
        _ model: RichMarkdownRenderModel,
        frames: ManualFrames,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.hasOutstandingWork {
            try #require(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            frames.tick()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            try #require(Date() < deadline, "조건이 제한 시간 안에 충족되어야 한다")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 스트리밍 append 결과는 준비된 즉시가 아니라 다음 디스플레이 프레임 첫머리에 게시한다.
    /// 그때까지 `hasOutstandingWork`는 true다.
    @Test func streamingAppendResultWaitsForNextDisplayFrame() async throws {
        let frames = ManualFrames()
        let model = RichMarkdownRenderModel(frameScheduler: frames.schedule)
        model.submit(request("첫 문단"))
        try await drain(model, frames: frames)
        let original = try #require(model.document)
        #expect(frames.requestCount == 0, "첫 렌더는 프레임을 기다리지 않는다")

        let appended = request("첫 문단 그리고 이어지는 답변")
        model.submit(appended)
        try await waitUntil { model.pendingFrameRequest == appended }

        #expect(model.document == original, "프레임 전에는 이전 문서가 보인다")
        #expect(model.hasOutstandingWork, "프레임을 기다리는 게시가 남아 있으면 idle이 아니다")
        #expect(frames.requestCount == 1)

        frames.tick()
        let updated = try #require(model.document)
        #expect(flatText(updated).contains("이어지는 답변"), "프레임 콜백에서 새 문서가 게시된다")
        #expect(model.parseIdentity == appended.parseIdentity)
        #expect(!model.hasOutstandingWork)
        #expect(frames.waitingCount == 0, "게시 뒤에는 기다리는 프레임이 없다")
    }

    /// 프레임을 기다리는 동안 더 새 append 결과가 오면 그것으로 바꾼다. 프레임 요청은 하나다.
    @Test func newerAppendResultReplacesPendingOne() async throws {
        let frames = ManualFrames()
        let model = RichMarkdownRenderModel(frameScheduler: frames.schedule)
        model.submit(request("첫 문단"))
        try await drain(model, frames: frames)

        var identities: [String] = []
        let sink = model.$parseIdentity.compactMap { $0?.markdown }.sink { identities.append($0) }
        defer { sink.cancel() }

        model.submit(request("첫 문단 둘"))
        try await waitUntil { model.pendingFrameRequest != nil }
        let latest = request("첫 문단 둘 셋")
        model.submit(latest)
        try await waitUntil { model.pendingFrameRequest == latest }
        #expect(frames.requestCount == 1, "기다리는 게시를 바꿔도 프레임은 한 번만 요청한다")

        frames.tick()
        #expect(model.parseIdentity == latest.parseIdentity)
        #expect(identities == ["첫 문단", "첫 문단 둘 셋"], "이전 append 결과는 게시되지 않는다")
        #expect(!model.hasOutstandingWork)
    }

    /// 프레임을 기다리는 사이 새 제출이 오면 그 결과는 프레임에서 다시 확인해 버린다.
    @Test func pendingAppendResultIsDroppedWhenSupersededBeforeFrame() async throws {
        let frames = ManualFrames()
        let model = RichMarkdownRenderModel(frameScheduler: frames.schedule)
        model.submit(request("첫 문단"))
        try await drain(model, frames: frames)
        let original = try #require(model.document)

        model.submit(request("첫 문단 둘"))
        try await waitUntil { model.pendingFrameRequest != nil }
        let latest = request("첫 문단 둘 셋")
        model.submit(latest)
        frames.tick()
        #expect(model.document == original, "stale generation은 프레임에서도 게시하지 않는다")

        try await drain(model, frames: frames)
        #expect(model.parseIdentity == latest.parseIdentity)
    }

    /// 1단계 게시가 프레임을 기다리는 사이 같은 generation의 hydration이 오면 문서를 잃지 않고 합친다.
    @Test func appendHydrationMergesIntoPendingDocument() async throws {
        let frames = ManualFrames()
        let model = RichMarkdownRenderModel(frameScheduler: frames.schedule)
        model.submit(request("첫 문단"))
        try await drain(model, frames: frames)

        let appended = request(#"첫 문단 \(y^2\)"#)
        model.submit(appended)
        // worker 게시보다 먼저, 같은 MainActor turn에서 두 단계 게시를 직접 만든다.
        let parsed = RichMarkdownParser.parse(markdown: appended.markdown, parsesDollarMath: false)
        let segment = try #require(parsed.allMathSegments.first)
        let image = RenderedMath(image: UIImage(), descent: 0, ascent: 0)
        model.publishComplete(parsed, images: [:], request: appended, generation: 2, atNextFrame: true)
        model.publishImages([segment: image], request: appended, generation: 2, atNextFrame: true)
        #expect(frames.requestCount == 1)

        frames.tick()
        #expect(model.document == parsed, "hydration이 기다리던 문서를 덮어 지우면 안 된다")
        #expect(model.mathImages[segment] != nil)
        #expect(model.imageRequest == appended)
        try await drain(model, frames: frames)
    }

    /// append가 아닌 게시(첫 렌더·교체·설정 변경)는 지금처럼 즉시 게시한다 — 프레임을 기다리지 않는다.
    @Test func nonAppendPublishesStayImmediate() async throws {
        let frames = ManualFrames()
        let model = RichMarkdownRenderModel(frameScheduler: frames.schedule)
        // 프레임을 흘리지 않는다. 즉시 게시라면 그래도 idle이 된다.
        model.submit(request(#"첫 렌더 \(a+b\)"#))
        try await waitForIdle(model)
        #expect(model.document != nil)
        #expect(!model.mathImages.isEmpty, "첫 렌더의 hydration도 즉시다")

        model.submit(request("전혀 다른 문서"))
        try await waitForIdle(model)
        #expect(model.parseIdentity?.markdown == "전혀 다른 문서")

        let reconfigured = RichMarkdownRenderModel.Request(
            markdown: "전혀 다른 문서",
            parsesDollarMath: false,
            pointSize: 24,
            colorRGBA: 0xFF0000FF,
            displayScale: 2
        )
        model.submit(reconfigured)
        try await waitForIdle(model)
        #expect(model.imageRequest == reconfigured)
        #expect(frames.requestCount == 0, "append가 아닌 게시는 프레임을 요청하지 않는다")
    }

    /// 실제 `CADisplayLink` 경로: append 결과는 프레임 콜백에서 게시되고, 울린 링크는 무효화돼 놓인다.
    /// 기다리는 게시가 없으면 살아 있는 링크도 없다.
    @Test func displayLinkPublishesAppendAndIsReleasedWhenIdle() async throws {
        var fired = 0
        weak var link: CADisplayLink?
        link = DisplayFrame.next { fired += 1 }
        #expect(link != nil, "기다리는 동안은 run loop가 링크를 잡는다")
        try await waitUntil { fired == 1 && link == nil }

        let model = RichMarkdownRenderModel()
        model.submit(request("첫 문단"))
        try await waitForIdle(model)
        let appended = request("첫 문단 그리고 이어지는 답변")
        model.submit(appended)
        // 기본 init도 append 게시를 동기로 반영하지 않는다. worker 게시보다 먼저 같은 MainActor turn에서
        // 만들므로, 실제 링크는 아래 확인이 끝나기 전에 울릴 수 없다.
        let parsed = RichMarkdownParser.parse(markdown: appended.markdown, parsesDollarMath: false)
        model.publishComplete(parsed, images: [:], request: appended, generation: 2, atNextFrame: true)
        #expect(model.pendingFrameRequest == appended, "기본 frame scheduler도 다음 프레임을 기다린다")
        #expect(model.parseIdentity != appended.parseIdentity)

        try await waitForIdle(model)
        #expect(model.parseIdentity == appended.parseIdentity)
        #expect(flatText(try #require(model.document)).contains("이어지는 답변"))
        #expect(fired == 1, "한 번 울린 링크는 다시 울리지 않는다")
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

/// 테스트용 수동 디스플레이 프레임. `tick()`이 기다리는 콜백을 한 번에 흘린다.
@MainActor
final class ManualFrames {
    private var waiting: [@MainActor () -> Void] = []
    /// 지금까지 받은 프레임 요청 수.
    private(set) var requestCount = 0
    var waitingCount: Int { waiting.count }

    var schedule: DisplayFrame.Scheduler {
        { [weak self] action in
            self?.requestCount += 1
            self?.waiting.append(action)
        }
    }

    func tick() {
        let actions = waiting
        waiting = []
        actions.forEach { $0() }
    }
}
