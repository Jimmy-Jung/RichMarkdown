import SwiftUI
import SwiftLatexCore

/// 비동기 렌더 계약 (DEVELOPMENT.md §4).
///
/// MainActor에서는 generation 관리와 게시만 한다. CPU parse/raster는 worker에서 실행한다.
/// 게시는 2단계: (1) 수식을 원문으로 둔 ParsedDocument, (2) 수식 이미지 hydration.
@MainActor
package final class LatexRenderModel: ObservableObject {
    /// Markdown parsing 결과를 결정하는 canonical 입력 식별자다.
    /// 수식 raster 설정은 포함하지 않으므로 테마/색/scale 변경 때 문서를 유지할 수 있다.
    package struct ParseIdentity: Sendable, Equatable {
        package let markdown: String
        package let parsesDollarMath: Bool
        package let wasTruncated: Bool
    }

    package struct Request: Sendable, Equatable {
        /// 과대 원문을 보관하지 않는 canonical bounded input이다.
        package let boundedInput: InputLimits.BoundedInput
        package var markdown: String { boundedInput.text }
        package let parsesDollarMath: Bool
        package let pointSize: CGFloat
        package let colorRGBA: UInt32
        package let displayScale: CGFloat
        package let mathFont: LatexMathFont
        /// 블록(display) 수식 raster가 필요한가. UIKit 렌더러는 블록 수식을 벡터 뷰로
        /// 그리므로 false를 보낸다 — 아무도 읽지 않는 raster를 만들지 않는다
        /// (Docs/RENDERING_PERFORMANCE_PLAN.md §9.4). 인라인 수식 raster에는 영향이 없다.
        package let rastersDisplayMath: Bool
        package var wasTruncated: Bool { boundedInput.wasTruncated }

        package var parseIdentity: ParseIdentity {
            ParseIdentity(
                markdown: markdown,
                parsesDollarMath: parsesDollarMath,
                wasTruncated: wasTruncated
            )
        }

        package init(
            markdown: String,
            parsesDollarMath: Bool,
            pointSize: CGFloat,
            colorRGBA: UInt32,
            displayScale: CGFloat,
            mathFont: LatexMathFont = .latinModern,
            rastersDisplayMath: Bool = true
        ) {
            self.init(
                boundedInput: InputLimits.bound(markdown),
                parsesDollarMath: parsesDollarMath,
                pointSize: pointSize,
                colorRGBA: colorRGBA,
                displayScale: displayScale,
                mathFont: mathFont,
                rastersDisplayMath: rastersDisplayMath
            )
        }

        /// UI가 public ingress에서 이미 제한한 입력을 재사용하는 경로다.
        /// model/worker/cache 모두 이 canonical form만 보관한다.
        package init(
            boundedInput: InputLimits.BoundedInput,
            parsesDollarMath: Bool,
            pointSize: CGFloat,
            colorRGBA: UInt32,
            displayScale: CGFloat,
            mathFont: LatexMathFont = .latinModern,
            rastersDisplayMath: Bool = true
        ) {
            self.boundedInput = boundedInput
            self.parsesDollarMath = parsesDollarMath
            self.pointSize = pointSize
            self.colorRGBA = colorRGBA
            self.displayScale = displayScale
            self.mathFont = mathFont
            self.rastersDisplayMath = rastersDisplayMath
        }
    }

    @Published package private(set) var document: ParsedDocument?
    /// `document`가 어느 parsing 입력에서 만들어졌는지 나타낸다.
    /// UI는 현재 Request의 `parseIdentity`와 같을 때만 document를 표시한다.
    @Published package private(set) var parseIdentity: ParseIdentity?
    @Published package private(set) var mathImages: [MathSegment: RenderedMath] = [:]
    /// `mathImages`가 어느 전체 render request(폰트/색/scale 포함)로 만들어졌는지 나타낸다.
    /// UI는 현재 Request와 같을 때만 이 사전을 수식 view에 전달한다.
    @Published package private(set) var imageRequest: Request?
    /// 아직 파싱되지 않은 최신 요청을 표시할 안전한 원문이다.
    /// 과대 입력은 `InputLimits`의 표시 상한으로 잘려 있어 UIKit/SwiftUI fallback에도
    /// 원본 전체 문자열이 전달되지 않는다.
    @Published package private(set) var fallbackMarkdown = ""

    private var generation = 0
    private var completedGeneration = 0
    private var worker: CoalescingWorker<Job>?
    private var lastRequest: Request?

    private struct Job: Sendable {
        let generation: Int
        let request: Request
    }

    package init() {}

    package func submit(_ request: Request) {
        // 같은 요청 재제출은 무시한다. SwiftUI `.task(id:)`는 뷰가 다시 나타날 때마다
        // 실행되고 트레잇 변경도 같은 값으로 올 수 있다 — 결과가 같으므로
        // 게시(뷰 재구성)도 없어야 한다. 진행 중이면 그 작업이 곧 게시한다.
        guard request != lastRequest else { return }
        let parseIdentityChanged = request.parseIdentity != lastRequest?.parseIdentity
        lastRequest = request
        generation += 1

        // Markdown/dollar parsing 조건이 바뀌면 cache 결과가 게시되기 전에는 이전 문서를
        // 보이면 안 된다. 수식 설정만 바뀐 경우에는 parsed document를 유지하고 이미지
        // 원문 fallback만 보인다.
        if parseIdentityChanged {
            fallbackMarkdown = request.markdown
            document = nil
            parseIdentity = nil
        }
        mathImages = [:]
        imageRequest = nil

        // 캐시가 전부 있어도 여기서 동기로 게시하지 않는다(실측). 동기 게시는 셀이
        // 붙는 레이아웃 패스 안에서 리사이즈를 일으키고, UIKit의 contentOffset 보정이
        // 스크롤 제스처 이동량을 매번 상쇄해 위로 스크롤이 얼어붙는다. worker 왕복
        // 뒤 `publishComplete`(단일 게시)로 합쳐지는 것으로 충분하다.
        let job = Job(generation: generation, request: request)
        let worker = ensureWorker()
        // generation high-water mark는 worker actor와 같은 turn에서 판정한다.
        // unstructured Task의 도착이 역순이어도 이전 job은 최신 pending을 덮지 못한다.
        Task { await worker.submit(job, generation: job.generation) }
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

    /// generation 확인과 cache 삽입은 같은 MainActor turn에서 수행한다.
    /// entry의 비용 산정은 worker에서 끝낸 뒤 넘기므로 이 경로는 AST를 순회하지 않는다.
    /// 확인 뒤 worker에서 삽입하면 그 사이 새 요청이 들어와 stale 결과가 남을 수 있다.
    /// internal visibility는 `@testable` stale-cache 계약의 deterministic regression test에도 사용한다.
    func storeParsedDocumentIfCurrent(
        _ entry: ParseCache.PreparedEntry,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        ParseCache.shared.store(entry)
    }

    private func publishParsed(
        _ parsed: ParsedDocument,
        parseIdentity: ParseIdentity,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        document = parsed
        self.parseIdentity = parseIdentity
        mathImages = [:]
        imageRequest = nil
    }

    private func publishImages(
        _ images: [MathSegment: RenderedMath],
        request: Request,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        mathImages = images
        imageRequest = request
    }

    /// 수식 이미지가 전부 준비된 경우의 단일 게시. 중간 단계(원문 fallback)가 없어
    /// 구독자의 뷰 재구성이 1회로 준다.
    private func publishComplete(
        _ parsed: ParsedDocument,
        images: [MathSegment: RenderedMath],
        parseIdentity: ParseIdentity,
        request: Request,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        document = parsed
        self.parseIdentity = parseIdentity
        mathImages = images
        imageRequest = request
    }

    /// 이 요청이 raster해야 하는 수식 segment (문서 순서, 중복 제거).
    ///
    /// display segment는 `blockMath` 블록과 1:1이다 — display delimiter는 공백 제외
    /// paragraph 전체일 때만 인정되고(§3), 그렇지 않으면 diagnostic과 함께 plain text로
    /// 남아 segment 자체가 만들어지지 않는다. 따라서 `kind.isDisplay` 필터가 곧
    /// "블록 수식 제외"다.
    private nonisolated static func rasterSegments(
        for parsed: ParsedDocument,
        request: Request
    ) -> [MathSegment] {
        let all = parsed.allMathSegments
        return request.rastersDisplayMath ? all : all.filter { !$0.kind.isDisplay }
    }

    /// 필요한 수식 raster가 전부 캐시에 있을 때만 그 사전을 반환한다. 하나라도 없으면 nil.
    /// 필요한 수식이 없으면(블록 수식 제외 후 잔여 0) 빈 사전 — 단일 게시로 이어진다.
    private nonisolated static func cachedImages(
        for parsed: ParsedDocument,
        request: Request
    ) -> [MathSegment: RenderedMath]? {
        var images: [MathSegment: RenderedMath] = [:]
        for segment in rasterSegments(for: parsed, request: request) {
            guard let rendered = MathRenderService.shared.cachedImage(
                for: renderKey(segment, request)
            ) else { return nil }
            images[segment] = rendered
        }
        return images
    }

    private nonisolated static func renderKey(_ segment: MathSegment, _ request: Request) -> MathRenderKey {
        MathRenderKey(
            latex: segment.latex,
            mathFont: request.mathFont,
            pointSize: request.pointSize,
            colorRGBA: request.colorRGBA,
            isDisplay: segment.kind.isDisplay,
            displayScale: request.displayScale
        )
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

        let cacheKey = ParseCache.shared.key(
            markdown: job.request.markdown,
            parsesDollarMath: job.request.parsesDollarMath,
            wasTruncated: job.request.wasTruncated
        )
        let parsed: ParsedDocument
        if let cached = ParseCache.shared.document(for: cacheKey) {
            parsed = cached
        } else {
            parsed = SwiftLatexParser.parse(
                job.request.boundedInput,
                parsesDollarMath: job.request.parsesDollarMath
            )
            let entry = ParseCache.shared.preparedEntry(parsed, for: cacheKey)
            await model.storeParsedDocumentIfCurrent(entry, generation: job.generation)
        }

        guard await model.isCurrent(job.generation) else { return }

        // raster가 전부 캐시에 있으면 2단계 게시가 필요 없다 — 기다릴 것이 없으므로
        // 원문 fallback 단계를 건너뛰고 한 번에 게시한다.
        if let images = cachedImages(for: parsed, request: job.request) {
            await model.publishComplete(
                parsed,
                images: images,
                parseIdentity: job.request.parseIdentity,
                request: job.request,
                generation: job.generation
            )
            return
        }

        // 1단계 게시: 수식은 원문으로 먼저 보인다 (DEVELOPMENT.md §4).
        await model.publishParsed(
            parsed,
            parseIdentity: job.request.parseIdentity,
            generation: job.generation
        )

        var images: [MathSegment: RenderedMath] = [:]
        for segment in rasterSegments(for: parsed, request: job.request) {
            // 각 수식 block 사이에 generation 확인. stale이면 이후 raster·cache 삽입이 없다.
            guard await model.isCurrent(job.generation) else { return }
            if let rendered = await MathRenderService.shared.render(
                key: renderKey(segment, job.request)
            ) {
                images[segment] = rendered
            }
        }

        // 최종 게시 직전 확인.
        guard await model.isCurrent(job.generation) else { return }
        await model.publishImages(images, request: job.request, generation: job.generation)
    }
}
