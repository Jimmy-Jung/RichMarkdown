// Author: JunyoungJung
// Date: 2026-09-04

import Testing
import UIKit
@testable import SwiftLatex
@testable import SwiftLatexCore

@Suite struct DollarMathOptionsTests {
    @Test func boolBridgeMapsToSingle() {
        #expect(LatexDollarMathOptions(parsesDollarMath: true) == [.single])
        #expect(LatexDollarMathOptions(parsesDollarMath: false) == [])
        #expect(LatexDollarMathOptions.inlineDouble.core == [.inlineDouble])
        #expect(LatexDollarMathOptions([.single, .inlineDouble]).core == [.single, .inlineDouble])
    }

    @Test func parseCacheKeySeparatesDollarOptionCombinations() {
        let cache = ParseCache.shared
        let single = cache.key(markdown: "x", dollarMath: [.single], wasTruncated: false)
        let both = cache.key(markdown: "x", dollarMath: [.single, .inlineDouble], wasTruncated: false)
        let legacy = cache.key(markdown: "x", parsesDollarMath: true, wasTruncated: false)
        #expect(single.value != both.value)
        #expect(single.value == legacy.value)
    }

    @Test func requestIdentityTracksDollarOptions() {
        let single = LatexRenderModel.Request(
            markdown: "$$x$$", parsesDollarMath: true, pointSize: 16, colorRGBA: 0, displayScale: 2
        )
        let both = LatexRenderModel.Request(
            boundedInput: InputLimits.bound("$$x$$"), dollarMath: [.single, .inlineDouble],
            pointSize: 16, colorRGBA: 0, displayScale: 2
        )
        #expect(single.parseIdentity != both.parseIdentity)
        #expect(!single.parseIdentity.isStreamingPrefix(of: both.parseIdentity))
    }

    @Test @MainActor func uiViewBoolPropertyBridgesToOptionSet() {
        let view = LatexMarkdownUIView(markdown: "x", dollarMath: [.inlineDouble])
        #expect(view.parsesDollarMath == false)
        view.parsesDollarMath = true
        #expect(view.dollarMath == [.single, .inlineDouble])
        view.parsesDollarMath = false
        #expect(view.dollarMath == [.inlineDouble])
    }

    @Test func inlineScannerFindsDoubleDollarWhenOptedIn() {
        let spans = LatexInlineMathScanner.scan("총합($$f(1)$$)", dollarMath: [.single, .inlineDouble])
        #expect(spans.map(\.latex) == ["f(1)"])
        #expect(LatexInlineMathScanner.scan("총합($$f(1)$$)", parsesDollarMath: true).isEmpty)
    }
}
