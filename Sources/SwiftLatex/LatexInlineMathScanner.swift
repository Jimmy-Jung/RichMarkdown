// Created by JunyoungJung on 2026-08-24.

import Foundation
import SwiftLatexCore

/// 원문의 UTF-16 위치와 구분자 포함 source를 보존한 인라인 수식입니다.
public struct LatexInlineMathSpan: Equatable, Sendable {
    public let range: NSRange
    public let source: String
    public let latex: String

    public init(range: NSRange, source: String, latex: String) {
        self.range = range
        self.source = source
        self.latex = latex
    }
}

/// SwiftLatex의 Markdown 렌더러와 같은 delimiter 규칙으로 인라인 수식을 찾습니다.
public enum LatexInlineMathScanner {
    /// - Parameters:
    ///   - source: 검사할 원문입니다.
    ///   - parsesDollarMath: `true`일 때만 `$...$`를 수식으로 인식합니다.
    ///   - excludedRanges: 인라인 코드처럼 수식으로 해석하면 안 되는 UTF-16 범위입니다.
    public static func scan(
        _ source: String,
        parsesDollarMath: Bool = false,
        excluding excludedRanges: [NSRange] = []
    ) -> [LatexInlineMathSpan] {
        scan(
            source,
            dollarMath: LatexDollarMathOptions(parsesDollarMath: parsesDollarMath),
            excluding: excludedRanges
        )
    }

    /// - Parameter dollarMath: `.inlineDouble`이 있으면 문장 안 `$$...$$`도 인라인 수식으로 찾는다.
    public static func scan(
        _ source: String,
        dollarMath: LatexDollarMathOptions,
        excluding excludedRanges: [NSRange] = []
    ) -> [LatexInlineMathSpan] {
        guard source.utf8.count <= InputLimits.maxInputUTF8Bytes else { return [] }

        let bytes = Array(source.utf8)
        let spans = SwiftLatexParser.scanInlineMathSpans(
            markdown: source,
            dollarMath: dollarMath.core,
            excludingUTF8Ranges: excludedRanges.compactMap { utf8Range($0, in: source) }
        )

        var utf8Cursor = 0
        var utf16Cursor = 0
        return spans.map { span in
            utf16Cursor += String(
                decoding: bytes[utf8Cursor..<span.originalUTF8Range.lowerBound],
                as: UTF8.self
            ).utf16.count
            let result = LatexInlineMathSpan(
                range: NSRange(location: utf16Cursor, length: span.source.utf16.count),
                source: span.source,
                latex: span.latex
            )
            utf8Cursor = span.originalUTF8Range.upperBound
            utf16Cursor += span.source.utf16.count
            return result
        }
    }

    private static func utf8Range(_ range: NSRange, in source: String) -> Range<Int>? {
        guard range.length > 0,
              let stringRange = Range(range, in: source),
              let lower = stringRange.lowerBound.samePosition(in: source.utf8),
              let upper = stringRange.upperBound.samePosition(in: source.utf8)
        else { return nil }

        let start = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let end = source.utf8.distance(from: source.utf8.startIndex, to: upper)
        return start..<end
    }
}
