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
        case .title1: return .largeTitle
        case .title2: return .title
        case .title3: return .title2
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
    /// nil이면 `relativeTo`의 기본 크기를 쓴다.
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

    /// 기본 Dynamic Type 크기에서의 point size.
    var unscaledSize: CGFloat { size ?? relativeTo.defaultSize }

    // MARK: - UIKit

    /// 뷰의 trait으로 해석한 `UIFont`.
    ///
    /// trait을 넘기지 않으면 앱 전역(앰비언트) 설정으로 해석되므로,
    /// 뷰 안에서는 반드시 그 뷰의 `traitCollection`을 넘긴다.
    func resolvedUIFont(compatibleWith traits: UITraitCollection?) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: relativeTo.uiTextStyle)
        let base: UIFont

        switch design {
        case .standard where size == nil:
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

    var resolvedFont: Font {
        var font: Font
        switch design {
        case .standard where size == nil:
            font = .system(relativeTo.swiftUITextStyle)
        case .standard:
            font = .system(size: unscaledSize)
        case .monospaced where size == nil:
            font = .system(relativeTo.swiftUITextStyle, design: .monospaced)
        case .monospaced:
            font = .system(size: unscaledSize, design: .monospaced)
        case .custom(let name):
            font = .custom(name, size: unscaledSize, relativeTo: relativeTo.swiftUITextStyle)
        }
        if let weight {
            font = font.weight(weight.swiftUIWeight)
        }
        return font
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
