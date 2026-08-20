import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

/// 테마 색이 실제로 어느 요소까지 닿는지 검증한다.
///
/// `theme.textColor`는 오래 `.primary` 기본값이었고 SwiftUI 환경 전경색과 값이 같아서,
/// 본문에 색이 닿지 않는 결함이 렌더 결과로는 보이지 않았다. 그래서 기본값과 절대
/// 겹치지 않는 marker 색을 넣고 SwiftUI는 픽셀로, UIKit은 속성으로 판정한다.
@MainActor
@Suite struct ThemeReachTests {

    /// 시스템 색·기본 테마와 겹치지 않는 판정용 색.
    private static let markerRGB: (UInt8, UInt8, UInt8) = (255, 0, 255)
    private static let marker = Color(red: 1, green: 0, blue: 1)

    private static var markerTheme: LatexTheme {
        LatexTheme(textColor: marker)
    }

    // MARK: - SwiftUI

    private func render<V: View>(_ view: V) throws -> UIImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 260, alignment: .leading)
                .background(Color.white)
        )
        renderer.scale = 1
        return try #require(renderer.uiImage, "ImageRenderer가 비트맵을 만들어야 한다")
    }

    private func markerPixelCount(_ image: UIImage, tolerance: Int = 24) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        let (r, g, b) = Self.markerRGB
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[index]) - Int(r)) <= tolerance,
               abs(Int(bytes[index + 1]) - Int(g)) <= tolerance,
               abs(Int(bytes[index + 2]) - Int(b)) <= tolerance {
                count += 1
            }
        }
        return count
    }

    private func containsMarker(_ image: UIImage) -> Bool {
        markerPixelCount(image) > 0
    }

    private func blockView(_ block: ParsedBlock) -> some View {
        LatexBlockView(block: block, images: [:])
            .latexTheme(Self.markerTheme)
    }

    @Test func swiftUIParagraphUsesThemeTextColor() throws {
        let block = ParsedBlock.paragraph([InlineRun(content: .text("본문 글자"))])
        #expect(containsMarker(try render(blockView(block))))
    }

    @Test func swiftUIHeadingUsesThemeTextColor() throws {
        let block = ParsedBlock.heading(level: 1, runs: [InlineRun(content: .text("제목"))])
        #expect(containsMarker(try render(blockView(block))))
    }

    @Test func swiftUIListMarkerUsesThemeTextColor() throws {
        let item: [ParsedBlock] = [.paragraph([InlineRun(content: .text("항목"))])]
        #expect(containsMarker(try render(blockView(.unorderedList(items: [item])))))
        #expect(containsMarker(try render(blockView(.orderedList(start: 1, items: [item])))))
    }

    @Test func swiftUICodeBlockBodyUsesThemeTextColor() throws {
        let block = ParsedBlock.codeBlock(language: "swift", code: "let x = 1")
        #expect(containsMarker(try render(blockView(block))))
    }

    @Test func swiftUIInlineCodeUsesThemeTextColor() throws {
        let block = ParsedBlock.paragraph([InlineRun(content: .code("code"))])
        #expect(containsMarker(try render(blockView(block))))
    }

    @Test func swiftUIRawFallbackUsesThemeTextColor() throws {
        let view = LatexMarkdownView(markdown: "파싱 전 원문").latexTheme(Self.markerTheme)
        #expect(containsMarker(try render(view)))
    }

    @Test func swiftUICopyButtonUsesThemeTextColor() throws {
        let view = CopyButton(text: "x", accessibilityLabel: "복사")
            .latexTheme(Self.markerTheme)
        #expect(containsMarker(try render(view)))
    }

    /// 음성 대조군: marker를 쓰지 않으면 marker 픽셀이 없어야 한다.
    /// 이게 실패하면 위 테스트들이 무의미하다.
    @Test func defaultThemeDoesNotProduceMarkerPixels() throws {
        let block = ParsedBlock.paragraph([InlineRun(content: .text("본문 글자"))])
        let view = LatexBlockView(block: block, images: [:]).latexTheme(.default)
        #expect(!containsMarker(try render(view)))
    }

    // MARK: - SwiftUI 폰트

    private func paragraph(_ text: String, bold: Bool = false) -> ParsedBlock {
        .paragraph([InlineRun(content: .text(text), bold: bold)])
    }

    private func inkCount(theme: LatexTheme, bold: Bool = false) throws -> Int {
        let view = LatexBlockView(block: paragraph("가나다 ABC", bold: bold), images: [:])
            .latexTheme(theme)
        return markerPixelCount(try render(view))
    }

    @Test func swiftUIBodyFontSizeChangesRendering() throws {
        let small = try inkCount(theme: LatexTheme(textColor: Self.marker, bodyFont: LatexFont(relativeTo: .body, size: 17)))
        let large = try inkCount(theme: LatexTheme(textColor: Self.marker, bodyFont: LatexFont(relativeTo: .body, size: 40)))
        #expect(large > small, "bodyFont 크기가 커지면 잉크 픽셀이 늘어야 한다")
    }

    @Test func swiftUICustomFontFamilyChangesRendering() throws {
        let system = try inkCount(theme: LatexTheme(textColor: Self.marker, bodyFont: LatexFont(relativeTo: .body, size: 28)))
        let georgia = try inkCount(theme: LatexTheme(
            textColor: Self.marker,
            bodyFont: LatexFont(design: .custom(name: "Georgia"), relativeTo: .body, size: 28)
        ))
        #expect(system != georgia, "서체를 바꾸면 렌더 결과가 달라져야 한다")
    }

    /// run의 굵게 표시는 `attributed.font`를 명시한 뒤에도 살아 있어야 한다.
    /// `Text.bold()`가 명시 폰트에 밀리면 이 테스트가 잡는다.
    @Test func swiftUIBoldRunRendersHeavier() throws {
        let theme = LatexTheme(textColor: Self.marker, bodyFont: LatexFont(relativeTo: .body, size: 28))
        let regular = try inkCount(theme: theme, bold: false)
        let bold = try inkCount(theme: theme, bold: true)
        #expect(bold > regular, "bold run은 더 많은 잉크 픽셀을 만들어야 한다")
    }

    // MARK: - UIKit

    private func waitForRender(_ view: LatexMarkdownUIView, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while view.model.hasOutstandingWork {
            #expect(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutIfNeeded()
    }

    private func foregroundColors(in view: UIView) -> [UIColor] {
        var colors: [UIColor] = []
        if let label = view as? UILabel, let color = label.textColor {
            colors.append(color)
        }
        if let button = view as? UIButton, let tint = button.tintColor {
            colors.append(tint)
        }
        if let textView = view as? UITextView, let attributed = textView.attributedText {
            attributed.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let color = value as? UIColor { colors.append(color) }
            }
        }
        for subview in view.subviews {
            colors.append(contentsOf: foregroundColors(in: subview))
        }
        return colors
    }

    @Test func uiKitAppliesThemeTextColorToEveryTextElement() async throws {
        let markdown = """
        # 제목

        본문 `코드` 글자

        - 항목

        1. 첫째

        ```swift
        let x = 1
        ```
        """
        let view = LatexMarkdownUIView(markdown: markdown, theme: Self.markerTheme)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        try await waitForRender(view)

        let expected = UIColor(Self.marker)
        let colors = foregroundColors(in: view)
        #expect(!colors.isEmpty, "텍스트 요소가 하나도 없으면 검증이 무의미하다")

        let resolved = expected.resolvedColor(with: view.traitCollection)
        for color in colors {
            let actual = color.resolvedColor(with: view.traitCollection)
            #expect(actual.rgbaValue == resolved.rgbaValue, "모든 텍스트 전경색이 theme.textColor여야 한다")
        }
    }
}
