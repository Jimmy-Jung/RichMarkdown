import Foundation
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// iOS Simulator에서만 실행하는 UIKit 의존 테스트 (DEVELOPMENT.md §8 CI 원칙).
/// memory warning notification이 전역이라 직렬 실행한다.
@Suite(.serialized) struct MathRenderServiceTests {

    private func makeKey(
        latex: String = "x^2",
        pointSize: CGFloat = 17,
        rgba: UInt32 = 0x000000FF,
        display: Bool = false,
        scale: CGFloat = 3
    ) -> MathRenderKey {
        MathRenderKey(
            latex: latex,
            pointSize: pointSize,
            colorRGBA: rgba,
            isDisplay: display,
            displayScale: scale
        )
    }

    // MARK: - cache key (source/size/color/mode/scale)

    @Test func cacheKeyDistinguishesAllComponents() {
        let base = makeKey()
        #expect(base != makeKey(latex: "x^3"))
        #expect(base != makeKey(pointSize: 21))
        #expect(base != makeKey(rgba: 0xFFFFFFFF))
        #expect(base != makeKey(display: true))
        #expect(base != makeKey(scale: 2))
        #expect(base == makeKey())
    }

    // MARK: - raster + baseline layout

    @Test func renderProducesImageAndLayout() async throws {
        let service = MathRenderService()
        let rendered = try #require(await service.render(key: makeKey(latex: #"\frac{a}{b}"#)))
        #expect(rendered.image.size.width > 0)
        #expect(rendered.image.size.height > 0)
        #expect(rendered.descent >= 0)
    }

    private static let complexEquations = [
        #"\underbrace{a+b+c}_{q}"#,
        #"\left\{\begin{array}{cc}1+\frac{a-b}{2\Delta t/T}&\mathrm{if}\ Q>0\\0&\mathrm{if}\ Q=0\end{array}\right."#,
        #"""
        r_t=\left\{\begin{array}{ccc}
        \underbrace{\begin{array}{c}
        1+\frac{\bar{R}_Q(t+\Delta t)-R_Q(t)}{2\Delta t/T_{\mathrm{single}}}\\
        0\\
        0
        \end{array}}_{r_t^{(1)}}&
        \underbrace{\begin{array}{c}
        \vphantom{\frac{\bar{R}_Q}{T_{\mathrm{single}}}}+0\\
        -P\\
        +0
        \end{array}}_{r_t^{(2)}}&
        \begin{array}{l}
        \vphantom{\frac{\bar{R}_Q}{T_{\mathrm{single}}}}\mathrm{if}\ \bar{R}_Q(t+\Delta t)>0\\
        \mathrm{if}\ \bar{R}_Q(t)\ne0\ \mathrm{and}\ R_Q(t+\Delta t)=0\\
        \mathrm{if}\ R_Q(t)=0
        \end{array}
        \end{array}\right.
        """#,
    ]

    @Test(arguments: complexEquations)
    func complexEquationsRenderWithBaselineAndRequestedScale(latex: String) async throws {
        let service = MathRenderService()
        for display in [false, true] {
            let key = makeKey(latex: latex, display: display, scale: 2)
            let rendered = try #require(await service.render(key: key))
            #expect(rendered.image.scale == 2)
            #expect(rendered.image.size.width > 0)
            #expect(rendered.image.size.height > 0)
            #expect(try containsInk(rendered.image), "글리프와 괄호가 실제 pixel로 그려져야 한다")
            #expect(rendered.ascent.isFinite && rendered.ascent > 0)
            #expect(rendered.descent.isFinite && rendered.descent >= 0)
            #expect(abs(rendered.image.size.height - rendered.ascent - rendered.descent) < 1)
            #expect(service.cachedImage(for: key)?.image === rendered.image)
        }
    }

    @MainActor @Test(arguments: complexEquations)
    func complexEquationsRenderAsNativeVectors(latex: String) throws {
        let key = makeKey(latex: latex, display: true)
        let vector = try #require(BlockMathVectorView.make(key: key, textColor: .black))
        #expect(!(vector is UIImageView))
        #expect(vector.intrinsicContentSize.width.isFinite && vector.intrinsicContentSize.width > 0)
        #expect(vector.intrinsicContentSize.height.isFinite && vector.intrinsicContentSize.height > 0)
    }

    @Test func oversizedComplexLayoutFailsBeforeBitmapAllocation() async {
        let service = MathRenderService()
        let key = makeKey(latex: #"\underbrace{\rule{9000pt}{1pt}}_{q}"#)
        #expect(await service.render(key: key) == nil)
        #expect(service.cachedImage(for: key) == nil)
        await MainActor.run {
            #expect(BlockMathVectorView.make(key: key, textColor: .black) == nil)
        }
    }

    @Test func excessiveMathNestingFailsBeforeParsing() async {
        let service = MathRenderService()
        let latex = String(repeating: "{", count: 200) + #"\underbrace{x}_{q}"#
            + String(repeating: "}", count: 200)
        #expect(await service.render(key: makeKey(latex: latex)) == nil)
    }

    @Test func nativeMathPreservesColorAndScale() async throws {
        let service = MathRenderService()
        let latex = #"\underbrace{a+b+c}_{q}"#
        let oneX = try #require(await service.render(key: makeKey(latex: latex, scale: 1)))
        let threeX = try #require(await service.render(key: makeKey(latex: latex, scale: 3)))
        let red = try #require(await service.render(key: makeKey(latex: latex, rgba: 0xFF0000FF, scale: 1)))
        #expect(abs(oneX.image.size.width - threeX.image.size.width) < 1)
        #expect(abs(oneX.image.size.height - threeX.image.size.height) < 1)
        let oneCG = try #require(oneX.image.cgImage)
        let threeCG = try #require(threeX.image.cgImage)
        #expect(threeCG.width > oneCG.width)
        #expect(threeCG.height > oneCG.height)
        let blackPNG = try #require(oneX.image.pngData())
        let redPNG = try #require(red.image.pngData())
        #expect(blackPNG != redPNG, "수식은 요청한 RGBA를 반영한다")
        #expect(try containsInk(oneX.image))
        #expect(try containsInk(red.image))
    }

    private func containsInk(_ image: UIImage) throws -> Bool {
        let cgImage = try #require(image.cgImage)
        let rowBytes = cgImage.width * 4
        let context = try #require(CGContext(
            data: nil, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(cgImage, in: CGRect(
            x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
        ))
        let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: rowBytes * cgImage.height)
        return stride(from: 3, to: rowBytes * cgImage.height, by: 4).contains { bytes[$0] > 0 }
    }

    @Test func renderCachesResult() async throws {
        let service = MathRenderService()
        let key = makeKey(latex: "a+b")
        let first = try #require(await service.render(key: key))
        let cached = try #require(service.cachedImage(for: key))
        #expect(first.image === cached.image, "두 번째 조회는 cache hit이어야 한다")
    }

    @Test func oversizedMathSourceFailsPreflight() async {
        let service = MathRenderService()
        let huge = String(repeating: "x+", count: InputLimits.maxMathSourceUTF8Bytes)
        let rendered = await service.render(key: makeKey(latex: huge))
        #expect(rendered == nil, "수식 source 상한 초과는 parser 진입 전에 거부한다")
    }

    @Test func invalidRasterParametersFailPreflight() async {
        let service = MathRenderService()
        for pointSize in [CGFloat(-1), 0, .nan, .infinity, 257] {
            let rendered = await service.render(key: makeKey(pointSize: pointSize))
            #expect(rendered == nil, "비정상 point size는 parser 진입 전에 거부한다")
        }
        for scale in [CGFloat(-1), 0, .nan, .infinity, 4.5] {
            let rendered = await service.render(key: makeKey(scale: scale))
            #expect(rendered == nil, "비정상 display scale은 parser 진입 전에 거부한다")
        }
    }

    @Test func oversizedBitmapFailsLayoutBounds() async {
        let service = MathRenderService()
        let rendered = await service.render(key: makeKey(
            latex: String(repeating: "a+", count: 20), pointSize: 256, scale: 4
        ))
        #expect(rendered == nil, "실제 pixel edge 상한을 넘으면 bitmap을 만들지 않는다")
    }

    @Test func invalidLatexFallsBackToNil() async {
        let service = MathRenderService()
        let rendered = await service.render(key: makeKey(latex: #"\frac{"#))
        #expect(rendered == nil, "malformed LaTeX는 nil → 호출자가 원문 source 표시")
    }


    @Test func renderUsesRequestedDisplayScale() async throws {
        let service = MathRenderService()
        let oneX = try #require(await service.render(key: makeKey(latex: #"\frac{a}{b}"#, scale: 1)))
        let threeX = try #require(await service.render(key: makeKey(latex: #"\frac{a}{b}"#, scale: 3)))
        let oneCGImage = try #require(oneX.image.cgImage)
        let threeCGImage = try #require(threeX.image.cgImage)

        #expect(oneX.image.scale == 1)
        #expect(threeX.image.scale == 3)
        #expect(abs(oneX.image.size.width - threeX.image.size.width) < 1)
        #expect(abs(oneX.image.size.height - threeX.image.size.height) < 1)
        #expect(threeCGImage.width > oneCGImage.width)
        #expect(threeCGImage.height > oneCGImage.height)
    }

    /// 엔진 통일 후에도 기존 수식군을 raster/vector 양쪽에서 그린다.
    @Test(arguments: [
        "a+b", #"\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#,
        #"\sum_{i=1}^{n}x_i+\int_0^1 t^2\,dt"#,
        #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
        #"\begin{cases}x^2&x>0\\0&x\le0\end{cases}"#,
        #"\mathbf{x}+\mathcal{F}+\mathbb{R}+\mathrm{single}"#,
    ])
    func existingEquationFamiliesRender(latex: String) async throws {
        let service = MathRenderService()
        let key = makeKey(latex: latex, display: true)
        let rendered = try #require(await service.render(key: key))
        #expect(rendered.image.size.width > 0 && rendered.image.size.height > 0)
        await MainActor.run {
            #expect(BlockMathVectorView.make(key: key, textColor: .black) != nil)
        }
    }

    @Test func memoryWarningClearsCache() async throws {
        let service = MathRenderService()
        let key = makeKey(latex: "c^2")
        _ = await service.render(key: key)
        #expect(service.cachedImage(for: key) != nil)
        await MainActor.run {
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification, object: nil
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(service.cachedImage(for: key) == nil, "memory warning에서 cache를 비운다")
    }
}
