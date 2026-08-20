import SwiftUI

/// v1 공개 theme. 값 비교로 렌더 요청 key에 포함된다.
///
/// 색과 폰트 모두 **요소 단위**다. 범위(문자 구간) 단위 지정은 제공하지 않는다.
public struct LatexTheme: Sendable, Equatable {
    // MARK: 색
    public var textColor: Color
    public var linkColor: Color
    public var codeBlockBackground: Color
    public var inlineCodeBackground: Color
    public var quoteBar: Color
    public var codeHeaderBackground: Color

    // MARK: 폰트
    /// 본문 문단, 리스트 마커, 링크, 원문 fallback.
    /// 수식 raster의 기준 크기도 이 값의 크기를 따른다.
    public var bodyFont: LatexFont
    public var heading1Font: LatexFont
    public var heading2Font: LatexFont
    public var heading3Font: LatexFont
    /// 헤딩 4단계 이하 전부.
    public var heading4Font: LatexFont
    /// 인라인 코드, 코드 블록 본문, 블록 수식 fallback.
    public var codeFont: LatexFont
    /// 코드 블록 헤더의 언어 라벨.
    public var codeLabelFont: LatexFont
    /// 수식 서체.
    public var mathFont: LatexMathFont

    public init(
        textColor: Color = .primary,
        linkColor: Color = .accessibleLink,
        codeBlockBackground: Color = Color(.secondarySystemBackground),
        inlineCodeBackground: Color = Color(.secondarySystemFill),
        quoteBar: Color = Color(.systemGray3),
        codeHeaderBackground: Color = Color(.tertiarySystemBackground),
        bodyFont: LatexFont = LatexFont(relativeTo: .body),
        heading1Font: LatexFont = LatexFont(relativeTo: .title1, weight: .bold),
        heading2Font: LatexFont = LatexFont(relativeTo: .title2, weight: .bold),
        heading3Font: LatexFont = LatexFont(relativeTo: .title3, weight: .semibold),
        heading4Font: LatexFont = LatexFont(relativeTo: .headline),
        codeFont: LatexFont = LatexFont(design: .monospaced, relativeTo: .body),
        codeLabelFont: LatexFont = LatexFont(design: .monospaced, relativeTo: .caption),
        mathFont: LatexMathFont = .latinModern
    ) {
        self.textColor = textColor
        self.linkColor = linkColor
        self.codeBlockBackground = codeBlockBackground
        self.inlineCodeBackground = inlineCodeBackground
        self.quoteBar = quoteBar
        self.codeHeaderBackground = codeHeaderBackground
        self.bodyFont = bodyFont
        self.heading1Font = heading1Font
        self.heading2Font = heading2Font
        self.heading3Font = heading3Font
        self.heading4Font = heading4Font
        self.codeFont = codeFont
        self.codeLabelFont = codeLabelFont
        self.mathFont = mathFont
    }

    /// 헤딩 레벨별 폰트. 4단계 이하는 모두 `heading4Font`다.
    public func headingFont(level: Int) -> LatexFont {
        switch level {
        case 1: return heading1Font
        case 2: return heading2Font
        case 3: return heading3Font
        default: return heading4Font
        }
    }

    public static let `default` = LatexTheme()
}

public extension Color {
    /// 기본 링크 색. 시스템 블루(#007AFF)는 흰 배경에서 약 3.6:1로 본문 텍스트
    /// 대비 기준(4.5:1)에 미달해 접근성 audit이 실패한다. light/dark 각각
    /// 기준을 넘는 값을 쓴다 (light 약 7.5:1, dark 약 8.9:1).
    static let accessibleLink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.75, blue: 1.00, alpha: 1)
            : UIColor(red: 0.04, green: 0.31, blue: 0.72, alpha: 1)
    })
}

private struct LatexThemeKey: EnvironmentKey {
    static let defaultValue = LatexTheme.default
}

extension EnvironmentValues {
    var latexTheme: LatexTheme {
        get { self[LatexThemeKey.self] }
        set { self[LatexThemeKey.self] = newValue }
    }
}

public extension View {
    func latexTheme(_ theme: LatexTheme) -> some View {
        environment(\.latexTheme, theme)
    }
}
