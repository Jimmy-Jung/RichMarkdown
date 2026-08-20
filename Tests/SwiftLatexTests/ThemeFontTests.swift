import Foundation
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

/// 요소 단위 폰트 지정이 UIKit 렌더러에 실제로 닿는지 검증한다.
/// SwiftUI 쪽은 `Font`를 들여다볼 수 없어 `ThemeReachTests`에서 픽셀로 판정한다.
@MainActor
@Suite struct ThemeFontTests {

    private func makeView(_ markdown: String, theme: LatexTheme) async throws -> LatexMarkdownUIView {
        let view = LatexMarkdownUIView(markdown: markdown, theme: theme)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 800)
        let deadline = Date().addingTimeInterval(10)
        while view.model.hasOutstandingWork {
            #expect(Date() < deadline, "idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        view.layoutIfNeeded()
        return view
    }

    private func textViews(in view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let textView = view as? UITextView { found.append(textView) }
        for subview in view.subviews { found.append(contentsOf: textViews(in: subview)) }
        return found
    }

    private func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found.append(contentsOf: labels(in: subview)) }
        return found
    }

    /// 첫 글자에 실린 폰트. 문단이 하나뿐인 입력에서만 쓴다.
    private func firstFont(in view: UIView) -> UIFont? {
        for textView in textViews(in: view) {
            guard let attributed = textView.attributedText, attributed.length > 0 else { continue }
            if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                return font
            }
        }
        return nil
    }

    private func attachments(in view: UIView) -> [NSTextAttachment] {
        var found: [NSTextAttachment] = []
        for textView in textViews(in: view) {
            guard let attributed = textView.attributedText else { continue }
            attributed.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let attachment = value as? NSTextAttachment { found.append(attachment) }
            }
        }
        return found
    }

    /// TextKit이 레이아웃 때 실제로 묻는 값. `attachment.bounds` 프로퍼티는
    /// UITextView를 거치면 `.zero`로 읽히므로 그쪽을 봐선 안 된다.
    private func askedBounds(_ attachment: NSTextAttachment) -> CGRect {
        attachment.attachmentBounds(
            for: nil,
            proposedLineFragment: .zero,
            glyphPosition: .zero,
            characterIndex: 0
        )
    }

    // MARK: - LatexFont 해석 단위 검증

    @Test func customFontFamilyResolves() {
        let font = LatexFont(design: .custom(name: "Georgia"), relativeTo: .body, size: 20)
        let resolved = font.resolvedUIFont(compatibleWith: nil)
        #expect(resolved.familyName == "Georgia")
        #expect(resolved.pointSize == 20)
    }

    @Test func unknownCustomFontFallsBackToSystem() {
        let font = LatexFont(design: .custom(name: "존재하지않는서체XYZ"), relativeTo: .body, size: 20)
        let resolved = font.resolvedUIFont(compatibleWith: nil)
        #expect(resolved.familyName == UIFont.systemFont(ofSize: 20).familyName)
        #expect(resolved.pointSize == 20)
    }

    @Test func weightAppliesToStandardDesign() {
        let regular = LatexFont(relativeTo: .body).resolvedUIFont(compatibleWith: nil)
        let heavy = LatexFont(relativeTo: .body, weight: .heavy).resolvedUIFont(compatibleWith: nil)
        #expect(!regular.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(heavy.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(heavy.pointSize == regular.pointSize, "굵기 변경이 크기를 바꾸면 안 된다")
    }

    @Test func monospacedDesignResolvesToFixedWidthFont() {
        let font = LatexFont(design: .monospaced, relativeTo: .body).resolvedUIFont(compatibleWith: nil)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    // MARK: - UIKit 렌더러 반영

    @Test func bodyFontSizeAppliesToParagraph() async throws {
        let theme = LatexTheme(bodyFont: LatexFont(relativeTo: .body, size: 40))
        let view = try await makeView("본문 글자", theme: theme)
        #expect(try #require(firstFont(in: view)).pointSize == 40)
    }

    @Test func headingFontOverrideApplies() async throws {
        let theme = LatexTheme(heading1Font: LatexFont(relativeTo: .title1, size: 50, weight: .black))
        let view = try await makeView("# 제목", theme: theme)
        let font = try #require(firstFont(in: view))
        #expect(font.pointSize == 50)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func codeFontOverrideAppliesToInlineAndBlock() async throws {
        let theme = LatexTheme(codeFont: LatexFont(design: .monospaced, relativeTo: .body, size: 30))
        let view = try await makeView("본문 `코드`\n\n```swift\nlet x = 1\n```", theme: theme)

        var codeFontSizes: Set<CGFloat> = []
        for textView in textViews(in: view) {
            guard let attributed = textView.attributedText else { continue }
            attributed.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                if let font = value as? UIFont,
                   font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
                    codeFontSizes.insert(font.pointSize)
                }
            }
        }
        #expect(codeFontSizes == [30], "인라인 코드와 코드 블록 본문이 모두 codeFont를 써야 한다")
    }

    @Test func codeLabelFontOverrideApplies() async throws {
        let theme = LatexTheme(codeLabelFont: LatexFont(design: .monospaced, relativeTo: .caption, size: 28))
        let view = try await makeView("```swift\nlet x = 1\n```", theme: theme)
        let label = try #require(labels(in: view).first)
        #expect(label.text == "swift")
        #expect(try #require(label.font).pointSize == 28)
    }

    @Test func listMarkerFollowsBodyFont() async throws {
        let theme = LatexTheme(bodyFont: LatexFont(relativeTo: .body, size: 33))
        let view = try await makeView("1. 첫째\n2. 둘째", theme: theme)
        let markers = labels(in: view)
        #expect(!markers.isEmpty)
        for marker in markers {
            #expect(try #require(marker.font).pointSize == 33)
        }
    }

    /// 수식 raster 기준 크기는 `bodyFont` 크기를 따른다.
    @Test func mathRasterSizeFollowsBodyFont() async throws {
        let small = try await makeView(
            #"인라인 \(a+b\) 수식"#,
            theme: LatexTheme(bodyFont: LatexFont(relativeTo: .body, size: 17))
        )
        let large = try await makeView(
            #"인라인 \(a+b\) 수식"#,
            theme: LatexTheme(bodyFont: LatexFont(relativeTo: .body, size: 40))
        )

        let smallHeight = askedBounds(try #require(attachments(in: small).first)).height
        let largeHeight = askedBounds(try #require(attachments(in: large).first)).height
        #expect(largeHeight > smallHeight, "bodyFont가 커지면 수식 raster도 커져야 한다")
    }

    /// 인라인 수식의 baseline 보정. `attachment.bounds`에 넣은 값은 UITextView를 거치며
    /// 사라지므로 TextKit이 묻는 메서드가 `-descent`를 답해야 한다.
    @Test func inlineMathReportsBaselineCorrectedBounds() async throws {
        let view = try await makeView(#"분수 \(\frac{a}{b}\) 포함"#, theme: .default)
        let attachment = try #require(attachments(in: view).first)
        let image = try #require(attachment.image)
        let bounds = askedBounds(attachment)

        #expect(bounds.size == image.size)
        #expect(bounds.origin.y < 0, "descent만큼 baseline 아래로 내려야 한다")
        #expect(attachment.bounds == .zero, "bounds 프로퍼티는 신뢰할 수 없다는 사실을 고정한다")
    }

    /// 서체를 바꾸면 raster가 새로 만들어져야 한다 (캐시 키에 서체가 들어간다).
    @Test func mathFontOverrideReachesRenderer() async throws {
        let latinModern = try await makeView(
            #"\(x+y\)"#,
            theme: LatexTheme(mathFont: .latinModern)
        )
        let xits = try await makeView(
            #"\(x+y\)"#,
            theme: LatexTheme(mathFont: .xits)
        )
        let latinAttachment = try #require(attachments(in: latinModern).first)
        let xitsAttachment = try #require(attachments(in: xits).first)
        let a = try #require(latinAttachment.image?.pngData())
        let b = try #require(xitsAttachment.image?.pngData())
        #expect(a != b, "서체가 다르면 raster가 달라져야 한다")
    }
}
