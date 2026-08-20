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

    private let cache = NSCache<KeyBox, Entry>()

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


    package func cachedImage(for key: MathRenderKey) -> RenderedMath? {
        cache.object(forKey: KeyBox(key: key))?.value
    }

    package func removeAll() {
        cache.removeAllObjects()
    }

    /// 렌더 실패(오류·preflight 초과)는 nil. 호출자는 해당 노드만 원문 source로 유지한다.
    package func render(key: MathRenderKey) -> RenderedMath? {
        if let cached = cache.object(forKey: KeyBox(key: key)) {
            return cached.value
        }
        // 수식 source byte 상한을 asImage() 호출 전에 검사한다 (§6 입력 보호).
        guard key.latex.utf8.count <= InputLimits.maxMathSourceUTF8Bytes else { return nil }

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

        let rendered = RenderedMath(image: image, descent: layout.descent, ascent: layout.ascent)
        let pixelCost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        cache.setObject(Entry(value: rendered), forKey: KeyBox(key: key), cost: pixelCost)
        return rendered
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
