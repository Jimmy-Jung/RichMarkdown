// Author: JunyoungJung
// Date: 2026-10-16

import SwiftUI
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// `InlineRunsText`가 run을 `Text` 몇 개로 합쳐도 화면은 run마다 `Text`를 만들던 이전 구성과
/// 픽셀 단위로 같다. 기준(`LegacyInlineRunsText`)은 이전 구현을 그대로 옮긴 것이다.
@MainActor
@Suite(.serialized) struct InlineRunsTextEquivalenceTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let markdown: String
        var streaming = false
        var smallFont = false
        var fontScale: CGFloat = 1
        var mathImage = false

        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "styled", markdown: "가나다 ABC **굵게** 그리고 *기울임 italic* ~~취소~~ [링크](https://example.com) 끝"),
        Case(name: "code", markdown: "코드 `let x = 1` 와 **굵은 `code`** 끝 *italic `c`*"),
        Case(name: "bold-italic", markdown: "***굵은 기울임 한글 bold italic*** 뒤 *italic* **bold** ~~**굵은 취소**~~"),
        Case(name: "breaks", markdown: "첫 줄  \n둘째 줄\n셋째 **굵게**  \n**굵은 줄** 끝"),
        Case(name: "math-source", markdown: #"수식 \(a+b\) 원문 *기울임 \(c\)* 끝"#),
        Case(name: "math-image", markdown: #"앞 \(x\) 뒤 **굵은 \(x\)**"#, mathImage: true),
        Case(name: "tail-unclosed", markdown: "스트리밍 중인 문장이 **굵은 꼬리로 끝나", streaming: true),
        Case(name: "tail-across-runs", markdown: "가나다 *기울임 꼬리* **굵은꼬리**짧음", streaming: true),
        Case(name: "tail-code", markdown: "코드 `x` 뒤에 이어지는 스트리밍 꼬리 문장", streaming: true),
        Case(name: "small-font-breaks", markdown: "작은 글씨  \n다음 줄 **굵게**  \n끝", smallFont: true),
        Case(name: "dynamic-type", markdown: "배율 **굵게** [링크](https://example.com) 끝", smallFont: true, fontScale: 1.6),
    ]

    @Test(arguments: cases)
    func mergedTextMatchesPerRunText(_ testCase: Case) throws {
        let block = try #require(
            RichMarkdownParser.parse(markdown: testCase.markdown, parsesDollarMath: false).blocks.first
        )
        guard case .paragraph(let runs) = block else {
            Issue.record("문단이어야 한다: \(block)")
            return
        }
        var images: [MathSegment: RenderedMath] = [:]
        if testCase.mathImage {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 12)).image { context in
                UIColor.systemRed.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 18, height: 12))
            }
            for case .math(let segment) in runs.map(\.content) {
                images[segment] = RenderedMath(image: image, descent: 3, ascent: 9)
            }
        }
        let font = testCase.smallFont
            ? RichMarkdownFont(relativeTo: .caption, size: 12)
            : RichMarkdownFont(relativeTo: .body)
        let tail = testCase.streaming
            ? RichMarkdownStreamingTailContext(options: .default, dollarMath: [])
            : nil

        let merged = try render(
            InlineRunsText(runs: runs, images: images, font: font, tail: tail),
            fontScale: testCase.fontScale
        )
        let legacy = try render(
            LegacyInlineRunsText(runs: runs, images: images, font: font, tail: tail),
            fontScale: testCase.fontScale
        )
        #expect(merged.size == legacy.size, "크기가 같아야 한다")
        let differing = zip(merged.pixels, legacy.pixels).filter { $0 != $1 }.count
        #expect(differing == 0, "다른 바이트 \(differing)개")
    }

    // MARK: - 렌더

    private struct Bitmap {
        let size: CGSize
        let pixels: [UInt8]
    }

    private func render(_ content: some View, fontScale: CGFloat) throws -> Bitmap {
        let root = content
            .environment(\.richMarkdownFontScale, RichMarkdownFontScale(body: fontScale, caption: fontScale))
            .frame(width: 320, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.white)
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image {
            controller.view.layer.render(in: $0.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        try #require(drawn)
        return Bitmap(size: size, pixels: pixels)
    }
}

/// 비교 기준: run마다 `Text`를 만들어 `+`로 잇던 이전 `InlineRunsText` 구현(접근성 라벨 제외).
/// `SwiftUIStreamingUpdateBenchmarks`도 같은 프로세스 A/B 비교에 쓴다.
struct LegacyInlineRunsText: View {
    let runs: [InlineRun]
    let images: [MathSegment: RenderedMath]
    let font: RichMarkdownFont
    var tail: RichMarkdownStreamingTailContext? = nil
    @Environment(\.richMarkdownTheme) private var theme
    @Environment(\.richMarkdownFontScale) private var fontScale

    var body: some View {
        if #available(iOS 18.0, *), hasInlineCode {
            combinedText.textRenderer(
                InlineCodeChipTextRenderer(background: theme.inlineCodeBackground, border: theme.inlineCodeBorder)
            )
        } else {
            combinedText.textSelection(.enabled)
        }
    }

    private var displayRuns: [InlineRun] {
        guard let tail, tail.options.hidesUnclosedInlineMarks else { return runs }
        return StreamingTail.hidingUnclosedOpeners(runs, dollarMath: tail.dollarMath.core)
    }

    private var hasInlineCode: Bool {
        displayRuns.contains { if case .code = $0.content { return true } else { return false } }
    }

    private var combinedText: Text {
        let plan = StreamingTail.fadePlan(displayRuns, graphemeCount: tail?.options.tailFadeGraphemeCount ?? 0)
        let head = plan.head.reduce(Text(verbatim: "")) { $0 + text(for: $1) }
        return plan.tail.reduce(head) { partial, piece in
            partial + styled(Text(emphasized(base(piece.text, alpha: piece.alpha), piece.run)), piece.run)
        }
    }

    private func text(for run: InlineRun) -> Text {
        switch run.content {
        case .text(let string):
            return styled(Text(emphasized(base(string), run)), run)
        case .code(let code):
            var attributed = base(code)
            attributed.font = theme.codeFont.resolvedFont(scaledBy: fontScale.factor(for: theme.codeFont.relativeTo))
            attributed.foregroundColor = theme.inlineCodeForeground
            if #available(iOS 18.0, *) {
                return styled(Text(emphasized(attributed, run)), run).customAttribute(InlineCodeChipTextAttribute())
            }
            attributed.backgroundColor = theme.inlineCodeBackground
            return styled(Text(emphasized(attributed, run)), run)
        case .math(let segment):
            if let rendered = images[segment] {
                return Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
            }
            return styled(Text(emphasized(base(segment.source), run)), run)
        case .link(let label, let destination):
            var attributed = base(label)
            attributed.link = destination
            attributed.foregroundColor = theme.linkColor
            attributed.underlineStyle = .single
            return styled(Text(emphasized(attributed, run)), run)
        case .hardBreak:
            return Text(verbatim: "\n")
        case .softBreak:
            return Text(verbatim: " ")
        }
    }

    private func base(_ string: String, alpha: Double = 1) -> AttributedString {
        var attributed = AttributedString(string)
        attributed.foregroundColor = alpha < 1 ? theme.textColor.opacity(alpha) : theme.textColor
        attributed.font = font.resolvedFont(scaledBy: fontScale.factor(for: font.relativeTo))
        return attributed
    }

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
