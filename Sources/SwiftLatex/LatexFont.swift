import CoreText
import SwiftUI
import UIKit

/// Dynamic Type 스케일 기준 스타일.
///
/// UIKit `UIFont.TextStyle`과 SwiftUI `Font.TextStyle` 양쪽으로 매핑된다.
/// 두 렌더러가 같은 값에서 폰트를 만들기 위한 중간 표현이다.
public enum LatexTextStyle: String, Sendable, Hashable, CaseIterable {
    case body
    case headline
    case title1
    case title2
    case title3
    case caption

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .body: return .body
        case .headline: return .headline
        case .title1: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .caption: return .caption1
        }
    }

    var swiftUITextStyle: Font.TextStyle {
        switch self {
        case .body: return .body
        case .headline: return .headline
        // UIKit의 title1/title2/title3는 각각 28/22/20pt다. SwiftUI의
        // largeTitle(34pt)이 아니라 title/title2/title3와 짝지어야 두
        // renderer의 기본 Dynamic Type 계층이 같다.
        case .title1: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .caption: return .caption
        }
    }

    /// 기본 Dynamic Type 크기(Large)에서의 point size.
    /// `LatexFont.size`가 nil일 때의 기준값이고, 수식 raster의 기준 크기이기도 하다.
    var defaultSize: CGFloat {
        switch self {
        case .body: return 17
        case .headline: return 17
        case .title1: return 28
        case .title2: return 22
        case .title3: return 20
        case .caption: return 12
        }
    }
}

/// 굵기. UIKit `UIFont.Weight`와 SwiftUI `Font.Weight` 양쪽으로 매핑된다.
public enum LatexFontWeight: String, Sendable, Hashable, CaseIterable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

/// 요소별 폰트 지정.
///
/// `Sendable` 값 타입이라 `LatexTheme`에 담고 수식 렌더 요청 key에도 넣을 수 있다.
/// SwiftUI `Font`나 UIKit `UIFont`를 직접 담지 않는 이유는 두 타입 사이에 손실 없는
/// 변환이 없고 `UIFont`가 `Sendable`이 아니기 때문이다.
///
/// ```swift
/// LatexFont(design: .custom(name: "Georgia"), relativeTo: .body)
/// LatexFont(relativeTo: .title1, size: 34, weight: .heavy)
/// ```
public struct LatexFont: Sendable, Hashable {
    public enum Design: Sendable, Hashable {
        /// 시스템 서체.
        case standard
        /// 시스템 고정폭 서체.
        case monospaced
        /// 앱이 등록한 서체 이름. 찾지 못하면 시스템 서체로 물러난다.
        case custom(name: String)
    }

    public var design: Design
    /// Dynamic Type 스케일 기준.
    public var relativeTo: LatexTextStyle
    /// nil 또는 0 이하/비유한 값이면 `relativeTo`의 기본 크기를 쓴다.
    public var size: CGFloat?
    /// nil이면 스타일의 기본 굵기를 유지한다. `.custom` 서체에서는 무시될 수 있다.
    public var weight: LatexFontWeight?

    public init(
        design: Design = .standard,
        relativeTo: LatexTextStyle = .body,
        size: CGFloat? = nil,
        weight: LatexFontWeight? = nil
    ) {
        self.design = design
        self.relativeTo = relativeTo
        self.size = size
        self.weight = weight
    }

    /// 렌더 동작과 동일하게 유효한 명시 크기만 값 정체성에 포함한다.
    /// 특히 IEEE `NaN`은 자기 자신과도 같지 않으므로 synthesized `Hashable`을 쓰면
    /// `LatexFont`가 `Set`/cache key에서 Hashable 계약을 깨게 된다.
    public static func == (lhs: LatexFont, rhs: LatexFont) -> Bool {
        lhs.design == rhs.design
            && lhs.relativeTo == rhs.relativeTo
            && lhs.explicitSize == rhs.explicitSize
            && lhs.weight == rhs.weight
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(design)
        hasher.combine(relativeTo)
        hasher.combine(explicitSize)
        hasher.combine(weight)
    }

    /// 유효한 명시 point size만 반환한다. 공개 `LatexTheme` 입력은 앱 설정이나 원격
    /// 테마에서 올 수 있으므로, 비정상 값이 UIKit/SwiftUI font 생성자까지 닿지 않게 한다.
    private var explicitSize: CGFloat? {
        guard let size, size.isFinite, size > 0 else { return nil }
        return size
    }

    /// 기본 Dynamic Type 크기에서의 안전한 point size.
    var unscaledSize: CGFloat { explicitSize ?? relativeTo.defaultSize }

    /// 수식 raster처럼 point size가 필요한 경로의 Dynamic Type 반영값.
    ///
    /// 텍스트의 custom font는 SwiftUI의 `relativeTo:`가 직접 스케일하지만,
    /// SwiftMath에는 point size만 전달하므로 모든 design에 이 값을 쓴다.
    func scaledPointSize(using scale: LatexFontScale) -> CGFloat {
        unscaledSize * scale.factor(for: relativeTo)
    }

    // MARK: - UIKit

    /// 뷰의 trait으로 해석한 `UIFont`.
    ///
    /// trait을 넘기지 않으면 앱 전역(앰비언트) 설정으로 해석되므로,
    /// 뷰 안에서는 반드시 그 뷰의 `traitCollection`을 넘긴다.
    func resolvedUIFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: relativeTo.uiTextStyle)
        let base: UIFont

        switch design {
        case .standard where explicitSize == nil:
            // Apple의 스타일별 metric을 그대로 쓴다 (크기를 재구성하지 않는다).
            base = .preferredFont(forTextStyle: relativeTo.uiTextStyle, compatibleWith: traits)
        case .standard:
            base = metrics.scaledFont(for: .systemFont(ofSize: unscaledSize), compatibleWith: traits)
        case .monospaced:
            base = metrics.scaledFont(
                for: .monospacedSystemFont(ofSize: unscaledSize, weight: weight?.uiWeight ?? .regular),
                compatibleWith: traits
            )
        case .custom(let name):
            let raw = UIFont(name: name, size: unscaledSize) ?? .systemFont(ofSize: unscaledSize)
            base = metrics.scaledFont(for: raw, compatibleWith: traits)
        }

        guard let weight else { return base }
        if case .monospaced = design { return base }  // 이미 반영했다.
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.uiWeight.rawValue]
        ])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    // MARK: - SwiftUI

    /// Dynamic Type 배율을 별도로 주입하지 않는 기존 호출 경로의 기본 해석값.
    var resolvedFont: Font { resolvedFont(scaledBy: 1) }

    /// SwiftUI 환경에서 Dynamic Type 배율까지 반영한 `Font`.
    ///
    /// `Font.system(size:)`에는 `relativeTo:`가 없다. 따라서 명시 크기의
    /// system/monospaced font는 `LatexFontScale`을 통해 이미 계산된 size를
    /// 전달한다. custom font는 SwiftUI가 제공하는 `relativeTo:` 경로를 유지한다.
    func resolvedFont(scaledBy scale: CGFloat = 1) -> Font {
        let validScale = scale.isFinite && scale > 0 ? scale : 1
        let resolvedSize = unscaledSize * validScale
        var font: Font
        switch design {
        case .standard where explicitSize == nil:
            font = .system(relativeTo.swiftUITextStyle)
        case .standard:
            font = .system(size: resolvedSize)
        case .monospaced where explicitSize == nil:
            font = .system(relativeTo.swiftUITextStyle, design: .monospaced)
        case .monospaced:
            font = .system(size: resolvedSize, design: .monospaced)
        case .custom(let name):
            font = .custom(name, size: unscaledSize, relativeTo: relativeTo.swiftUITextStyle)
        }
        if let weight {
            font = font.weight(weight.swiftUIWeight)
        }
        return font
    }
}

/// SwiftUI가 root view에서 주입하는 Dynamic Type 배율.
///
/// `@ScaledMetric(relativeTo:)`의 기준 style은 컴파일 시점 상수여야 하므로, 실제
/// 환경값은 `LatexMarkdownView`가 style별로 측정해 이 값으로 전달한다. 공개 theme
/// API에 새 설정을 추가하지 않기 위해 module 내부에만 둔다.
struct LatexFontScale: Sendable, Hashable {
    var body: CGFloat = 1
    var headline: CGFloat = 1
    var title: CGFloat = 1
    var title2: CGFloat = 1
    var title3: CGFloat = 1
    var caption: CGFloat = 1

    func factor(for style: LatexTextStyle) -> CGFloat {
        let factor: CGFloat
        switch style {
        case .body: factor = body
        case .headline: factor = headline
        case .title1: factor = title
        case .title2: factor = title2
        case .title3: factor = title3
        case .caption: factor = caption
        }
        return factor.isFinite && factor > 0 ? factor : 1
    }
}

private struct LatexFontScaleKey: EnvironmentKey {
    static let defaultValue = LatexFontScale()
}

extension EnvironmentValues {
    var latexFontScale: LatexFontScale {
        get { self[LatexFontScaleKey.self] }
        set { self[LatexFontScaleKey.self] = newValue }
    }
}

private struct LatexFontModifier: ViewModifier {
    let font: LatexFont
    @Environment(\.latexFontScale) private var scale

    func body(content: Content) -> some View {
        content.font(font.resolvedFont(scaledBy: scale.factor(for: font.relativeTo)))
    }
}

extension View {
    /// 명시 point size도 root의 `LatexFontScale`에 따라 Dynamic Type으로 확대한다.
    func latexFont(_ font: LatexFont) -> some View {
        modifier(LatexFontModifier(font: font))
    }
}

extension UIFont {
    /// 숫자 폭을 고정한 변형. 순서 리스트 마커 정렬에 쓴다.
    /// 서체가 이 feature를 지원하지 않으면 원래 폰트를 그대로 돌려준다.
    var monospacedDigitVariant: UIFont {
        let feature: [UIFontDescriptor.FeatureKey: Int] = [
            .type: Int(kNumberSpacingType),
            .selector: Int(kMonospacedNumbersSelector),
        ]
        let descriptor = fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// 수식 서체. SwiftMath가 번들한 서체 목록이다.
///
/// 값은 raster cache key에 들어가므로, 바꾸면 해당 서체의 이미지가 새로 만들어진다.
public enum LatexMathFont: String, Sendable, Hashable, CaseIterable {
    case latinModern
    case kpMathLight
    case kpMathSans
    case xits
    case termes
    case asana
    case euler
    case fira
    case notoSans
    case libertinus
    case garamond
    case leteSans
}
