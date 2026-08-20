import Foundation
import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

/// iOS Simulator에서만 실행하는 UIKit 의존 테스트 (DEVELOPMENT.md §8 CI 원칙).
/// memory warning notification이 전역이라 직렬 실행한다.
@Suite(.serialized) struct MathRenderServiceTests {

    private func makeKey(
        latex: String = "x^2",
        mathFont: LatexMathFont = .latinModern,
        pointSize: CGFloat = 17,
        rgba: UInt32 = 0x000000FF,
        display: Bool = false,
        scale: CGFloat = 3
    ) -> MathRenderKey {
        MathRenderKey(
            latex: latex,
            mathFont: mathFont,
            pointSize: pointSize,
            colorRGBA: rgba,
            isDisplay: display,
            displayScale: scale
        )
    }

    // MARK: - cache key (font/size/color/mode/scale)

    @Test func cacheKeyDistinguishesAllComponents() {
        let base = makeKey()
        #expect(base != makeKey(latex: "x^3"))
        #expect(base != makeKey(mathFont: .xits))
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
        #expect(rendered == nil, "수식 source 상한 초과는 asImage() 호출 전에 거부한다")
    }

    @Test func invalidRasterParametersFailPreflight() async {
        let service = MathRenderService()
        for pointSize in [CGFloat(-1), 0, .nan, .infinity, 257] {
            let rendered = await service.render(key: makeKey(pointSize: pointSize))
            #expect(rendered == nil, "비정상 point size는 asImage() 전에 거부한다")
        }
        for scale in [CGFloat(-1), 0, .nan, .infinity, 4.5] {
            let rendered = await service.render(key: makeKey(scale: scale))
            #expect(rendered == nil, "비정상 display scale은 asImage() 전에 거부한다")
        }
    }

    @Test func oversizedEstimatedBitmapFailsPreflight() async {
        let service = MathRenderService()
        // 짧은 source라도 256pt·4x의 추정 bitmap은 4 Mi pixels를 넘는다.
        let rendered = await service.render(key: makeKey(latex: "a+b+c", pointSize: 256, scale: 4))
        #expect(rendered == nil, "bitmap 작업 상한 초과는 asImage() 전에 거부한다")
    }

    @Test func invalidLatexFallsBackToNil() async {
        let service = MathRenderService()
        let rendered = await service.render(key: makeKey(latex: #"\frac{"#))
        #expect(rendered == nil, "malformed LaTeX는 nil → 호출자가 원문 source 표시")
    }

    /// 수식 서체가 실제로 raster에 반영되는지. key만 갈리고 글리프가 같으면
    /// `fontIdentifier`처럼 캐시만 쪼개는 죽은 필드가 된다.
    @Test func mathFontChangesRasterOutput() async throws {
        let service = MathRenderService()
        let latinModern = try #require(await service.render(key: makeKey(latex: "x+y", mathFont: .latinModern)))
        let xits = try #require(await service.render(key: makeKey(latex: "x+y", mathFont: .xits)))

        let a = try #require(latinModern.image.pngData())
        let b = try #require(xits.image.pngData())
        #expect(a != b, "서체가 다르면 raster 결과가 달라야 한다")
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

    /// 12종 전부 SwiftMath 번들에서 실제로 로드되는지 확인한다.
    @Test func everyMathFontRenders() async throws {
        let service = MathRenderService()
        for font in LatexMathFont.allCases {
            let rendered = await service.render(key: makeKey(latex: "a+b", mathFont: font))
            #expect(rendered != nil, "\(font.rawValue) 서체가 raster를 만들어야 한다")
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
