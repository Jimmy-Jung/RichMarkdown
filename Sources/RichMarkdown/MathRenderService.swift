import UIKit
import CoreText
import RaTeX
import RichMarkdownCore

/// 수식 raster 요청 key (DEVELOPMENT.md §6 cache key):
/// LaTeX source, point size, resolved RGBA, inline/display mode, display scale.
package struct MathRenderKey: Hashable, Sendable {
    package let latex: String
    package let pointSize: CGFloat
    package let colorRGBA: UInt32
    package let isDisplay: Bool
    package let displayScale: CGFloat

    package init(
        latex: String,
        pointSize: CGFloat,
        colorRGBA: UInt32,
        isDisplay: Bool,
        displayScale: CGFloat
    ) {
        self.latex = latex
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

/// parser 진입 전에 source/font/scale을, bitmap 생성 전에 실제 layout 크기를 제한한다.
private enum RasterInputLimits {
    static let minimumPointSize: CGFloat = 1
    static let maximumPointSize: CGFloat = 256
    static let maximumDisplayScale: CGFloat = 4
    static let maximumPixelEdge: CGFloat = 8_192
    static let maximumPixelCount: CGFloat = 4_194_304

    static func allowsInput(_ key: MathRenderKey) -> Bool {
        guard key.pointSize.isFinite,
              key.pointSize >= minimumPointSize,
              key.pointSize <= maximumPointSize,
              key.displayScale.isFinite,
              key.displayScale >= 1,
              key.displayScale <= maximumDisplayScale,
              key.latex.utf8.count <= InputLimits.maxMathSourceUTF8Bytes else {
            return false
        }

        // 이 검사는 TeX 전체 구조 깊이를 증명하지 않는다.
        // RaTeX 자체 parser의 structural depth budget도 유지한다.
        var depth = 0
        var escaped = false
        var inComment = false
        for byte in key.latex.utf8 {
            if inComment { if byte == 10 || byte == 13 { inComment = false }; continue }
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 37 { inComment = true; continue }
            if byte == 123 { depth += 1 }
            if byte == 125 { depth -= 1 }
            if depth < 0 || depth > 64 { return false }
        }
        return depth == 0
    }

}

/// 수식 raster를 담당하는 actor. MainActor에서 CPU raster를 실행하지 않는다.
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

    /// 벡터와 raster가 같은 source/font/scale 진입 상한을 공유하기 위한 통로다.
    package static func preflightAllows(_ key: MathRenderKey) -> Bool {
        RasterInputLimits.allowsInput(key)
    }

    package func removeAll() {
        cache.removeAllObjects()
    }

    /// 렌더 실패(오류·preflight 초과)는 nil. 호출자는 해당 노드만 원문 source로 유지한다.
    package func render(key: MathRenderKey) -> RenderedMath? {
        guard Self.preflightAllows(key) else {
            return nil
        }
        if let cached = cache.object(forKey: KeyBox(key: key)) {
            return cached.value
        }

        let signpostState = RichMarkdownSignposts.raster.beginInterval("raster")
        defer { RichMarkdownSignposts.raster.endInterval("raster", signpostState) }

        guard let rendered = MathRenderer.raster(key: key),
              let pixelCost = rendered.image.pixelByteCost else { return nil }
        cache.setObject(Entry(value: rendered), forKey: KeyBox(key: key), cost: pixelCost)
        return rendered
    }

}

/// iOS와 Android가 같은 native RaTeX 조판과 KaTeX 서체를 사용한다.
private enum MathRenderer {
    // Swift lazy static 초기화가 동기화된다. draw()가 부르는 upstream의 font loader를
    // 첫 초기화에서 끝내 이후 actor/MainActor의 동시 draw에서는 읽기만 하게 한다.
    private static let fontsLoaded: Void = { _ = RaTeXFontLoader.ensureLoaded() }()

    static func measure(key: MathRenderKey, color: UIColor) -> RaTeXRenderer? {
        guard let list = try? RaTeXEngine.shared.parse(
            key.latex, displayMode: key.isDisplay, color: color
        ) else { return nil }
        let renderer = RaTeXRenderer(displayList: list, fontSize: key.pointSize)
        let width = ceil(renderer.width * key.displayScale)
        let height = ceil(renderer.totalHeight * key.displayScale)
        guard renderer.height.isFinite, renderer.height >= 0,
              renderer.depth.isFinite, renderer.depth >= 0,
              width.isFinite, width > 0, width <= RasterInputLimits.maximumPixelEdge,
              height.isFinite, height > 0, height <= RasterInputLimits.maximumPixelEdge,
              width * height <= RasterInputLimits.maximumPixelCount else { return nil }
        _ = fontsLoaded
        // Font가 누락됐거나 새 display-list 명령을 모르면 부분 성공 대신 원문을 남긴다.
        let fonts = Set(list.items.compactMap { item -> String? in
            if case .glyphPath(let glyph) = item { return "KaTeX_\(glyph.font)" }
            return nil
        })
        // upstream `isFontRegistered`는 iOS에서 disabled font만 조회한다.
        // 실제 CoreText가 선택한 PostScript 이름을 비교해 자동 대체 서체도 거부한다.
        guard fonts.allSatisfy({ name in
            let font = CTFontCreateWithName(name as CFString, key.pointSize, nil)
            return CTFontCopyPostScriptName(font) as String == name
        }),
              !list.items.contains(where: { if case .unknown = $0 { return true }; return false })
        else { return nil }
        return renderer
    }

    static func raster(key: MathRenderKey) -> RenderedMath? {
        guard let renderer = measure(key: key, color: UIColor(rgba: key.colorRGBA)) else { return nil }
        let size = CGSize(
            width: ceil(renderer.width * key.displayScale) / key.displayScale,
            height: ceil(renderer.totalHeight * key.displayScale) / key.displayScale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = key.displayScale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            renderer.draw(in: context.cgContext)
        }
        guard let cost = image.pixelByteCost,
              cost <= Int(RasterInputLimits.maximumPixelCount * 4) else { return nil }
        return RenderedMath(image: image, descent: size.height - renderer.height, ascent: renderer.height)
    }
}

@MainActor
private final class NativeMathVectorView: UIView {
    private let renderer: RaTeXRenderer

    init(renderer: RaTeXRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: renderer.width, height: renderer.totalHeight)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        renderer.draw(in: context)
    }
}

/// 블록 수식의 벡터 뷰 팩토리.
///
/// 측정한 RaTeX renderer를 CoreGraphics·CoreText로 직접 그린다.
/// 이미지 중간 단계 없이 크기를 동기 확정하며 엔진 타입은 뷰 계층으로 새지 않는다.
@MainActor
package enum BlockMathVectorView {
    /// 실패(preflight 초과·latex parse 오류)는 nil이다. 호출자는 원문 source를 표시한다.
    ///
    /// UIView 생성은 MainActor 전용이다. raster와 같은 입력/실측 layout 상한을 쓴다.
    package static func make(key: MathRenderKey, textColor: UIColor) -> UIView? {
        guard MathRenderService.preflightAllows(key) else { return nil }
        guard let renderer = MathRenderer.measure(key: key, color: textColor) else { return nil }
        return NativeMathVectorView(renderer: renderer)
    }
}

private extension UIImage {
    var pixelByteCost: Int? {
        guard let cgImage else { return nil }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? nil : cost
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
