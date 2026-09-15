import SwiftUI

/// 블록 수식의 가로 정렬. 콘텐츠가 가용 폭보다 좁을 때만 의미가 있고,
/// 넓으면 기존처럼 가로 스크롤한다.
public enum LatexEquationAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// v1 공개 theme. 값 비교로 렌더 요청 key에 포함된다.
///
/// 색과 폰트 모두 **요소 단위**다. 범위(문자 구간) 단위 지정은 제공하지 않는다.
public struct RichMarkdownTheme: Sendable, Equatable {
    // MARK: 색
    public var textColor: Color
    public var linkColor: Color
    public var codeBlockBackground: Color
    public var inlineCodeBackground: Color
    /// 인라인 코드 텍스트 색. 배경만으로는 코드가 눈에 띄지 않아 Notion처럼 강조한다.
    public var inlineCodeForeground: Color
    /// 인라인 코드 칩 테두리 색.
    public var inlineCodeBorder: Color
    public var quoteBar: Color
    public var codeHeaderBackground: Color
    /// 코드 블록 신택스 하이라이팅 색. `RichMarkdownCodeBlockOptions.highlighter`를 주입했을 때만 쓰인다.
    public var syntax: RichMarkdownSyntaxColors

    // MARK: 폰트
    /// 본문 문단, 리스트 마커, 링크, 원문 fallback.
    /// 수식 raster의 기준 크기도 이 값의 크기를 따른다.
    public var bodyFont: RichMarkdownFont
    public var heading1Font: RichMarkdownFont
    public var heading2Font: RichMarkdownFont
    public var heading3Font: RichMarkdownFont
    /// 헤딩 4단계 이하 전부.
    public var heading4Font: RichMarkdownFont
    /// 인라인 코드, 코드 블록 본문, 블록 수식 fallback.
    public var codeFont: RichMarkdownFont
    /// 코드 블록 헤더의 언어 라벨.
    public var codeLabelFont: RichMarkdownFont
    /// 수식 서체.
    public var mathFont: LatexMathFont
    /// 블록 수식 정렬. 기본 leading (콘텐츠가 좁을 때만 의미).
    public var equationAlignment: LatexEquationAlignment

    public init(
        textColor: Color = .primary,
        linkColor: Color = .accessibleLink,
        codeBlockBackground: Color = Color(.secondarySystemBackground),
        inlineCodeBackground: Color = Color(.secondarySystemFill),
        inlineCodeForeground: Color = .inlineCodeAccent,
        inlineCodeBorder: Color = Color(.separator),
        quoteBar: Color = Color(.systemGray3),
        codeHeaderBackground: Color = Color(.tertiarySystemBackground),
        syntax: RichMarkdownSyntaxColors = .default,
        bodyFont: RichMarkdownFont = RichMarkdownFont(relativeTo: .body),
        heading1Font: RichMarkdownFont = RichMarkdownFont(relativeTo: .title1, weight: .bold),
        heading2Font: RichMarkdownFont = RichMarkdownFont(relativeTo: .title2, weight: .bold),
        heading3Font: RichMarkdownFont = RichMarkdownFont(relativeTo: .title3, weight: .semibold),
        heading4Font: RichMarkdownFont = RichMarkdownFont(relativeTo: .headline),
        codeFont: RichMarkdownFont = RichMarkdownFont(design: .monospaced, relativeTo: .body),
        codeLabelFont: RichMarkdownFont = RichMarkdownFont(design: .monospaced, relativeTo: .caption),
        mathFont: LatexMathFont = .latinModern,
        equationAlignment: LatexEquationAlignment = .leading
    ) {
        self.textColor = textColor
        self.linkColor = linkColor
        self.codeBlockBackground = codeBlockBackground
        self.inlineCodeBackground = inlineCodeBackground
        self.inlineCodeForeground = inlineCodeForeground
        self.inlineCodeBorder = inlineCodeBorder
        self.quoteBar = quoteBar
        self.codeHeaderBackground = codeHeaderBackground
        self.syntax = syntax
        self.bodyFont = bodyFont
        self.heading1Font = heading1Font
        self.heading2Font = heading2Font
        self.heading3Font = heading3Font
        self.heading4Font = heading4Font
        self.codeFont = codeFont
        self.codeLabelFont = codeLabelFont
        self.mathFont = mathFont
        self.equationAlignment = equationAlignment
    }

    /// 헤딩 레벨별 폰트. 4단계 이하는 모두 `heading4Font`다.
    public func headingFont(level: Int) -> RichMarkdownFont {
        switch level {
        case 1: return heading1Font
        case 2: return heading2Font
        case 3: return heading3Font
        default: return heading4Font
        }
    }

    public static let `default` = RichMarkdownTheme()
}

/// 코드 블록 신택스 색. 역할별 **요소 단위**이며 테마의 다른 색과 같은 규칙이다.
///
/// 기본값은 light/dark 각각을 담은 동적 `UIColor`다. 코드 블록 배경
/// (`secondarySystemBackground`) 위에서 일곱 역할 모두 본문 대비 기준(4.5:1)을 넘는다.
public struct RichMarkdownSyntaxColors: Sendable, Equatable {
    public var keyword: Color
    public var string: Color
    public var comment: Color
    public var number: Color
    public var type: Color
    public var function: Color
    public var property: Color

    public init(
        keyword: Color = Self.dynamic(light: 0x9A_24_6C, dark: 0xFF_7A_B2),
        string: Color = Self.dynamic(light: 0xAF_30_1D, dark: 0xFC_8F_74),
        comment: Color = Self.dynamic(light: 0x62_70_69, dark: 0x9A_A7_B2),
        number: Color = Self.dynamic(light: 0x76_54_A3, dark: 0xD9_C9_7C),
        type: Color = Self.dynamic(light: 0x17_6A_66, dark: 0x82_D4_C0),
        function: Color = Self.dynamic(light: 0x23_5C_AD, dark: 0x73_BF_FF),
        property: Color = Self.dynamic(light: 0x74_51_9A, dark: 0xC2_A8_FF)
    ) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.type = type
        self.function = function
        self.property = property
    }

    public func color(for kind: RichMarkdownHighlightKind) -> Color {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .function: return function
        case .property: return property
        }
    }

    /// light/dark RGB를 담은 동적 색. 스냅샷이 아니라 trait에 따라 해석된다.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    public static let `default` = RichMarkdownSyntaxColors()
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
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

    /// 기본 인라인 코드 텍스트 색 (Notion 스타일 붉은 강조).
    /// 기본 칩 배경(`secondarySystemFill`을 base 위에 합성한 값) 대비
    /// light #A93226 약 5.5:1, dark #FF7369 약 5.7:1로 본문 기준(4.5:1)을 넘는다.
    static let inlineCodeAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.45, blue: 0.41, alpha: 1)
            : UIColor(red: 0.66, green: 0.20, blue: 0.15, alpha: 1)
    })
}

private struct RichMarkdownThemeKey: EnvironmentKey {
    static let defaultValue = RichMarkdownTheme.default
}

extension EnvironmentValues {
    var richMarkdownTheme: RichMarkdownTheme {
        get { self[RichMarkdownThemeKey.self] }
        set { self[RichMarkdownThemeKey.self] = newValue }
    }
}

public extension View {
    func richMarkdownTheme(_ theme: RichMarkdownTheme) -> some View {
        environment(\.richMarkdownTheme, theme)
    }
}
