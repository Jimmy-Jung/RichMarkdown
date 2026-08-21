import UIKit
import SwiftMath
import SwiftLatexCore

/// 수식 raster 요청 key (DEVELOPMENT.md §6 cache key):
/// LaTeX source, 수식 서체+point size, resolved RGBA, inline/display mode, display scale.
package struct MathRenderKey: Hashable, Sendable {
    package let latex: String
    package let mathFont: LatexMathFont
    package let pointSize: CGFloat
    package let colorRGBA: UInt32
    package let isDisplay: Bool
    package let displayScale: CGFloat

    package init(
        latex: String,
        mathFont: LatexMathFont = .latinModern,
        pointSize: CGFloat,
        colorRGBA: UInt32,
        isDisplay: Bool,
        displayScale: CGFloat
    ) {
        self.latex = latex
        self.mathFont = mathFont
        self.pointSize = pointSize
        self.colorRGBA = colorRGBA
        self.isDisplay = isDisplay
        self.displayScale = displayScale
    }
}

/// actor 밖으로는 immutable 결과만 반환한다.
package struct RenderedMath: Sendable {
    package let image: UIImage
    package let descent: CGFloat
    package let ascent: CGFloat
}

/// SwiftMath 1.7.3은 allocation 전에 실제 layout dimension을 알려주는 public API를
/// 제공하지 않는다. 이 값들은 그 공백을 완전히 증명하는 보안 경계가 아니라, font/scale과
/// source 길이를 함께 제한해 비정상 요청을 `asImage()` 전에 막는 보수적 작업 상한이다.
private enum RasterInputLimits {
    static let minimumPointSize: CGFloat = 1
    static let maximumPointSize: CGFloat = 256
    static let maximumDisplayScale: CGFloat = 4
    static let maximumEstimatedPixelEdge: CGFloat = 8_192
    static let maximumEstimatedPixelCount: CGFloat = 4_194_304

    static func allows(_ key: MathRenderKey, sourceRendererScale: CGFloat) -> Bool {
        guard key.pointSize.isFinite,
              key.pointSize >= minimumPointSize,
              key.pointSize <= maximumPointSize,
              key.displayScale.isFinite,
              key.displayScale >= 1,
              key.displayScale <= maximumDisplayScale,
              key.latex.utf8.count <= InputLimits.maxMathSourceUTF8Bytes else {
            return false
        }

        // `MathImage`는 현재 main renderer의 scale로 먼저 bitmap을 만든다. target과
        // source 중 큰 쪽으로 잡아 source bitmap과 scale 변환 bitmap 모두를 고려한다.
        let pixelsPerEm = key.pointSize * max(key.displayScale, sourceRendererScale)
        let sourceUnits = CGFloat(key.latex.utf8.count)
        return sourceUnits * pixelsPerEm <= maximumEstimatedPixelEdge
            && sourceUnits * pixelsPerEm * pixelsPerEm <= maximumEstimatedPixelCount
    }
}

/// SwiftMath raster를 담당하는 actor. MainActor에서 CPU raster를 실행하지 않는다.
package actor MathRenderService {
    package static let shared = MathRenderService()

    // cache reference box는 actor 내부 전용 final class + let 필드만 사용한다.
    private final class Entry {
        let value: RenderedMath
        init(value: RenderedMath) { self.value = value }
    }

    private final class KeyBox: NSObject {
        let key: MathRenderKey
        init(key: MathRenderKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyBox)?.key == key
        }
    }

    /// `NSCache`는 문서상 thread-safe하지만 `Sendable`로 표시되어 있지 않다.
    /// notification 클로저가 안전하게 캡처하도록 검사 면제 박스로 감싼다.
    /// 참조는 weak다 — 원래 `[weak cache]` 캡처와 같은 수명 규칙을 유지한다.
    private struct CacheRef: @unchecked Sendable {
        weak var cache: NSCache<KeyBox, Entry>?
    }

    /// `NSCache`는 문서상 thread-safe다. `cachedImage`를 actor 밖(MainActor의
    /// 동기 fast path, worker의 일괄 게시 판단)에서 hop 없이 읽기 위해 면제한다.
    private nonisolated(unsafe) let cache = NSCache<KeyBox, Entry>()

    /// `MathImage.asImage()`가 사용하는 기본 renderer scale을 한 번만 실측한다.
    /// SwiftMath 1.7.3은 renderer format을 받지 않으므로, scale 불일치 요청의
    /// preflight에는 이 source bitmap scale도 포함해야 한다.
    private static let sourceRendererScale: CGFloat = {
        let probe = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        return probe.scale.isFinite && probe.scale > 0 ? probe.scale : 1
    }()

    package init() {
        // ponytail: cache 상한은 P0 측정 전 잠정값. cost는 이미지 pixel byte.
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        // `self`를 캡처하면 nonisolated init에서 isolation 검사에 걸린다.
        // 캐시만 Sendable 박스로 감싸 캡처한다.
        let cacheRef = CacheRef(cache: cache)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            cacheRef.cache?.removeAllObjects()
        }
    }


    package nonisolated func cachedImage(for key: MathRenderKey) -> RenderedMath? {
        cache.object(forKey: KeyBox(key: key))?.value
    }

    /// 벡터 경로(`MTMathUILabel`)가 raster와 같은 작업 상한을 공유하기 위한 통로다.
    ///
    /// `MTMathUILabel.intrinsicContentSize`는 main thread에서 동기 typeset하므로,
    /// bitmap을 만들지 않아도 병리적 입력에서는 main을 오래 잡는다. raster와 상한을
    /// 나누지 않고 같은 판정을 쓴다.
    package static func preflightAllows(_ key: MathRenderKey) -> Bool {
        RasterInputLimits.allows(key, sourceRendererScale: sourceRendererScale)
    }

    package func removeAll() {
        cache.removeAllObjects()
    }

    /// 렌더 실패(오류·preflight 초과)는 nil. 호출자는 해당 노드만 원문 source로 유지한다.
    package func render(key: MathRenderKey) -> RenderedMath? {
        guard RasterInputLimits.allows(key, sourceRendererScale: Self.sourceRendererScale) else {
            return nil
        }
        if let cached = cache.object(forKey: KeyBox(key: key)) {
            return cached.value
        }

        let signpostState = SwiftLatexSignposts.raster.beginInterval("raster")
        defer { SwiftLatexSignposts.raster.endInterval("raster", signpostState) }

        var mathImage = MathImage(
            latex: key.latex,
            fontSize: key.pointSize,
            textColor: UIColor(rgba: key.colorRGBA),
            labelMode: key.isDisplay ? .display : .text,
            textAlignment: .left
        )
        mathImage.font = key.mathFont.swiftMathFont
        let (error, image, layout) = mathImage.asImage()
        guard error == nil, let image, let layout else { return nil }

        guard let scaledImage = image.withDisplayScale(key.displayScale),
              let pixelCost = scaledImage.pixelByteCost,
              pixelCost <= Int(RasterInputLimits.maximumEstimatedPixelCount * 4) else {
            return nil
        }

        let rendered = RenderedMath(image: scaledImage, descent: layout.descent, ascent: layout.ascent)
        cache.setObject(Entry(value: rendered), forKey: KeyBox(key: key), cost: pixelCost)
        return rendered
    }
}

/// 블록 수식의 벡터 뷰 팩토리.
///
/// `MTMathUILabel`은 SwiftMath의 공개 뷰로, 내부에서 동기 typeset하고 CoreText로 직접
/// 드로잉한다. 이미지 중간 단계가 없어 크기가 생성 시점에 확정되고, 원문 → 이미지 교체와
/// 그에 따른 셀 리사이즈가 사라진다.
///
/// 반환 타입을 `UIView`로 두어 SwiftMath 타입이 뷰 계층으로 새지 않게 한다
/// (DEVELOPMENT.md §5: SwiftMath 호출은 이 파일에 가둬 교체 비용을 한 파일로 유지한다).
@MainActor
package enum BlockMathVectorView {
    /// 실패(preflight 초과·latex parse 오류)는 nil이다. 호출자는 원문 source를 표시한다.
    ///
    /// `MTMathUILabel`은 UIView다 — actor/worker에서 만들지 말 것. 동기 typeset 비용의
    /// 상한은 raster와 같은 `MathRenderService.preflightAllows`가 잡는다.
    package static func make(key: MathRenderKey, textColor: UIColor) -> UIView? {
        guard MathRenderService.preflightAllows(key) else { return nil }

        let label = MTMathUILabel()
        // 오류는 호출자의 원문 fallback으로 표시한다. `latex` 대입이 내부 errorLabel의
        // 표시 여부를 이 값으로 정하므로 대입보다 먼저 꺼야 한다.
        label.displayErrorInline = false
        // raster 경로(`MathImage`)와 같은 `MTFontV2`를 쓴다. `MTFontManager`의
        // `font(withName:size:)`는 legacy `MTFont(fontWithName:)`로 .otf와 math table
        // .plist를 직접 읽고, size가 캐시된 값과 다르면 매번 math table을 재구성한다.
        // 두 경로가 같은 폰트 구현을 써야 인라인(raster)과 블록(vector)의 글리프 메트릭이
        // 어긋나지 않는다.
        label.font = key.mathFont.swiftMathFont.mtfont(size: key.pointSize)
        // `fontSize`는 내부 세로 정렬(`_layoutSubviews`)이 쓰는 별도 저장 값이다.
        // 기본값 20이 남으면 raster와 정렬 기준이 갈린다.
        label.fontSize = key.pointSize
        label.labelMode = key.isDisplay ? .display : .text
        label.textColor = textColor
        label.latex = key.latex
        guard label.error == nil else { return nil }
        return label
    }
}

private extension UIImage {
    /// SwiftMath 1.7.3의 `MathImage`는 renderer scale을 지정받지 않는다. 같은 scale이면
    /// 원본을 그대로 쓰고, 외부 display/trait에서 달라질 때만 target scale bitmap을 만든다.
    func withDisplayScale(_ scale: CGFloat) -> UIImage? {
        guard scale.isFinite, scale > 0 else { return nil }
        guard self.scale != scale else { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    var pixelByteCost: Int? {
        guard let cgImage else { return nil }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? nil : cost
    }
}

extension LatexMathFont {
    /// SwiftMath 번들 서체 매핑.
    /// SwiftMath 타입을 공개 API로 새지 않게 변환을 여기 한 곳에 둔다.
    var swiftMathFont: MathFont {
        switch self {
        case .latinModern: return .latinModernFont
        case .kpMathLight: return .kpMathLightFont
        case .kpMathSans: return .kpMathSansFont
        case .xits: return .xitsFont
        case .termes: return .termesFont
        case .asana: return .asanaFont
        case .euler: return .eulerFont
        case .fira: return .firaFont
        case .notoSans: return .notoSansFont
        case .libertinus: return .libertinusFont
        case .garamond: return .garamondFont
        case .leteSans: return .leteSansFont
        }
    }
}

extension UIColor {
    convenience init(rgba: UInt32) {
        self.init(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    var rgbaValue: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return (clamp(r) << 24) | (clamp(g) << 16) | (clamp(b) << 8) | clamp(a)
    }
}
