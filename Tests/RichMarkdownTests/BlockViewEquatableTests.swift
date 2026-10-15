// Author: JunyoungJung
// Date: 2026-10-15

import SwiftUI
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// SwiftUI 블록 경계(`RichMarkdownBlockView`의 `Equatable`)의 계약.
///
/// 스트리밍 게시마다 `RichMarkdownView` body가 다시 돌아도 값이 같은 앞쪽 블록은 body를
/// 다시 평가하지 않는다. 같다는 판정은 블록 값, tail 문맥, 그 블록이 쓰는 수식 이미지의
/// identity로만 하고, 테마·폰트 배율 같은 environment 변경은 판정과 무관하게 반영돼야 한다.
@MainActor
@Suite(.serialized) struct BlockViewEquatableTests {

    private let document = RichMarkdownParser.parse(
        markdown: #"""
        문단 \(a+b\) 수식

        다른 문단 \(c+d\)

        - 항목 \(e+f\)

        | 열 |
        | --- |
        | \(g+h\) |

        \[i+j\]
        """#,
        parsesDollarMath: false
    )

    private func segment(_ latex: String) throws -> MathSegment {
        try #require(document.allMathSegments.first { $0.latex == latex })
    }

    private func rendered() -> RenderedMath {
        // identity만 판정에 쓴다. 매 호출 새 UIImage 인스턴스다.
        RenderedMath(image: UIImage(), descent: 0, ascent: 0)
    }

    private func view(
        _ index: Int,
        images: [MathSegment: RenderedMath],
        tail: RichMarkdownStreamingTailContext? = nil
    ) -> RichMarkdownBlockView {
        RichMarkdownBlockView(block: document.blocks[index], images: images, tail: tail)
    }

    @Test func equalityTracksBlockAndTail() throws {
        #expect(document.blocks.count == 5)
        #expect(view(0, images: [:]) == view(0, images: [:]))
        #expect(view(0, images: [:]) != view(1, images: [:]), "블록 값이 다르면 다시 그린다")

        let tail = RichMarkdownStreamingTailContext(options: .default, dollarMath: [])
        #expect(view(0, images: [:], tail: tail) == view(0, images: [:], tail: tail))
        #expect(view(0, images: [:], tail: tail) != view(0, images: [:]), "tail이 붙거나 빠지면 다시 그린다")
    }

    @Test func equalityComparesOnlyOwnMathImageIdentity() throws {
        let own = try segment("a+b")
        let other = try segment("c+d")
        let image = rendered()
        let base: [MathSegment: RenderedMath] = [own: image, other: rendered()]

        var otherReplaced = base
        otherReplaced[other] = rendered()
        #expect(view(0, images: base) == view(0, images: otherReplaced), "다른 블록의 수식 이미지는 판정에 넣지 않는다")

        var ownReplaced = base
        ownReplaced[own] = rendered()
        #expect(view(0, images: base) != view(0, images: ownReplaced), "같은 수식이라도 새 raster면 다시 그린다")

        var ownRemoved = base
        ownRemoved[own] = nil
        #expect(view(0, images: base) != view(0, images: ownRemoved), "이미지 유무가 바뀌면 다시 그린다")
        #expect(view(0, images: [own: image]) == view(0, images: [own: image]), "같은 인스턴스면 같다")
    }

    /// 목록·표·블록 수식처럼 수식이 안쪽에 있는 블록도 자기 수식 이미지를 비교한다.
    @Test func equalityFindsMathInsideContainerBlocks() throws {
        for (index, latex) in [(2, "e+f"), (3, "g+h"), (4, "i+j")] {
            let own = try segment(latex)
            let before = [own: rendered()]
            #expect(view(index, images: before) == view(index, images: before))
            #expect(view(index, images: before) != view(index, images: [own: rendered()]), "블록 \(index)")
            #expect(view(index, images: before) != view(index, images: [:]), "블록 \(index)")
        }
    }

    // MARK: - environment 반영

    /// 판정용 marker 색. 시스템 색·기본 테마와 겹치지 않는다 (ThemeReachTests와 같은 방식).
    private static let marker = Color(red: 1, green: 0, blue: 1)

    /// 블록 입력은 고정하고 environment만 바꾸는 루트. 타입이 같아 rootView를 바꿔도
    /// `EquatableView`가 이전 값과 비교된다(AnyView로 감싸지 않는다).
    private struct Harness: View {
        let block: ParsedBlock
        let theme: RichMarkdownTheme
        let fontScale: RichMarkdownFontScale

        var body: some View {
            RichMarkdownBlockView(block: block, images: [:])
                .equatable()
                .richMarkdownTheme(theme)
                .environment(\.richMarkdownFontScale, fontScale)
                .frame(width: 320, alignment: .leading)
                .background(Color.white)
        }
    }

    private func markerPixelCount(in view: UIView) -> Int {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
            view.layer.render(in: $0.cgContext)
        }
        guard let cgImage = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] > 220 && pixels[$0 + 1] < 40 && pixels[$0 + 2] > 220
        }.count
    }

    private func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "environment 변경이 제한 시간 안에 화면에 반영돼야 한다 (호출 줄: \(line))")
    }

    /// 블록 입력이 같아 `==`가 true여도 테마·폰트 배율(Dynamic Type) 변경은 화면에 닿는다.
    /// environment를 읽는 하위 뷰는 부모의 Equatable 판정과 별개로 무효화된다.
    @Test func environmentChangesReachEquatableBlockView() async throws {
        let block = ParsedBlock.paragraph([InlineRun(content: .text("가나다 ABC 본문"))])
        // 명시 크기 폰트여야 `richMarkdownFontScale`이 적용된다. text style 폰트는 SwiftUI가 직접 키운다.
        let markerTheme = RichMarkdownTheme(
            textColor: Self.marker,
            bodyFont: RichMarkdownFont(relativeTo: .body, size: 17)
        )
        let controller = UIHostingController(
            rootView: Harness(block: block, theme: .default, fontScale: RichMarkdownFontScale())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        #expect(markerPixelCount(in: controller.view) == 0, "기본 테마는 marker 픽셀이 없다")

        controller.rootView = Harness(block: block, theme: markerTheme, fontScale: RichMarkdownFontScale())
        try await waitUntil { markerPixelCount(in: controller.view) > 0 }
        let regularInk = markerPixelCount(in: controller.view)

        controller.rootView = Harness(block: block, theme: markerTheme, fontScale: RichMarkdownFontScale(body: 2))
        try await waitUntil { markerPixelCount(in: controller.view) > regularInk }
    }
}
