import SwiftUI
import SwiftLatexCore

/// v1 공개 API (DEVELOPMENT.md §2).
///
/// ```swift
/// LatexMarkdownView(markdown: message, parsesDollarMath: false)
///     .latexTheme(.default)
/// ```
public struct LatexMarkdownView: View {
    private let markdown: String
    private let parsesDollarMath: Bool

    @StateObject private var model = LatexRenderModel()
    @Environment(\.latexTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    /// Dynamic Type 배율. `@ScaledMetric`의 `relativeTo`는 컴파일 시점 상수여야 해서
    /// 크기 대신 배율만 재고 `bodyFont` 크기에 곱한다.
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 100

    public init(markdown: String, parsesDollarMath: Bool = false) {
        self.markdown = markdown
        self.parsesDollarMath = parsesDollarMath
    }

    public var body: some View {
        content
            .task(id: currentRequest) {
                model.submit(currentRequest)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            VStack(alignment: .leading, spacing: 12) {
                // identity는 렌더 시점의 위치 + content digest. 편집 사이 영속성은 약속하지 않는다.
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    LatexBlockView(block: block, images: model.mathImages)
                }
            }
        } else {
            // 최신 원문 fallback 즉시 표시 (§4).
            Text(markdown)
                .font(theme.bodyFont.resolvedFont)
                .foregroundStyle(theme.textColor)
                .textSelection(.enabled)
        }
    }

    /// 수식 raster 기준 크기. `theme.bodyFont` 크기를 Dynamic Type 배율로 스케일한다.
    /// 배율 기준은 항상 `.body`다 — `bodyFont.relativeTo`를 다른 스타일로 두면
    /// 수식은 body 배율로 커진다.
    private var mathPointSize: CGFloat { theme.bodyFont.unscaledSize * bodyScale / 100 }

    private var currentRequest: LatexRenderModel.Request {
        LatexRenderModel.Request(
            markdown: markdown,
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
                            .font(theme.bodyFont.resolvedFont)
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
                            .font(theme.bodyFont.resolvedFont)
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

        case .thematicBreak:
            Divider()
        }
    }

}

// MARK: - Inline runs

struct InlineRunsText: View {
    let runs: [InlineRun]
    let images: [MathSegment: RenderedMath]
    /// 감싼 블록의 폰트. 문단은 `bodyFont`, 헤딩은 해당 레벨 폰트다.
    let font: LatexFont
    @Environment(\.latexTheme) private var theme

    var body: some View {
        combinedText
            .textSelection(.enabled)
            .modifier(MathAccessibilityLabel(runs: runs))
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
            attributed.font = theme.codeFont.resolvedFont
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
        attributed.font = font.resolvedFont
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
}

// MARK: - Block math

struct BlockMathView: View {
    let segment: MathSegment
    let rendered: RenderedMath?
    @Environment(\.latexTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                if let rendered {
                    Image(uiImage: rendered.image)
                        .accessibilityLabel("수식: \(segment.latex)")
                } else {
                    Text(verbatim: segment.source)
                        .font(theme.codeFont.resolvedFont)
                        .foregroundStyle(theme.textColor)
                        .textSelection(.enabled)
                }
            }
            CopyButton(text: segment.source, accessibilityLabel: "수식 원문 복사")
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
                    .font(theme.codeLabelFont.resolvedFont)
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
                    .font(theme.codeFont.resolvedFont)
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
