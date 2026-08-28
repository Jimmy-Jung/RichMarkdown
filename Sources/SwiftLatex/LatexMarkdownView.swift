import SwiftUI
import SwiftLatexCore

/// v1 공개 API (DEVELOPMENT.md §2).
///
/// ```swift
/// LatexMarkdownView(markdown: message, parsesDollarMath: false)
///     .latexTheme(.default)
/// ```
public struct LatexMarkdownView: View {
    /// public ingress에서 한 번 제한한 canonical 입력. 원문 전체를 View 수명 동안
    /// 보관하지 않아 large markdown이 SwiftUI state에 남지 않는다.
    private let boundedMarkdown: InputLimits.BoundedInput
    private let parsesDollarMath: Bool

    @StateObject private var model = LatexRenderModel()
    @Environment(\.latexTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    /// `@ScaledMetric(relativeTo:)`의 기준 style은 컴파일 시점 상수여서 style별
    /// 배율을 root에서 측정한 뒤 하위 renderer에 environment로 전달한다.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1
    @ScaledMetric(relativeTo: .headline) private var headlineScale: CGFloat = 1
    @ScaledMetric(relativeTo: .title) private var titleScale: CGFloat = 1
    @ScaledMetric(relativeTo: .title2) private var title2Scale: CGFloat = 1
    @ScaledMetric(relativeTo: .title3) private var title3Scale: CGFloat = 1
    @ScaledMetric(relativeTo: .caption) private var captionScale: CGFloat = 1

    public init(markdown: String, parsesDollarMath: Bool = false) {
        self.boundedMarkdown = InputLimits.bound(markdown)
        self.parsesDollarMath = parsesDollarMath
    }

    public var body: some View {
        // 요청을 한 번만 canonicalize한다. 대형 원문의 bounded fallback도 body와
        // `.task(id:)`가 같은 값을 써야 이전 문서가 한 프레임 되살아나지 않는다.
        let request = currentRequest
        content(for: request)
            .environment(\.latexFontScale, fontScale)
            .task(id: request) {
                model.submit(request)
            }
    }

    @ViewBuilder
    private func content(for request: LatexRenderModel.Request) -> some View {
        // `.task(id:)`는 body 뒤에 시작된다. 모델 문서가 현재 요청과 같은 parse identity거나
        // 그 **스트리밍 prefix**면 표시한다 — append 중에는 새 parse가 게시될 때까지 이전
        // 렌더를 유지해 화면 전체가 원문 fallback으로 출렁이지 않게 한다. 다른 문서
        // (셀 재사용)는 여전히 한 프레임도 되살아나지 않는다.
        if let identity = model.parseIdentity,
           identity == request.parseIdentity || identity.isStreamingPrefix(of: request.parseIdentity),
           let document = model.document {
            // 색·폰트·scale이 바뀐 새 raster가 준비되기 전에는 이전 bitmap을 섞지 않고
            // source fallback을 유지한다. markdown만 다른 stale 이미지는 계속 쓴다 —
            // 수식 raster는 문서 안 위치와 무관하다.
            let images = model.imageRequest?.matchesRasterConfiguration(of: request) == true
                ? model.mathImages : [:]
            VStack(alignment: .leading, spacing: 12) {
                // identity는 렌더 시점의 위치 + content digest. 편집 사이 영속성은 약속하지 않는다.
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    LatexBlockView(block: block, images: images)
                }
            }
        } else {
            // Request가 입력을 제한해 보관하므로 raw markdown을 UI에 직접 전달하지 않는다.
            Text(request.markdown)
                .latexFont(theme.bodyFont)
                .foregroundStyle(theme.textColor)
                .textSelection(.enabled)
        }
    }

    /// 수식 raster 기준 크기. 수식은 본문 폰트가 선택한 Dynamic Type 기준을 따른다.
    private var mathPointSize: CGFloat { theme.bodyFont.scaledPointSize(using: fontScale) }

    private var fontScale: LatexFontScale {
        LatexFontScale(
            body: bodyScale,
            headline: headlineScale,
            title: titleScale,
            title2: title2Scale,
            title3: title3Scale,
            caption: captionScale
        )
    }

    private var currentRequest: LatexRenderModel.Request {
        LatexRenderModel.Request(
            boundedInput: boundedMarkdown,
            parsesDollarMath: parsesDollarMath,
            pointSize: mathPointSize,
            colorRGBA: resolvedTextColorRGBA,
            displayScale: displayScale,
            mathFont: theme.mathFont
        )
    }

    private var resolvedTextColorRGBA: UInt32 {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return UIColor(theme.textColor)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .rgbaValue
    }
}

// MARK: - Blocks

struct LatexBlockView: View {
    let block: ParsedBlock
    let images: [MathSegment: RenderedMath]
    @Environment(\.latexTheme) private var theme

    var body: some View {
        switch block {
        case .paragraph(let runs):
            InlineRunsText(runs: runs, images: images, font: theme.bodyFont)

        case .heading(let level, let runs):
            InlineRunsText(runs: runs, images: images, font: theme.headingFont(level: level))
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
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        LatexBlockView(block: child, images: images)
                    }
                }
            }

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .latexFont(theme.bodyFont)
                            .foregroundStyle(theme.textColor)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(item.enumerated()), id: \.offset) { _, child in
                                LatexBlockView(block: child, images: images)
                            }
                        }
                    }
                }
            }

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .latexFont(theme.bodyFont)
                            .monospacedDigit()
                            .foregroundStyle(theme.textColor)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(item.enumerated()), id: \.offset) { _, child in
                                LatexBlockView(block: child, images: images)
                            }
                        }
                    }
                }
            }

        case .table(let table):
            TableBlockView(table: table, images: images)

        case .thematicBreak:
            Divider()
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

    @Environment(\.latexTheme) private var theme

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
    let font: LatexFont
    @Environment(\.latexTheme) private var theme
    @Environment(\.latexFontScale) private var fontScale

    var body: some View {
        chipDecoratedText
            .modifier(MathAccessibilityLabel(runs: runs))
    }

    /// iOS 18+는 `TextRenderer`로 인라인 코드 칩(둥근 배경+테두리)을 그린다.
    /// 이전 OS는 `text(for:)`가 넣은 사각 `backgroundColor`가 fallback이다.
    ///
    /// `.textSelection(.enabled)`은 선택 가능한 텍스트 경로로 바꿔 커스텀
    /// `TextRenderer` 드로잉을 우회한다(실측 — 수식자 순서와 무관). 그래서
    /// 인라인 코드가 있는 문단만 선택 대신 칩을 택한다. UIKit 렌더러는
    /// 둘 다 지원하므로 선택이 필요하면 `LatexMarkdownUIView`를 쓴다.
    @ViewBuilder private var chipDecoratedText: some View {
        if #available(iOS 18.0, *), hasInlineCode {
            combinedText.textRenderer(
                InlineCodeChipTextRenderer(
                    background: theme.inlineCodeBackground,
                    border: theme.inlineCodeBorder
                )
            )
        } else {
            combinedText.textSelection(.enabled)
        }
    }

    private var hasInlineCode: Bool {
        runs.contains { run in
            if case .code = run.content { return true }
            return false
        }
    }

    private var combinedText: Text {
        runs.reduce(Text(verbatim: "")) { partial, run in
            partial + text(for: run)
        }
    }

    private func text(for run: InlineRun) -> Text {
        switch run.content {
        case .text(let string):
            return styled(Text(emphasized(base(string), run)), run)

        case .code(let code):
            var attributed = base(code)
            attributed.font = theme.codeFont.resolvedFont(
                scaledBy: fontScale.factor(for: theme.codeFont.relativeTo)
            )
            attributed.foregroundColor = theme.inlineCodeForeground
            if #available(iOS 18.0, *) {
                // 칩은 `InlineCodeChipTextRenderer`가 그린다. 사각 배경을 겹치지 않는다.
                return styled(Text(emphasized(attributed, run)), run)
                    .customAttribute(InlineCodeChipTextAttribute())
            }
            // iOS 16·17 fallback: Text run은 둥근 칩을 그릴 수 없어 사각 배경까지만.
            attributed.backgroundColor = theme.inlineCodeBackground
            return styled(Text(emphasized(attributed, run)), run)

        case .math(let segment):
            if let rendered = images[segment] {
                // `-descent` baseline 보정 (DEVELOPMENT.md §5).
                return Text(Image(uiImage: rendered.image))
                    .baselineOffset(-rendered.descent)
            }
            // 렌더 전/실패 시 원래 구분자를 포함한 source를 표시한다.
            return styled(Text(emphasized(base(segment.source), run)), run)

        case .link(let label, let destination):
            var attributed = base(label)
            attributed.link = destination
            // 대비 기준을 넘는 링크 색 + 밑줄(색 외 구분 수단).
            attributed.foregroundColor = theme.linkColor
            attributed.underlineStyle = .single
            return styled(Text(emphasized(attributed, run)), run)

        case .hardBreak:
            return Text(verbatim: "\n")

        case .softBreak:
            return Text(verbatim: " ")
        }
    }

    /// 기본 전경색과 폰트를 실은 AttributedString.
    ///
    /// `Text`는 색·폰트를 지정하지 않으면 주변 환경 값을 쓴다. 그러면 `theme.textColor`와
    /// `theme.bodyFont`가 본문 글자에 닿지 않고, 소비 앱이 바깥에 건 `.font(_:)`가
    /// 우연히 새어 들어온다. 모든 텍스트 run은 여기서 값을 실어
    /// UIKit 렌더러(`LatexMarkdownUIView`)와 같은 규칙을 갖는다.
    private func base(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        attributed.foregroundColor = theme.textColor
        attributed.font = font.resolvedFont(scaledBy: fontScale.factor(for: font.relativeTo))
        return attributed
    }

    /// 굵게/기울임/취소선 적용.
    ///
    /// - 기울임·취소선은 AttributedString의 `inlinePresentationIntent`로 준다.
    ///   `Text.italic()`/`.strikethrough()`는 여러 `Text`를 `+`로 합치면 사라진다.
    /// - 굵게는 `Text.bold()`로 준다. bold를 intent로 함께 주면 italic과 겹칠 때
    ///   한글처럼 italic 변형이 없는 폰트에서 굵기까지 잃는다.
    /// - 한글은 시스템 폰트에 italic 변형이 없어 기울임이 시각적으로 적용되지 않는다
    ///   (iOS 제약). 영문·숫자에는 적용된다.
    private func styled(_ text: Text, _ run: InlineRun) -> Text {
        run.bold ? text.bold() : text
    }

    private func emphasized(_ attributed: AttributedString, _ run: InlineRun) -> AttributedString {
        var intent: InlinePresentationIntent = []
        if run.italic { intent.insert(.emphasized) }
        if run.strikethrough { intent.insert(.strikethrough) }
        guard !intent.isEmpty else { return attributed }
        var copy = attributed
        copy.inlinePresentationIntent = intent
        return copy
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
    @Environment(\.latexTheme) private var theme

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
                        .latexFont(theme.codeFont)
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
    @Environment(\.latexTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language ?? "code")
                    .latexFont(theme.codeLabelFont)
                    // secondary(60% 회색)를 밝은 헤더 배경에 쓰면 작은 텍스트 대비
                    // 기준(4.5:1)에 미달해 접근성 audit이 실패한다. 테마 텍스트 색을 쓴다.
                    .foregroundStyle(theme.textColor)
                Spacer(minLength: 8)
                CopyButton(text: code, accessibilityLabel: "코드 복사")
            }
            .padding(.horizontal, 12)
            .background(theme.codeHeaderBackground)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .latexFont(theme.codeFont)
                    .foregroundStyle(theme.textColor)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(theme.codeBlockBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Copy button

struct CopyButton: View {
    let text: String
    let accessibilityLabel: String
    @State private var copied = false
    @Environment(\.latexTheme) private var theme

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
