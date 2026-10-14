import Foundation
import Markdown

/// swift-markdown의 SourceLocation(line/column, column은 UTF-8 byte 기준)을
/// 원문 UTF-8 절대 offset으로 변환한다. DEVELOPMENT.md §3.
package struct UTF8LineMap: Sendable {
    /// 각 line(1-based)의 시작 UTF-8 offset. index 0 == line 1.
    private let lineStartOffsets: [Int]
    /// 각 line의 줄 종결 문자(CR·LF·CRLF) 시작 offset. 마지막 줄에 종결 문자가 없으면 byteCount.
    private let lineEndOffsets: [Int]
    package let byteCount: Int

    package init(utf8 bytes: [UInt8]) {
        var starts = [0]
        var ends: [Int] = []
        starts.reserveCapacity(64)
        for (i, byte) in bytes.enumerated() {
            if byte == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { ends.append(i); continue }
            if byte == 0x0A || byte == 0x0D {
                if !(byte == 0x0A && i > 0 && bytes[i - 1] == 0x0D) { ends.append(i) }
                starts.append(i + 1)
            }
        }
        ends.append(bytes.count)
        self.lineStartOffsets = starts
        self.lineEndOffsets = ends
        self.byteCount = bytes.count
    }

    /// 1-based line의 시작 offset.
    package func lineStart(_ line: Int) -> Int? {
        line >= 1 && line <= lineStartOffsets.count ? lineStartOffsets[line - 1] : nil
    }

    /// offset이 속한 1-based line.
    package func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= offset { low = mid } else { high = mid }
        }
        return low + 1
    }

    /// 1-based line의 줄 종결 문자 시작 offset (내용 끝).
    package func lineEnd(_ line: Int) -> Int? {
        line >= 1 && line <= lineEndOffsets.count ? lineEndOffsets[line - 1] : nil
    }

    /// 1-based line/column → 0-based UTF-8 offset. 범위 밖이면 nil.
    package func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStartOffsets.count, column >= 1 else { return nil }
        let start = lineStartOffsets[line - 1]
        let columnOffset = column - 1
        guard columnOffset <= byteCount - start else { return nil }
        return start + columnOffset
    }
}

/// swift-cmark 0.8의 인라인 sourcepos 보정 (2026-10-14 퍼즈 패리티로 발견). 블록 위치는 정확하지만 인라인 위치는
/// 다음처럼 틀리게 보고된다. 원문 slice가 어긋나 끝 글자가 사라지거나 수식 가림 문자(xxxxx)가 새고 한글이 잘렸다.
/// ① 연속 줄은 "내용이 블록 시작 열에서 시작한다"고 가정한다 — 앞 공백을 떼어 낸 줄은 왼쪽으로, 게으른 줄은 오른쪽으로 밀린다.
/// ② 역슬래시 줄바꿈(`\`+줄 끝) 뒤 글자는 같은 줄의 열로 이어 세고(줄 종결 문자는 1바이트로 센다),
///    그 문단의 이후 줄 번호는 역슬래시 줄바꿈 수만큼 앞당겨진다.
/// 보정 순서: 보고 줄 → 실제 줄(②의 지연) → 그 줄의 열 밀림(①) → 줄 끝을 넘는 열은 다음 줄로 이어 셈(②).
package struct InlineColumnShift: Sendable {
    private let lineLag: [Int: Int]
    private let shiftByLine: [Int: Int]
    /// `\|`가 있는 표 줄 → (셀 경계 `|`의 열, `\|` 역슬래시의 열). cmark-gfm 표 확장은 셀 문자열에서 `\|`의 역슬래시를 지운 뒤
    /// 인라인을 파싱하고 위치를 "셀 시작 열 + 지운 문자열 안의 오프셋"으로 보고한다. 같은 셀에서 `\|` 뒤 위치는 그 개수만큼
    /// 앞당겨져 끝 글자가 잘렸다(퍼즈 10만 회: `| \(x^2\|제곱 |` → `\(x^2|제�`). 다음 셀은 영향이 없다.
    private let tablePipeEscapes: [Int: (boundaries: [Int], escapes: [Int])]
    private let lineMap: UTF8LineMap
    private let bytes: [UInt8]

    /// - Parameter parsedBytes: `document`를 만든 문자열의 바이트. 2차 파싱은 수식을 `x`로 가린 버퍼를 파싱하므로 표 셀의 `\|`는
    ///   그 버퍼에서 센다(가려진 수식 안의 `\|`는 표 확장이 보지 못한다). 생략하면 `bytes`.
    package init(document: Markup, lineMap: UTF8LineMap, bytes: [UInt8], parsedBytes: [UInt8]? = nil) {
        self.lineMap = lineMap
        self.bytes = bytes
        let lag = Self.backslashBreakLag(document: document, lineMap: lineMap, bytes: bytes)
        self.lineLag = lag
        var firstColumn: [Int: Int] = [:]
        var inlineStarts: [Int: [Int]] = [:]
        var continuationBase: [Int: Int] = [:]
        // 앞 줄에서 시작한 인라인 노드(여러 줄 코드 span·강조)가 덮는 줄. 그 줄의 첫 노드는 줄 머리에 있지 않다.
        var coveredLines = Set<Int>()
        // 표 둘째 줄 이후 → 표 시작 열. cmark-gfm 표 확장은 행 위치를 "표 시작 열 + 그 줄의 들여쓰기를 뺀 오프셋"으로
        // 보고한다. 머리글만 들여쓰면 이후 행이 그만큼 밀려 셀 글자가 한 칸씩 어긋났다(퍼즈 10만 회, `\(x\)`의 `\` 손실).
        var tableBase: [Int: Int] = [:]
        // 표 줄의 `\|`(→ tablePipeEscapes), 다른 리프 블록이 시작하는 줄(setext 제목 범위가 다음 줄의 목록 항목까지
        // 보고되는 경우 그 줄은 앞 블록의 연속 줄이 아니다).
        var pipeEscapes: [Int: (boundaries: [Int], escapes: [Int])] = [:]
        var leafStarts = Set<Int>()
        let parsed = parsedBytes ?? bytes
        func collectPipeEscapes(line: Int) {
            guard let start = lineMap.lineStart(line), let end = lineMap.lineEnd(line) else { return }
            var boundaries: [Int] = [], escapes: [Int] = []
            var offset = start
            while offset < end {
                if parsed[offset] == 0x5C, offset + 1 < end, parsed[offset + 1] == 0x7C {
                    escapes.append(offset - start + 1)
                    offset += 2
                    continue
                }
                if parsed[offset] == 0x7C { boundaries.append(offset - start + 1) }
                offset += 1
            }
            if !escapes.isEmpty { pipeEscapes[line] = (boundaries, escapes) }
        }
        // 트리를 한 번만 돈다. swift-markdown 트리 순회는 노드마다 값을 새로 만들어 비싸다(순회 네 번이 50 KiB 파싱 시간의
        // 절반이었다). 인라인 노드는 문단·제목·표 셀 아래에만 있으므로 `is InlineMarkup` 프로토콜 캐스트 대신 위치로 판단한다.
        func visit(_ markup: Markup, inline: Bool) {
            if let range = markup.range {
                if inline {
                    let line = range.lowerBound.line + (lag[range.lowerBound.line] ?? 0)
                    let upperLine = range.upperBound.line + (lag[range.upperBound.line] ?? 0)
                    inlineStarts[line, default: []].append(range.lowerBound.column)
                    if upperLine > line { coveredLines.formUnion((line + 1)...upperLine) }
                } else if markup is Paragraph || markup is Heading {
                    leafStarts.insert(range.lowerBound.line)
                    if range.upperBound.line > range.lowerBound.line {
                        for line in (range.lowerBound.line + 1)...range.upperBound.line {
                            continuationBase[line] = range.lowerBound.column
                        }
                    }
                } else if markup is Table {
                    leafStarts.insert(range.lowerBound.line)
                    if range.upperBound.line > range.lowerBound.line {
                        for line in (range.lowerBound.line + 1)...range.upperBound.line {
                            tableBase[line] = range.lowerBound.column
                        }
                    }
                    for line in range.lowerBound.line...range.upperBound.line { collectPipeEscapes(line: line) }
                } else if markup is CodeBlock || markup is HTMLBlock || markup is ThematicBreak {
                    leafStarts.insert(range.lowerBound.line)
                }
            }
            let inlineChildren = inline || markup is Paragraph || markup is Heading || markup is Table.Cell
            for child in markup.children { visit(child, inline: inlineChildren) }
        }
        visit(document, inline: false)
        tablePipeEscapes = pipeEscapes
        for line in leafStarts { continuationBase[line] = nil }
        // 역슬래시 줄바꿈 뒤 글자는 같은 줄의 열로 이어 세어져 그 줄 내용을 넘는다. 그 위치는 다음 줄의 것이므로 이 줄의
        // 첫 노드로 세지 않는다(`\`만 있는 줄에 엉뚱한 밀림이 생겨 `\]`가 `]`로 보였다, 퍼즈 10만 회).
        // 블록 첫 줄은 원문 줄 끝(줄 끝 문자 위치 포함)을, `\`로 끝나는 연속 줄은 앞 공백·`>`를 뗀 내용 길이를 넘는지 본다
        // (cmark는 연속 줄의 앞 공백을 떼고 블록 시작 열부터 센다). 다른 연속 줄은 게으른 줄과 구분할 수 없어 그대로 둔다.
        for (line, columns) in inlineStarts {
            guard let lineStart = lineMap.lineStart(line), let lineEnd = lineMap.lineEnd(line) else { continue }
            let valid: [Int]
            if let base = continuationBase[line] {
                if lineEnd > lineStart, bytes[lineEnd - 1] == 0x5C {
                    var contentStart = lineStart
                    while contentStart < lineEnd, bytes[contentStart] == 0x20 || bytes[contentStart] == 0x09 || bytes[contentStart] == 0x3E { contentStart += 1 }
                    valid = columns.filter { $0 <= base + (lineEnd - contentStart) - 1 }
                } else {
                    valid = columns
                }
            } else {
                valid = columns.filter { column in lineMap.offset(line: line, column: column).map { $0 < lineEnd } ?? false }
            }
            if let first = valid.min() { firstColumn[line] = first }
        }
        var shifts: [Int: Int] = [:]
        for line in Set(firstColumn.keys).union(continuationBase.keys).union(tableBase.keys) {
            guard let lineStart = lineMap.lineStart(line) else { continue }
            if let base = tableBase[line] {
                // 행의 내용은 앞 공백·탭과 인용 표식 `>` 뒤에서 시작한다. 보고 열은 그 시작이 표 시작 열에 있다고 본 값이다.
                var offset = lineStart
                while offset < bytes.count, bytes[offset] == 0x20 || bytes[offset] == 0x09 || bytes[offset] == 0x3E { offset += 1 }
                let actual = offset - lineStart + 1
                if actual != base { shifts[line] = actual - base }
            } else if let base = continuationBase[line] {
                // 연속 줄의 내용은 앞 공백·탭과 인용 표식 `>` 뒤에서 시작한다(문단 연속 줄은 `>`로 시작할 수 없다).
                var offset = lineStart
                while offset < bytes.count, bytes[offset] == 0x20 || bytes[offset] == 0x09 || bytes[offset] == 0x3E { offset += 1 }
                let actual = offset - lineStart + 1
                // 기준은 그 줄 첫 인라인 노드의 보고 열이다(게으른 줄은 블록 시작 열 + 앞 공백 수로 보고된다).
                // 앞 줄에서 이어진 노드가 줄 머리를 덮으면 첫 노드가 줄 머리에 없으므로 블록 시작 열을 쓴다.
                let reported = coveredLines.contains(line) ? base : (firstColumn[line] ?? base)
                if actual != reported { shifts[line] = actual - reported }
            } else if let column = firstColumn[line], var offset = lineMap.offset(line: line, column: column) {
                // 블록 첫 줄은 보고 위치가 맞거나 떼어 낸 공백 위를 가리킨다.
                while offset < bytes.count, bytes[offset] == 0x20 || bytes[offset] == 0x09 { offset += 1 }
                let actual = offset - lineStart + 1
                if actual != column { shifts[line] = actual - column }
            }
        }
        shiftByLine = shifts
    }

    /// 문단·제목마다 역슬래시 줄바꿈 뒤로 밀린 보고 줄 → 지연 줄 수. 줄바꿈의 실제 줄은 앞 노드 끝 위치로 찾고,
    /// 그 줄 내용의 마지막 바이트가 `\`이면 역슬래시 줄바꿈이다(두 칸 공백 줄바꿈은 줄 번호가 정확하다).
    private static func backslashBreakLag(document: Markup, lineMap: UTF8LineMap, bytes: [UInt8]) -> [Int: Int] {
        var lag: [Int: Int] = [:]
        func visitBlock(_ markup: Markup) {
            if markup is Paragraph || markup is Heading, let blockRange = markup.range {
                // 역슬래시 줄바꿈은 `\`로 끝나는 줄에만 있다. 그런 줄이 없는 블록은 인라인을 돌 필요가 없다.
                let hasBackslashLineEnd = (blockRange.lowerBound.line...blockRange.upperBound.line).contains { line in
                    guard let lineEnd = lineMap.lineEnd(line), lineEnd > 0 else { return false }
                    return bytes[lineEnd - 1] == 0x5C
                }
                guard hasBackslashLineEnd else { return }
                var breakLines: [Int] = []
                // 문단이 `\\` 한 줄로 시작하면 앞 노드가 없다. 그때는 블록 시작 위치를 앞 노드 끝으로 본다.
                var lastEnd: (line: Int, column: Int)? = (blockRange.lowerBound.line, blockRange.lowerBound.column)
                var atBlockStart = true
                // 앞 노드 끝 뒤에 지나간 줄바꿈 수. 부드러운 줄바꿈 다음 줄이 `\`만 있는 줄이면 그 줄이 역슬래시 줄바꿈이다.
                var linesSinceEnd = 0
                func walk(_ node: Markup) {
                    if node is LineBreak, let end = lastEnd {
                        let delayed = breakLines.filter { $0 < end.line }.count
                        var offset = lineMap.offset(line: end.line + delayed, column: end.column) ?? 0
                        var line = end.line + delayed
                        while let lineEnd = lineMap.lineEnd(line), offset > lineEnd, let next = lineMap.lineStart(line + 1) {
                            offset += (next - lineEnd) - 1
                            line += 1
                        }
                        // 앞 노드의 끝(배타)이면 그 직전 글자의 줄, 문단 머리면 그 줄 자체를 본다. 그 뒤 지나간 줄바꿈만큼 내려간다.
                        let breakLine = lineMap.line(containing: atBlockStart ? offset : max(offset - 1, 0)) + linesSinceEnd
                        if let lineEnd = lineMap.lineEnd(breakLine), lineEnd > 0, bytes[lineEnd - 1] == 0x5C {
                            breakLines.append(end.line + linesSinceEnd)
                        }
                        linesSinceEnd += 1
                    } else if node is SoftBreak {
                        linesSinceEnd += 1
                    }
                    if let range = node.range {  // 문단·제목의 자손은 모두 인라인 노드다
                        lastEnd = (range.upperBound.line, range.upperBound.column)
                        linesSinceEnd = 0
                        atBlockStart = false
                    }
                    if node is LineBreak || node is SoftBreak { atBlockStart = false }
                    for child in node.children { walk(child) }
                }
                for child in markup.children { walk(child) }
                if !breakLines.isEmpty {
                    for line in blockRange.lowerBound.line...blockRange.upperBound.line {
                        let count = breakLines.filter { $0 < line }.count
                        if count > 0 { lag[line] = count }
                    }
                }
                return
            }
            // 표 아래(머리·행·셀)에는 문단·제목이 없다. 셀의 인라인까지 내려가지 않는다.
            if markup is Table { return }
            for child in markup.children { visitBlock(child) }
        }
        visitBlock(document)
        return lag
    }

    /// 줄 머리의 공백·탭·인용 표식 `>` 길이.
    private func prefixLength(line: Int) -> Int {
        guard let start = lineMap.lineStart(line) else { return 0 }
        var offset = start
        while offset < bytes.count, bytes[offset] == 0x20 || bytes[offset] == 0x09 || bytes[offset] == 0x3E { offset += 1 }
        return offset - start
    }

    /// 인라인 노드의 1-based line/column을 원문 UTF-8 offset으로 바꾼다.
    package func offset(line reportedLine: Int, column: Int) -> Int? {
        let line = reportedLine + (lineLag[reportedLine] ?? 0)
        var shifted = column + (shiftByLine[line] ?? 0)
        if let table = tablePipeEscapes[line] {
            // 보고 열이 든 셀의 시작(앞 경계 `|` 다음 열)부터, 실제 위치 앞에 있는 `\|`마다 한 칸씩 되돌린다.
            let cellStart = (table.boundaries.last { $0 < shifted } ?? 0) + 1
            for escape in table.escapes where escape >= cellStart {
                guard escape < shifted else { break }
                shifted += 1
            }
        }
        guard var offset = lineMap.offset(line: line, column: shifted) else { return nil }
        var current = line
        while let end = lineMap.lineEnd(current), offset > end, let next = lineMap.lineStart(current + 1), next > end {
            // cmark는 줄 종결 문자를 1바이트로 센다. CRLF면 실제로는 2바이트라 그 차이만큼 뒤로 민다.
            offset += (next - end) - 1
            current += 1
            // 다음 줄 앞에서 떼어 낸 공백·탭·`>`도 세지 않는다(`a\\\n  b` → b의 위치가 공백 앞으로 보고됨).
            offset += prefixLength(line: current)
        }
        return min(offset, lineMap.byteCount)
    }
}
