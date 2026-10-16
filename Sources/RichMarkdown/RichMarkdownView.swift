import SwiftUI
import RichMarkdownCore

/// v1 공개 API (DEVELOPMENT.md §2).
///
/// ```swift
/// RichMarkdownView(markdown: message, parsesDollarMath: false)
///     .richMarkdownTheme(.default)
/// ```
public struct RichMarkdownView: View {
    /// public ingress에서 한 번 제한한 canonical 입력. 원문 전체를 View 수명 동안
    /// 보관하지 않아 large markdown이 SwiftUI state에 남지 않는다.
    private let boundedMarkdown: InputLimits.BoundedInput
    private let dollarMath: LatexDollarMathOptions

    @StateObject private var model = RichMarkdownRenderModel()
    @Environment(\.richMarkdownTheme) private var theme
    @Environment(\.richMarkdownStreaming) private var streaming
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.richMarkdownBodyProbe) private var probe
    /// `@ScaledMetric(relativeTo:)`의 기준 style은 컴파일 시점 상수여서 style별
    /// 배율을 root에서 측정한 뒤 하위 renderer에 environment로 전달한다.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1
    @ScaledMetric(relativeTo: .headline) private var headlineScale: CGFloat = 1
    @ScaledMetric(relativeTo: .title) private var titleScale: CGFloat = 1
    @ScaledMetric(relativeTo: .title2) private var title2Scale: CGFloat = 1
    @ScaledMetric(relativeTo: .title3) private var title3Scale: CGFloat = 1
    @ScaledMetric(relativeTo: .caption) private var captionScale: CGFloat = 1

    public init(markdown: String, parsesDollarMath: Bool = false) {
        self.init(markdown: markdown, dollarMath: LatexDollarMathOptions(parsesDollarMath: parsesDollarMath))
    }

    /// dollar 수식 범위를 조합해 켠다. `[.single, .inlineDouble]`이면 문장 안 `$$...$$`도 inline 수식이다.
    public init(markdown: String, dollarMath: LatexDollarMathOptions) {
        self.boundedMarkdown = InputLimits.bound(markdown)
        self.dollarMath = dollarMath
    }

    public var body: some View {
        // 요청을 한 번만 canonicalize한다. 대형 원문의 bounded fallback도 body와
        // `.task(id:)`가 같은 값을 써야 이전 문서가 한 프레임 되살아나지 않는다.
        let request = currentRequest
        let document = displayedDocument(for: request)
        let _ = probe?.didEvaluateRoot(showsDocument: document != nil)
        content(for: request, document: document)
            .environment(\.richMarkdownFontScale, fontScale)
            .task(id: request) {
                model.submit(request)
            }
    }

    /// 이 body는 markdown이 바뀔 때마다(스트리밍 tick마다) 돈다. 문서 렌더는 하위
    /// `RichMarkdownDocumentView`에 두고 입력을 모델이 게시한 값으로만 채운다 — 새 parse가
    /// 게시되기 전의 갱신에서는 `==`가 참이라 블록·ForEach·레이아웃을 다시 돌지 않는다.
    @ViewBuilder
    private func content(
        for request: RichMarkdownRenderModel.Request,
        document: ParsedDocument?
    ) -> some View {
        if let document {
            // 색·폰트·scale이 바뀐 새 raster가 준비되기 전에는 이전 bitmap을 섞지 않고
            // source fallback을 유지한다. markdown만 다른 stale 이미지는 계속 쓴다 —
            // 수식 raster는 문서 안 위치와 무관하다.
            let images = model.imageRequest?.matchesRasterConfiguration(of: request) == true
                ? model.mathImages : [:]
            // 스트리밍 표시(꼬리 페이드·미닫힌 마크 억제)는 마지막 블록에만 전달한다.
            let tail = streaming.map {
                RichMarkdownStreamingTailContext(options: $0, dollarMath: dollarMath)
            }
            RichMarkdownDocumentView(document: document, images: images, tail: tail, probe: probe)
                .equatable()
        } else {
            // Request가 입력을 제한해 보관하므로 raw markdown을 UI에 직접 전달하지 않는다.
            Text(request.markdown)
                .richMarkdownFont(theme.bodyFont)
                .foregroundStyle(theme.textColor)
                .textSelection(.enabled)
        }
    }

    /// 표시할 모델 문서. `.task(id:)`는 body 뒤에 시작된다. 모델 문서가 현재 요청과 같은
    /// parse identity거나 그 **스트리밍 prefix**면 표시한다 — append 중에는 새 parse가 게시될
    /// 때까지 이전 렌더를 유지해 화면 전체가 원문 fallback으로 출렁이지 않게 한다. 다른 문서
    /// (셀 재사용)는 여전히 한 프레임도 되살아나지 않는다.
    private func displayedDocument(for request: RichMarkdownRenderModel.Request) -> ParsedDocument? {
        guard let identity = model.parseIdentity,
              identity == request.parseIdentity || identity.isStreamingPrefix(of: request.parseIdentity)
        else { return nil }
        return model.document
    }

    /// 수식 raster 기준 크기. 수식은 본문 폰트가 선택한 Dynamic Type 기준을 따른다.
    private var mathPointSize: CGFloat { theme.bodyFont.scaledPointSize(using: fontScale) }

    private var fontScale: RichMarkdownFontScale {
        RichMarkdownFontScale(
            body: bodyScale,
            headline: headlineScale,
            title: titleScale,
            title2: title2Scale,
            title3: title3Scale,
            caption: captionScale
        )
    }

    private var currentRequest: RichMarkdownRenderModel.Request {
        RichMarkdownRenderModel.Request(
            boundedInput: boundedMarkdown,
            dollarMath: dollarMath,
            pointSize: mathPointSize,
            colorRGBA: resolvedTextColorRGBA,
            displayScale: displayScale
        )
    }

    private var resolvedTextColorRGBA: UInt32 {
        TextColorRGBA.resolve(theme.textColor, colorScheme: colorScheme)
    }
}

/// 수식 raster 색. body는 tick마다 여러 번 돈다(markdown 변경·append 알림·parse 게시) — `UIColor(Color)` 변환과 trait 해석(시뮬레이터 약 7 µs)
/// 대신 마지막 (색, scheme) 결과를 재사용한다(`Color` 비교는 0.01 µs).
@MainActor
private enum TextColorRGBA {
    // ponytail: 1칸 캐시. 테마가 다른 뷰가 번갈아 그리면 매번 다시 변환할 뿐 결과는 같다.
    private static var last: (color: Color, colorScheme: ColorScheme, rgba: UInt32)?

    static func resolve(_ color: Color, colorScheme: ColorScheme) -> UInt32 {
        if let last, last.color == color, last.colorScheme == colorScheme { return last.rgba }
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let rgba = UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .rgbaValue
        last = (color, colorScheme, rgba)
        return rgba
    }
}

// MARK: - Document

/// 모델이 게시한 문서의 블록 목록. 입력이 문서·이미지·tail 문맥뿐이라 markdown만 바뀐 상위
/// 갱신(스트리밍 tick의 parse 전 갱신)에서는 값이 같아 body를 다시 평가하지 않는다.
struct RichMarkdownDocumentView: View {
    let document: ParsedDocument
    let images: [MathSegment: RenderedMath]
    let tail: RichMarkdownStreamingTailContext?
    /// 테스트 관측점. `==`에 넣지 않는다. environment로 읽지 않고 상위가 넘겨 이 뷰의 의존을
    /// 문서 입력으로만 둔다.
    var probe: RichMarkdownBodyProbe? = nil

    var body: some View {
        let _ = probe?.didEvaluateDocument()
        let lastIndex = document.blocks.count - 1
        VStack(alignment: .leading, spacing: 12) {
            // identity는 렌더 시점의 위치 + content digest. 편집 사이 영속성은 약속하지 않는다.
            // `.equatable()`: 새 문서가 게시돼도 값이 같은 블록은 body를 다시 평가하지 않는다.
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { offset, block in
                RichMarkdownBlockView(
                    block: block,
                    images: images,
                    tail: offset == lastIndex ? tail : nil
                )
                .equatable()
            }
        }
    }
}

/// 새 parse가 게시되기 전에는 문서와 이미지 사전이 같은 저장소라 비교가 짧다(배열 identity 지름길).
/// 이미지는 `RichMarkdownBlockView`와 같이 raster identity로 비교한다. 테마·폰트 배율은
/// environment라 이 판정과 별개로 블록에 닿는다.
extension RichMarkdownDocumentView: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tail == rhs.tail
            && lhs.document == rhs.document
            && lhs.images.count == rhs.images.count
            && lhs.images.allSatisfy { rhs.images[$0.key]?.image === $0.value.image }
    }
}

/// 테스트 전용 관측점. body 평가 횟수를 센다. 기본값 nil이라 앱에서는 environment 읽기 외 비용이 없다.
/// environment에서는 `RichMarkdownView`만 읽는다(어차피 markdown마다 도는 body).
@MainActor
final class RichMarkdownBodyProbe {
    /// `RichMarkdownView` body 평가 수와 그중 원문 fallback을 고른 수.
    private(set) var rootBodies = 0
    private(set) var fallbackBodies = 0
    /// `RichMarkdownDocumentView` body 평가 수.
    private(set) var documentBodies = 0

    func didEvaluateRoot(showsDocument: Bool) {
        rootBodies += 1
        if !showsDocument { fallbackBodies += 1 }
    }

    func didEvaluateDocument() {
        documentBodies += 1
    }
}

private struct RichMarkdownBodyProbeKey: EnvironmentKey {
    static let defaultValue: RichMarkdownBodyProbe? = nil
}

extension EnvironmentValues {
    var richMarkdownBodyProbe: RichMarkdownBodyProbe? {
        get { self[RichMarkdownBodyProbeKey.self] }
        set { self[RichMarkdownBodyProbeKey.self] = newValue }
    }
}

// MARK: - Blocks

struct RichMarkdownBlockView: View {
    let block: ParsedBlock
    let images: [MathSegment: RenderedMath]
    /// 스트리밍 tail 문맥. 컨테이너 블록은 마지막 자식에만 넘겨 리프 문단·헤딩에서 소비한다.
    var tail: RichMarkdownStreamingTailContext? = nil
    @Environment(\.richMarkdownTheme) private var theme

    var body: some View {
        switch block {
        case .paragraph(let runs):
            InlineRunsText(runs: runs, images: images, font: theme.bodyFont, tail: tail)

        case .heading(let level, let runs):
            InlineRunsText(runs: runs, images: images, font: theme.headingFont(level: level), tail: tail)
                .accessibilityAddTraits(.isHeader)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .blockMath(let segment):
            BlockMathView(segment: segment, rendered: images[segment])

        case .blockQuote(let children):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.quoteBar)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
                        RichMarkdownBlockView(
                            block: child,
                            images: images,
                            tail: offset == children.count - 1 ? tail : nil
                        )
                        .equatable()
                    }
                }
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .richMarkdownFont(theme.bodyFont)
                            .foregroundStyle(theme.textColor)
                        listItemStack(item, isLastItem: index == items.count - 1)
                    }
                }
            }

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .richMarkdownFont(theme.bodyFont)
                            .monospacedDigit()
                            .foregroundStyle(theme.textColor)
                        listItemStack(item, isLastItem: index == items.count - 1)
                    }
                }
            }

        case .table(let table):
            TableBlockView(table: table, images: images)

        case .thematicBreak:
            Divider()
        }
    }

    /// 리스트 항목의 블록 묶음. tail은 마지막 항목의 마지막 블록에만 닿는다.
    private func listItemStack(_ item: [ParsedBlock], isLastItem: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(item.enumerated()), id: \.offset) { offset, child in
                RichMarkdownBlockView(
                    block: child,
                    images: images,
                    tail: isLastItem && offset == item.count - 1 ? tail : nil
                )
                .equatable()
            }
        }
    }
}

/// 블록 경계의 값 비교. 스트리밍으로 마지막 블록·항목만 바뀌는 게시에서 나머지 블록의
/// body 재평가를 건너뛴다.
///
/// 판정은 블록 값, tail 문맥, **이 블록이 쓰는 수식**의 이미지 identity로 한다. 이미지
/// 사전 전체는 비교하지 않는다 — 다른 블록의 hydration이 이 블록을 다시 그리게 하지 않는다.
/// segment는 이 블록 안에서만 모으므로 비용은 블록 크기에 비례한다.
/// 테마·폰트 배율·color scheme은 environment다. 이를 읽는 하위 뷰는 이 판정과 별개로
/// 무효화되므로 판정에 넣지 않는다.
extension RichMarkdownBlockView: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.tail == rhs.tail
            && ParsedDocument(blocks: [lhs.block]).allMathSegments.allSatisfy {
                lhs.images[$0]?.image === rhs.images[$0]?.image
            }
    }
}

private struct TableBlockView: View {
    let table: ParsedTable
    let images: [MathSegment: RenderedMath]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.header, rowNumber: nil)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, rowNumber: index + 1)
                }
            }
        }
        .accessibilityLabel("표")
    }

    @ViewBuilder
    private func tableRow(_ cells: [[InlineRun]], rowNumber: Int?) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, runs in
                TableCellView(
                    runs: rowNumber == nil ? runs.map(\.boldened) : runs,
                    images: images,
                    alignment: alignment(at: column),
                    textAlignment: textAlignment(at: column),
                    isHeader: rowNumber == nil,
                    accessibilityHint: accessibilityHint(rowNumber: rowNumber, column: column)
                )
            }
        }
    }

    private func alignment(at column: Int) -> Alignment {
        guard table.columnAlignments.indices.contains(column) else { return .leading }
        switch table.columnAlignments[column] {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    private func textAlignment(at column: Int) -> TextAlignment {
        guard table.columnAlignments.indices.contains(column) else { return .leading }
        switch table.columnAlignments[column] {
        case .center: return .center
        case .right: return .trailing
        case .left, .none: return .leading
        }
    }

    private func accessibilityHint(rowNumber: Int?, column: Int) -> String {
        guard let rowNumber else { return "열 \(column + 1), 헤더" }
        let header = table.header.indices.contains(column)
            ? accessibilityText(for: table.header[column]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return "행 \(rowNumber), 열 \(column + 1), 헤더 \(header)"
    }
}

private struct TableCellView: View {
    let runs: [InlineRun]
    let images: [MathSegment: RenderedMath]
    let alignment: Alignment
    let textAlignment: TextAlignment
    let isHeader: Bool
    let accessibilityHint: String

    @Environment(\.richMarkdownTheme) private var theme

    var body: some View {
        InlineRunsText(runs: runs, images: images, font: theme.bodyFont)
            .multilineTextAlignment(textAlignment)
            .frame(minWidth: 96, maxWidth: 240, alignment: alignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHeader ? theme.codeHeaderBackground : Color.clear)
            .overlay(Rectangle().stroke(theme.textColor.opacity(0.2), lineWidth: 0.5))
            .accessibilityAddTraits(isHeader ? .isHeader : [])
            .accessibilityHint(accessibilityHint)
    }
}

extension InlineRun {
    var boldened: InlineRun {
        var copy = self
        copy.bold = true
        return copy
    }
}

// MARK: - Inline runs

struct InlineRunsText: View {
    let runs: [InlineRun]
    let images: [MathSegment: RenderedMath]
    /// 감싼 블록의 폰트. 문단은 `bodyFont`, 헤딩은 해당 레벨 폰트다.
    let font: RichMarkdownFont
    /// 스트리밍 tail 문맥. nil이면 표시 변환 없음.
    var tail: RichMarkdownStreamingTailContext? = nil
    @Environment(\.richMarkdownTheme) private var theme
    @Environment(\.richMarkdownFontScale) private var fontScale

    var body: some View {
        // 표시용 run은 body마다 한 번만 만든다. 칩 판정·접근성 라벨도 이 run을 써서 숨긴 마크가
        // 읽히거나 칩 경로를 고르지 않게 한다.
        let displayRuns = self.displayRuns
        decorated(combinedText(displayRuns), hasInlineCode: Self.hasInlineCode(displayRuns))
            .modifier(MathAccessibilityLabel(runs: displayRuns))
    }

    /// 표시용 run. 스트리밍 tail이면 미닫힌 opener를 숨긴 결과다.
    private var displayRuns: [InlineRun] {
        guard let tail, tail.options.hidesUnclosedInlineMarks else { return runs }
        return StreamingTail.hidingUnclosedOpeners(runs, dollarMath: tail.dollarMath.core)
    }

    /// iOS 18+는 `TextRenderer`로 인라인 코드 칩(둥근 배경+테두리)을 그린다.
    /// 이전 OS는 `append(_:to:)`가 넣은 사각 `backgroundColor`가 fallback이다.
    ///
    /// `.textSelection(.enabled)`은 선택 가능한 텍스트 경로로 바꿔 커스텀
    /// `TextRenderer` 드로잉을 우회한다(실측 — 수식자 순서와 무관). 그래서
    /// 인라인 코드가 있는 문단만 선택 대신 칩을 택한다. UIKit 렌더러는
    /// 둘 다 지원하므로 선택이 필요하면 `RichMarkdownUIView`를 쓴다.
    @ViewBuilder
    private func decorated(_ text: Text, hasInlineCode: Bool) -> some View {
        if #available(iOS 18.0, *), hasInlineCode {
            text.textRenderer(
                InlineCodeChipTextRenderer(
                    background: theme.inlineCodeBackground,
                    border: theme.inlineCodeBorder
                )
            )
        } else {
            text.textSelection(.enabled)
        }
    }

    private static func hasInlineCode(_ runs: [InlineRun]) -> Bool {
        runs.contains { run in
            if case .code = run.content { return true }
            return false
        }
    }

    /// 이어지는 run을 `Text` 하나의 AttributedString으로 합친다. `Text`를 끊는 것은 따로 둬야 하는
    /// 것뿐이다: 굵기가 바뀌는 곳(`Text.bold()`), iOS 18 인라인 코드(칩 attribute는 `Text`에만 붙는다),
    /// 수식 이미지, 줄바꿈 앞뒤의 굵은 run. 꼬리 페이드의 grapheme 조각도 같은 AttributedString에
    /// 붙인다 — 조각마다 `Text`를 만들면 tick마다 `Text` 해석이 조각 수만큼 늘어난다.
    private func combinedText(_ runs: [InlineRun]) -> Text {
        let plan = StreamingTail.fadePlan(
            runs,
            graphemeCount: tail?.options.tailFadeGraphemeCount ?? 0
        )
        var builder = InlineTextBuilder()
        for run in plan.head {
            append(run, to: &builder)
        }
        // 꼬리 조각은 grapheme 하나씩 alpha만 다르고 나머지 스타일은 원 run을 따른다.
        for piece in plan.tail {
            builder.append(segment(piece.text, run: piece.run, alpha: piece.alpha), bold: piece.run.bold)
        }
        return builder.build()
    }

    private func append(_ run: InlineRun, to builder: inout InlineTextBuilder) {
        switch run.content {
        case .text(let string):
            builder.append(segment(string, run: run), bold: run.bold)

        case .code(let code):
            if #available(iOS 18.0, *) {
                // 칩은 `InlineCodeChipTextRenderer`가 그린다. 사각 배경을 겹치지 않는다.
                let text = Text(codeSegment(code, run: run, background: nil))
                builder.append((run.bold ? text.bold() : text).customAttribute(InlineCodeChipTextAttribute()))
            } else {
                // iOS 16·17 fallback: Text run은 둥근 칩을 그릴 수 없어 사각 배경까지만.
                builder.append(codeSegment(code, run: run, background: theme.inlineCodeBackground), bold: run.bold)
            }

        case .math(let segment):
            if let rendered = images[segment] {
                // `-descent` baseline 보정 (DEVELOPMENT.md §5).
                builder.append(Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent))
            } else {
                // 렌더 전/실패 시 원래 구분자를 포함한 source를 표시한다.
                builder.append(self.segment(segment.source, run: run), bold: run.bold)
            }

        case .link(let label, let destination):
            // 대비 기준을 넘는 링크 색 + 밑줄(색 외 구분 수단).
            builder.append(segment(label, run: run, link: destination), bold: run.bold)

        case .hardBreak:
            // 폰트·색 없이 둔다(환경 값). 굵게도 하지 않는다 — 줄 높이가 이전과 같다.
            builder.append(AttributedString("\n"), bold: false)

        case .softBreak:
            builder.append(AttributedString(" "), bold: false)
        }
    }

    /// 본문·링크·수식 원문 조각. 기본 전경색과 폰트를 싣는다.
    ///
    /// `Text`는 색·폰트를 지정하지 않으면 주변 환경 값을 쓴다. 그러면 `theme.textColor`와
    /// `theme.bodyFont`가 본문 글자에 닿지 않고, 소비 앱이 바깥에 건 `.font(_:)`가
    /// 우연히 새어 들어온다. 모든 텍스트 run은 여기서 값을 실어
    /// UIKit 렌더러(`RichMarkdownUIView`)와 같은 규칙을 갖는다.
    private func segment(
        _ string: String,
        run: InlineRun,
        alpha: Double = 1,
        link: URL? = nil
    ) -> AttributedString {
        InlineSegments.attributed(InlineSegments.Key(
            string: string,
            link: link,
            italic: run.italic,
            strikethrough: run.strikethrough,
            font: font,
            scale: fontScale.factor(for: font.relativeTo),
            foreground: link == nil ? theme.textColor : theme.linkColor,
            alpha: alpha,
            background: nil
        ))
    }

    private func codeSegment(_ code: String, run: InlineRun, background: Color?) -> AttributedString {
        InlineSegments.attributed(InlineSegments.Key(
            string: code,
            link: nil,
            italic: run.italic,
            strikethrough: run.strikethrough,
            font: theme.codeFont,
            scale: fontScale.factor(for: theme.codeFont.relativeTo),
            foreground: theme.inlineCodeForeground,
            alpha: 1,
            background: background
        ))
    }
}

/// 같은 굵기로 이어지는 AttributedString 조각을 `Text` 하나로 모은다.
///
/// 굵게는 `Text.bold()`로 준다. bold를 `inlinePresentationIntent`로 함께 주면 italic과 겹칠 때
/// 한글처럼 italic 변형이 없는 폰트에서 굵기까지 잃는다.
private struct InlineTextBuilder {
    private var result: Text?
    private var pending = AttributedString()
    private var pendingBold = false

    mutating func append(_ attributed: AttributedString, bold: Bool) {
        if bold != pendingBold { flush() }
        pendingBold = bold
        pending.append(attributed)
    }

    /// 따로 둬야 하는 `Text`(인라인 코드 칩, 수식 이미지).
    mutating func append(_ text: Text) {
        flush()
        result = result.map { $0 + text } ?? text
    }

    mutating func build() -> Text {
        flush()
        return result ?? Text(verbatim: "")
    }

    private mutating func flush() {
        guard !pending.characters.isEmpty else { return }
        let text = pendingBold ? Text(pending).bold() : Text(pending)
        result = result.map { $0 + text } ?? text
        pending = AttributedString()
    }
}

/// run 하나(또는 꼬리 조각)의 AttributedString과 해석한 폰트를 재사용한다. 스트리밍 tail 문단은
/// tick마다 다시 그려지지만 자라는 마지막 run 앞의 run은 그대로다 — 같은 입력이면 지난 값을 쓴다.
@MainActor
enum InlineSegments {
    /// 조각의 스타일을 정하는 입력 전부.
    struct Key: Hashable {
        let string: String
        let link: URL?
        let italic: Bool
        let strikethrough: Bool
        let font: RichMarkdownFont
        let scale: CGFloat
        let foreground: Color
        let alpha: Double
        let background: Color?
    }

    private struct FontKey: Hashable {
        let font: RichMarkdownFont
        let scale: CGFloat
    }

    // ponytail: 2세대 캐시(세대당 128개)와 길이 상한. 자라는 마지막 run은 tick마다 키가 바뀌어
    // 맞지 않으므로 긴 문자열은 넣지 않는다. 적중률이 문제면 문단 단위 캐시로 바꾼다.
    private static let generationLimit = 128
    private static let maximumCachedUTF8 = 256
    private static var current: [Key: AttributedString] = [:]
    private static var previous: [Key: AttributedString] = [:]
    private static var fonts: [FontKey: Font] = [:]

    static func attributed(_ key: Key) -> AttributedString {
        guard key.string.utf8.count <= maximumCachedUTF8 else { return make(key) }
        if let hit = current[key] { return hit }
        let value = previous[key] ?? make(key)
        if current.count >= generationLimit {
            previous = current
            current = [:]
        }
        current[key] = value
        return value
    }

    static func font(_ font: RichMarkdownFont, scale: CGFloat) -> Font {
        let key = FontKey(font: font, scale: scale)
        if let hit = fonts[key] { return hit }
        let resolved = font.resolvedFont(scaledBy: scale)
        // ponytail: 테마 폰트 × Dynamic Type 크기만큼만 생긴다. 넘치면 비운다.
        if fonts.count >= 64 { fonts.removeAll() }
        fonts[key] = resolved
        return resolved
    }

    /// 기울임·취소선은 `inlinePresentationIntent`로 준다. `Text.italic()`/`.strikethrough()`는
    /// 여러 `Text`를 `+`로 합치면 사라진다. 한글은 시스템 폰트에 italic 변형이 없어 기울임이
    /// 시각적으로 적용되지 않는다(iOS 제약). 영문·숫자에는 적용된다.
    private static func make(_ key: Key) -> AttributedString {
        var attributed = AttributedString(key.string)
        attributed.foregroundColor = key.alpha < 1 ? key.foreground.opacity(key.alpha) : key.foreground
        attributed.font = font(key.font, scale: key.scale)
        if let link = key.link {
            attributed.link = link
            attributed.underlineStyle = .single
        }
        if let background = key.background {
            attributed.backgroundColor = background
        }
        var intent: InlinePresentationIntent = []
        if key.italic { intent.insert(.emphasized) }
        if key.strikethrough { intent.insert(.strikethrough) }
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        return attributed
    }
}

/// 수식이 든 문단의 접근성 표현: "수식: 원본 LaTeX"를 읽기 순서대로 제공한다.
/// 링크가 있는 문단에는 label을 덮어쓰지 않는다 — 개별 link semantics를 없애지 않기 위함 (§5).
private struct MathAccessibilityLabel: ViewModifier {
    let runs: [InlineRun]

    func body(content: Content) -> some View {
        if hasMath && !hasLink {
            content.accessibilityLabel(spokenText)
        } else {
            content
        }
    }

    private var hasMath: Bool {
        runs.contains { if case .math = $0.content { return true } else { return false } }
    }

    private var hasLink: Bool {
        runs.contains { if case .link = $0.content { return true } else { return false } }
    }

    private var spokenText: String {
        accessibilityText(for: runs)
    }
}

private func accessibilityText(for runs: [InlineRun]) -> String {
    runs.map { run in
        switch run.content {
        case .text(let string): return string
        case .code(let code): return code
        case .math(let segment): return "수식: \(segment.latex)"
        case .link(let label, _): return label
        case .hardBreak, .softBreak: return " "
        }
    }.joined()
}

// MARK: - Block math

struct BlockMathView: View {
    let segment: MathSegment
    let rendered: RenderedMath?
    @Environment(\.richMarkdownTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let rendered {
                // 정렬은 콘텐츠가 뷰포트보다 좁을 때만 의미가 있다. GeometryReader로
                // 뷰포트 폭을 얻어 minWidth로 채우고, 높이는 이미지 크기로 고정해
                // GeometryReader의 greedy 세로 확장을 막는다.
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        Image(uiImage: rendered.image)
                            .frame(minWidth: proxy.size.width, alignment: alignment)
                            .accessibilityLabel("수식: \(segment.latex)")
                    }
                }
                .frame(height: rendered.image.size.height)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: segment.source)
                        .richMarkdownFont(theme.codeFont)
                        .foregroundStyle(theme.textColor)
                        .textSelection(.enabled)
                }
            }
            CopyButton(text: segment.source, accessibilityLabel: "수식 원문 복사")
        }
    }

    private var alignment: Alignment {
        switch theme.equationAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let language: String?
    let code: String
    @Environment(\.richMarkdownTheme) private var theme
    @Environment(\.richMarkdownCodeBlocks) private var codeBlocks

    /// 도착한 색 범위는 원문·언어·공급자가 모두 같은 요청에만 사용한다.
    @State private var highlight: HighlightState?

    private struct HighlightRequest: Sendable, Equatable {
        let code: String
        let language: String?
        let highlighter: (any RichMarkdownSyntaxHighlighting)?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.code == rhs.code && lhs.language == rhs.language && lhs.highlighter === rhs.highlighter
        }
    }

    private struct HighlightState {
        let request: HighlightRequest
        let spans: [RichMarkdownHighlightSpan]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language ?? "code")
                    .richMarkdownFont(theme.codeLabelFont)
                    // secondary(60% 회색)를 밝은 헤더 배경에 쓰면 작은 텍스트 대비
                    // 기준(4.5:1)에 미달해 접근성 audit이 실패한다. 테마 텍스트 색을 쓴다.
                    .foregroundStyle(theme.textColor)
                Spacer(minLength: 8)
                CopyButton(text: code, accessibilityLabel: "코드 복사")
            }
            .padding(.horizontal, 12)
            .background(theme.codeHeaderBackground)

            blockBody(diagram: codeBlocks.diagramRenderer(for: language))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 다이어그램 렌더러가 담당하는 언어면 본문을 그 뷰로 대체한다. 헤더(언어 라벨·복사)는
    /// 그대로 두어 원문을 항상 가져갈 수 있다.
    @ViewBuilder
    private func blockBody(diagram: (any RichMarkdownDiagramRendering)?) -> some View {
        if let diagram {
            diagram.makeSwiftUIView(source: code, theme: theme)
                .background(theme.codeBlockBackground)
        } else {
            let request = highlightRequest
            ScrollView(.horizontal, showsIndicators: false) {
                Text(attributedCode(for: request))
                    .richMarkdownFont(theme.codeFont)
                    .foregroundStyle(theme.textColor)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(theme.codeBlockBackground)
            // 색은 늦게 와도 된다. 먼저 plain으로 그리고 범위가 도착하면 색만 바꾼다 —
            // 글자·폰트가 그대로라 코드 블록 크기는 달라지지 않는다.
            .task(id: request) { await loadHighlight(for: request) }
        }
    }

    private var highlightRequest: HighlightRequest {
        HighlightRequest(code: code, language: language, highlighter: codeBlocks.highlighter)
    }

    private func attributedCode(for request: HighlightRequest) -> AttributedString {
        guard let highlight, highlight.request == request else { return AttributedString(request.code) }
        return RichMarkdownHighlightSegments.attributedString(
            code: request.code,
            spans: highlight.spans,
            colors: theme.syntax
        )
    }

    private func loadHighlight(for request: HighlightRequest) async {
        guard !Task.isCancelled, request == highlightRequest else { return }
        highlight = nil
        guard let highlighter = request.highlighter, let language = request.language,
              !request.code.isEmpty
        else { return }
        let spans = await highlighter.spans(for: request.code, language: language)
        // 미지원 언어·실패는 빈 배열이다. 그대로 plain을 유지한다.
        guard !Task.isCancelled, request == highlightRequest else { return }
        highlight = HighlightState(request: request, spans: spans)
    }
}

// MARK: - Copy button

struct CopyButton: View {
    let text: String
    let accessibilityLabel: String
    @State private var copied = false
    @Environment(\.richMarkdownTheme) private var theme

    /// 복사 동작. 원래 구분자를 포함한 원문 source를 그대로 넣는다.
    /// 러너 프로세스에서 pasteboard를 읽으면 권한 프롬프트가 뜨므로
    /// 검증은 UI 테스트가 아니라 앱 프로세스 안의 unit test에서 한다.
    @MainActor
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general) {
        pasteboard.string = text
    }

    var body: some View {
        Button {
            Self.copy(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .imageScale(.small)
                // UIKit 렌더러와 같은 색 규칙. 기본 accent(파랑)로 두면 두 렌더러의
                // 아이콘 색이 갈리고 테마로 제어할 수 없다.
                .foregroundStyle(theme.textColor)
                // 최소 44×44pt hit target (§5 접근성).
                // 고정 크기다: 아이콘 교체로 폭이 바뀌면 가로 ScrollView가 재측정되고
                // XCUITest의 "wait for app to idle"이 풀리지 않는다.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        // ponytail: 체크 표시는 다시 누를 때까지 유지한다. 타이머 기반 자동 복귀는
        // XCUITest의 "wait for app to idle"을 붙잡아 UI 테스트를 느리게 만든다.
    }
}
