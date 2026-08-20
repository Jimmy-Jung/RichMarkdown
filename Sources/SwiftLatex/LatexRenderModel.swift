import SwiftUI
import SwiftLatexCore

/// 비동기 렌더 계약 (DEVELOPMENT.md §4).
///
/// MainActor에서는 generation 관리와 게시만 한다. CPU parse/raster는 worker에서 실행한다.
/// 게시는 2단계: (1) 수식을 원문으로 둔 ParsedDocument, (2) 수식 이미지 hydration.
@MainActor
package final class LatexRenderModel: ObservableObject {
    package struct Request: Sendable, Equatable {
        package var markdown: String
        package var parsesDollarMath: Bool
        package var pointSize: CGFloat
        package var colorRGBA: UInt32
        package var displayScale: CGFloat
        package var mathFont: LatexMathFont

        package init(
            markdown: String,
            parsesDollarMath: Bool,
            pointSize: CGFloat,
            colorRGBA: UInt32,
            displayScale: CGFloat,
            mathFont: LatexMathFont = .latinModern
        ) {
            self.markdown = markdown
            self.parsesDollarMath = parsesDollarMath
            self.pointSize = pointSize
            self.colorRGBA = colorRGBA
            self.displayScale = displayScale
            self.mathFont = mathFont
        }
    }

    @Published package private(set) var document: ParsedDocument?
    @Published package private(set) var mathImages: [MathSegment: RenderedMath] = [:]

    private var generation = 0
    private var completedGeneration = 0
    private var worker: CoalescingWorker<Job>?

    private struct Job: Sendable {
        let generation: Int
        let request: Request
    }

    package init() {}

    package func submit(_ request: Request) {
        generation += 1
        let job = Job(generation: generation, request: request)
        let worker = ensureWorker()
        Task { await worker.submit(job) }
    }

    /// 입력 종료 후 idle 검증용 (테스트).
    /// 마지막으로 제출된 generation의 처리가 끝나면 false가 된다.
    package var hasOutstandingWork: Bool {
        completedGeneration < generation
    }

    private func ensureWorker() -> CoalescingWorker<Job> {
        if let worker { return worker }
        let created = CoalescingWorker<Job> { [weak self] job in
            await Self.process(job, model: self)
        }
        worker = created
        return created
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    private func markCompleted(_ generation: Int) {
        completedGeneration = max(completedGeneration, generation)
    }

    private func publishParsed(_ parsed: ParsedDocument, generation: Int) {
        guard isCurrent(generation) else { return }
        document = parsed
        mathImages = [:]
    }

    private func publishImages(_ images: [MathSegment: RenderedMath], generation: Int) {
        guard isCurrent(generation) else { return }
        mathImages = images
    }

    /// `nonisolated`가 이 설계의 핵심이다.
    ///
    /// `LatexRenderModel`은 `@MainActor`이고 global actor 표시는 **static 멤버에도 적용된다**.
    /// 그래서 `nonisolated` 없이 두면 이 함수 전체가 MainActor에서 실행되고
    /// `SwiftLatexParser.parse`가 main thread를 점유한다(50 KiB에서 p50 약 119ms).
    /// `nonisolated`면 worker executor에서 실행되고 `await model.…`만 MainActor로 hop한다.
    /// 컴파일러가 "no 'async' operations occur within 'await' expression" 경고를 내면
    /// 이 표시가 빠졌다는 신호다.
    private nonisolated static func process(_ job: Job, model: LatexRenderModel?) async {
        guard let model else { return }
        await run(job, model: model)
        await model.markCompleted(job.generation)
    }

    private nonisolated static func run(_ job: Job, model: LatexRenderModel) async {
        // service 진입 직후 generation 확인.
        guard await model.isCurrent(job.generation) else { return }

        let parsed = SwiftLatexParser.parse(
            markdown: job.request.markdown,
            parsesDollarMath: job.request.parsesDollarMath
        )

        // parse 직후 확인 후 1단계 게시.
        guard await model.isCurrent(job.generation) else { return }
        await model.publishParsed(parsed, generation: job.generation)

        var images: [MathSegment: RenderedMath] = [:]
        for segment in parsed.allMathSegments {
            // 각 수식 block 사이에 generation 확인. stale이면 이후 raster·cache 삽입이 없다.
            guard await model.isCurrent(job.generation) else { return }
            let key = MathRenderKey(
                latex: segment.latex,
                mathFont: job.request.mathFont,
                pointSize: job.request.pointSize,
                colorRGBA: job.request.colorRGBA,
                isDisplay: segment.kind.isDisplay,
                displayScale: job.request.displayScale
            )
            if let rendered = await MathRenderService.shared.render(key: key) {
                images[segment] = rendered
            }
        }

        // 최종 게시 직전 확인.
        guard await model.isCurrent(job.generation) else { return }
        await model.publishImages(images, generation: job.generation)
    }
}
