import Foundation

/// 원문 UTF-8 byte 배열에서 수식 span을 찾는다. DEVELOPMENT.md §3.
///
/// - 수식은 1차 Markdown AST가 아니라 원문 전체에서 탐색한다.
///   `\(a * b\)`, `\(x_[i]\)`, link-like source처럼 Markdown 기호가 든 LaTeX를
///   노드 분할과 무관하게 보호하기 위함이다.
/// - code/HTML 전체 범위는 hard barrier: 내부 delimiter를 절대 수식으로 보지 않고
///   경계를 가로지르는 매칭도 없다.
/// - link/image 전체 범위는 soft range: 수식 span이 완전히 포함하면 수식이 이기고,
///   delimiter가 range 안에 있으면(부분 겹침 포함) 수식이 아니다.
///   → `[\(x\)](url)`은 보호되고 `\([a](b)\)`는 수식이다.
/// - block 수식은 1차 AST paragraph 전체 기준으로 판정하고, 나머지 허용 범위에서 inline을 찾는다.
package struct MathScanner: Sendable {
    package struct Result: Sendable {
        package var spans: [ProtectedMathSpan]
        package var diagnostics: [MathDiagnostic]
    }

    private let bytes: [UInt8]
    /// 정렬·병합된 hard barrier (code/HTML 전체 범위).
    private let hardRanges: [Range<Int>]
    /// 정렬·병합된 soft range (link/image 전체 범위).
    private let softRanges: [Range<Int>]
    private let paragraphRanges: [Range<Int>]
    private let parsesDollarMath: Bool

    package init(
        bytes: [UInt8],
        forbiddenRanges: [Range<Int>],
        softRanges: [Range<Int>] = [],
        paragraphRanges: [Range<Int>],
        parsesDollarMath: Bool
    ) {
        self.bytes = bytes
        self.hardRanges = Self.merged(forbiddenRanges)
        self.softRanges = Self.merged(softRanges)
        self.paragraphRanges = paragraphRanges
        self.parsesDollarMath = parsesDollarMath
    }

    package func scan() -> Result {
        var spans: [ProtectedMathSpan] = []
        var diagnostics: [MathDiagnostic] = []

        // 1) block 수식: 공백 제외 paragraph 전체가 \[...\] 또는 opt-in $$...$$
        for paragraph in paragraphRanges {
            guard !intersectsHard(paragraph) else { continue }
            if let span = blockSpan(inParagraph: paragraph, diagnostics: &diagnostics) {
                spans.append(span)
            }
        }

        // 2) inline 수식: hard barrier와 block span을 배리어로 두고 허용 구간에서 탐색.
        var barriers = hardRanges + spans.map(\.originalUTF8Range)
        barriers = Self.merged(barriers)
        for segment in allowedSegments(excluding: barriers) {
            scanInline(in: segment, spans: &spans, diagnostics: &diagnostics)
        }

        spans.sort { $0.originalUTF8Range.lowerBound < $1.originalUTF8Range.lowerBound }
        return Result(spans: spans, diagnostics: diagnostics)
    }

    // MARK: - Block math

    private func blockSpan(
        inParagraph paragraph: Range<Int>,
        diagnostics: inout [MathDiagnostic]
    ) -> ProtectedMathSpan? {
        let trimmed = trimWhitespace(paragraph)
        guard trimmed.count >= 4 else { return nil }
        let s = trimmed.lowerBound
        let e = trimmed.upperBound

        // \[ ... \]
        if bytes[s] == UInt8(ascii: "\\"), bytes[s + 1] == UInt8(ascii: "["), !isBackslashEscaped(at: s) {
            guard e - s >= 4,
                  bytes[e - 2] == UInt8(ascii: "\\"), bytes[e - 1] == UInt8(ascii: "]"),
                  !isBackslashEscaped(at: e - 2)
            else {
                diagnostics.append(MathDiagnostic(kind: .unterminatedDelimiter, utf8Range: trimmed))
                return nil
            }
            // 내부에 조기 닫힘 \] 이 있으면 paragraph 전체 wrap이 아니다.
            if firstUnescapedDelimiter(prefixByte: UInt8(ascii: "\\"), byte: UInt8(ascii: "]"),
                                       in: (s + 2)..<(e - 2)) != nil {
                diagnostics.append(MathDiagnostic(kind: .nestedDelimiter, utf8Range: trimmed))
                return nil
            }
            let inner = trimWhitespace((s + 2)..<(e - 2))
            guard !inner.isEmpty else {
                diagnostics.append(MathDiagnostic(kind: .emptyMath, utf8Range: trimmed))
                return nil
            }
            guard softRangesAllow(span: trimmed, content: (s + 2)..<(e - 2)) else { return nil }
            return makeSpan(range: trimmed, kind: .displayBracket)
        }

        // $$ ... $$ (opt-in). $$는 $보다 먼저 판정한다.
        if parsesDollarMath,
           bytes[s] == UInt8(ascii: "$"), bytes[s + 1] == UInt8(ascii: "$"), !isBackslashEscaped(at: s) {
            guard e - s >= 5,
                  bytes[e - 2] == UInt8(ascii: "$"), bytes[e - 1] == UInt8(ascii: "$"),
                  !isBackslashEscaped(at: e - 2)
            else {
                diagnostics.append(MathDiagnostic(kind: .unterminatedDelimiter, utf8Range: trimmed))
                return nil
            }
            if firstDollarDollar(in: (s + 2)..<(e - 2)) != nil {
                diagnostics.append(MathDiagnostic(kind: .nestedDelimiter, utf8Range: trimmed))
                return nil
            }
            let inner = trimWhitespace((s + 2)..<(e - 2))
            guard !inner.isEmpty else {
                diagnostics.append(MathDiagnostic(kind: .emptyMath, utf8Range: trimmed))
                return nil
            }
            guard softRangesAllow(span: trimmed, content: (s + 2)..<(e - 2)) else { return nil }
            return makeSpan(range: trimmed, kind: .displayDollar)
        }

        return nil
    }

    // MARK: - Inline math

    private func scanInline(
        in segment: Range<Int>,
        spans: inout [ProtectedMathSpan],
        diagnostics: inout [MathDiagnostic]
    ) {
        var i = segment.lowerBound
        while i < segment.upperBound {
            let b = bytes[i]
            if b == UInt8(ascii: "\\"), i + 1 < segment.upperBound,
               bytes[i + 1] == UInt8(ascii: "("), !isBackslashEscaped(at: i) {
                let outcome = inlineParenSpan(openingAt: i, segment: segment, diagnostics: &diagnostics)
                if let span = outcome.span {
                    spans.append(span)
                    i = span.originalUTF8Range.upperBound
                } else {
                    i = outcome.nextIndex
                }
                continue
            }
            if b == UInt8(ascii: "\\"), i + 1 < segment.upperBound,
               bytes[i + 1] == UInt8(ascii: "["), !isBackslashEscaped(at: i) {
                // ponytail: paragraph 전체가 아닌 \[...\]는 v1에서 plain text + diagnostic.
                // 필요가 측정되면 inline display로 승격한다.
                diagnostics.append(
                    MathDiagnostic(kind: .nonParagraphDisplayDelimiter, utf8Range: i..<min(i + 2, segment.upperBound))
                )
                i += 2
                continue
            }
            if parsesDollarMath, b == UInt8(ascii: "$"), !isBackslashEscaped(at: i) {
                // $$를 $보다 먼저 판정: inline 위치의 $$ 토큰은 수식이 아니다.
                if i + 1 < segment.upperBound, bytes[i + 1] == UInt8(ascii: "$") {
                    i += 2
                    continue
                }
                if let span = inlineDollarSpan(openingAt: i, segment: segment) {
                    spans.append(span)
                    i = span.originalUTF8Range.upperBound
                    continue
                }
                i += 1
                continue
            }
            i += 1
        }
    }

    /// `\( ... \)` — 한 logical line의 inline 수식.
    ///
    /// 수식이 아닐 때는 다음 스캔 위치도 함께 돌려준다. 중첩·빈 구분자는 닫는
    /// delimiter 뒤로 건너뛰어야 구간 전체가 plain text로 남는다. 미완성 구분자는
    /// 여는 delimiter 뒤부터 계속 탐색해 같은 줄의 다른 후보를 놓치지 않는다.
    private func inlineParenSpan(
        openingAt open: Int,
        segment: Range<Int>,
        diagnostics: inout [MathDiagnostic]
    ) -> (span: ProtectedMathSpan?, nextIndex: Int) {
        // 여는 delimiter가 link/image 내부에 있으면 수식이 아니다.
        guard !insideSoftRange(open) else { return (nil, open + 2) }
        let contentStart = open + 2
        let lineEnd = endOfLine(from: contentStart, limit: segment.upperBound)
        guard let close = firstUnescapedDelimiter(prefixByte: UInt8(ascii: "\\"), byte: UInt8(ascii: ")"),
                                                  in: contentStart..<lineEnd)
        else {
            diagnostics.append(MathDiagnostic(kind: .unterminatedDelimiter, utf8Range: open..<lineEnd))
            return (nil, open + 2)
        }
        let end = close + 2
        // 중첩 opener는 구간 전체가 plain text + diagnostic이다.
        if firstUnescapedDelimiter(prefixByte: UInt8(ascii: "\\"), byte: UInt8(ascii: "("),
                                   in: contentStart..<close) != nil {
            diagnostics.append(MathDiagnostic(kind: .nestedDelimiter, utf8Range: open..<end))
            return (nil, end)
        }
        let inner = trimWhitespace(contentStart..<close)
        guard !inner.isEmpty else {
            diagnostics.append(MathDiagnostic(kind: .emptyMath, utf8Range: open..<end))
            return (nil, end)
        }
        guard softRangesAllow(span: open..<end, content: contentStart..<close) else {
            return (nil, end)
        }
        return (makeSpan(range: open..<end, kind: .inlineParen), end)
    }

    /// `$ ... $` — v1 자체 규칙 (DEVELOPMENT.md §3):
    /// 여는 `$` 바로 뒤/닫는 `$` 바로 앞 공백 금지, 닫는 `$` 뒤 숫자 금지, 줄바꿈 금지.
    private func inlineDollarSpan(openingAt open: Int, segment: Range<Int>) -> ProtectedMathSpan? {
        guard !insideSoftRange(open) else { return nil }
        let contentStart = open + 1
        let lineEnd = endOfLine(from: contentStart, limit: segment.upperBound)
        guard contentStart < lineEnd, !isSpaceOrTab(bytes[contentStart]) else { return nil }

        var candidate = contentStart
        while let close = firstUnescapedDelimiter(prefixByte: nil, byte: UInt8(ascii: "$"),
                                                  in: candidate..<lineEnd) {
            // 닫는 후보가 $$의 일부이면 무효.
            if close + 1 < lineEnd, bytes[close + 1] == UInt8(ascii: "$") {
                candidate = close + 2
                continue
            }
            let validBefore = close > contentStart && !isSpaceOrTab(bytes[close - 1])
            let validAfter = close + 1 >= lineEnd || !isASCIIDigit(bytes[close + 1])
            if validBefore && validAfter {
                guard softRangesAllow(span: open..<(close + 1), content: contentStart..<close) else {
                    candidate = close + 1
                    continue
                }
                return makeSpan(range: open..<(close + 1), kind: .inlineDollar)
            }
            candidate = close + 1
        }
        return nil
    }

    // MARK: - Soft range 규칙

    /// span과 겹치는 모든 soft range(link/image)가 content 안에 완전히 포함될 때만 수식이 성립한다.
    private func softRangesAllow(span: Range<Int>, content: Range<Int>) -> Bool {
        for soft in softRanges where soft.overlaps(span) {
            guard soft.lowerBound >= content.lowerBound, soft.upperBound <= content.upperBound else {
                return false
            }
        }
        return true
    }

    private func insideSoftRange(_ index: Int) -> Bool {
        softRanges.contains { $0.contains(index) }
    }

    // MARK: - Byte helpers

    private func makeSpan(range: Range<Int>, kind: MathKind) -> ProtectedMathSpan {
        let source = String(decoding: bytes[range], as: UTF8.self)
        return ProtectedMathSpan(originalUTF8Range: range, kind: kind, source: source)
    }

    /// index 위치 byte 바로 앞의 연속 backslash 수가 홀수면 escape된 것이다.
    private func isBackslashEscaped(at index: Int) -> Bool {
        var count = 0
        var i = index - 1
        while i >= 0, bytes[i] == UInt8(ascii: "\\") {
            count += 1
            i -= 1
        }
        return count % 2 == 1
    }

    /// `prefixByte`가 nil이면 단일 byte delimiter, 있으면 2-byte delimiter(prefix+byte)를 찾는다.
    /// escape된 delimiter는 건너뛴다. 반환값은 delimiter 시작 index.
    private func firstUnescapedDelimiter(prefixByte: UInt8?, byte: UInt8, in range: Range<Int>) -> Int? {
        var i = range.lowerBound
        while i < range.upperBound {
            if let prefix = prefixByte {
                if bytes[i] == prefix, i + 1 < range.upperBound, bytes[i + 1] == byte,
                   !isBackslashEscaped(at: i) {
                    return i
                }
            } else if bytes[i] == byte, !isBackslashEscaped(at: i) {
                return i
            }
            i += 1
        }
        return nil
    }

    private func firstDollarDollar(in range: Range<Int>) -> Int? {
        var i = range.lowerBound
        while i + 1 < range.upperBound {
            if bytes[i] == UInt8(ascii: "$"), bytes[i + 1] == UInt8(ascii: "$"),
               !isBackslashEscaped(at: i) {
                return i
            }
            i += 1
        }
        return nil
    }

    private func endOfLine(from start: Int, limit: Int) -> Int {
        var i = start
        while i < limit {
            let b = bytes[i]
            if b == 0x0A || b == 0x0D { return i }
            i += 1
        }
        return limit
    }

    private func trimWhitespace(_ range: Range<Int>) -> Range<Int> {
        var s = range.lowerBound
        var e = range.upperBound
        while s < e, isWhitespaceByte(bytes[s]) { s += 1 }
        while e > s, isWhitespaceByte(bytes[e - 1]) { e -= 1 }
        return s..<e
    }

    private func isWhitespaceByte(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    private func isSpaceOrTab(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }
    private func isASCIIDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private func intersectsHard(_ range: Range<Int>) -> Bool {
        hardRanges.contains { $0.overlaps(range) }
    }

    private func allowedSegments(excluding barriers: [Range<Int>]) -> [Range<Int>] {
        var segments: [Range<Int>] = []
        var cursor = 0
        for barrier in barriers {
            if cursor < barrier.lowerBound {
                segments.append(cursor..<barrier.lowerBound)
            }
            cursor = max(cursor, barrier.upperBound)
        }
        if cursor < bytes.count {
            segments.append(cursor..<bytes.count)
        }
        return segments
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
