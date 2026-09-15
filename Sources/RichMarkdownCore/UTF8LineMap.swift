import Foundation

/// swift-markdown의 SourceLocation(line/column, column은 UTF-8 byte 기준)을
/// 원문 UTF-8 절대 offset으로 변환한다. DEVELOPMENT.md §3.
package struct UTF8LineMap: Sendable {
    /// 각 line(1-based)의 시작 UTF-8 offset. index 0 == line 1.
    private let lineStartOffsets: [Int]
    package let byteCount: Int

    package init(utf8 bytes: [UInt8]) {
        var starts = [0]
        starts.reserveCapacity(64)
        for (i, b) in bytes.enumerated() where b == 0x0A {
            starts.append(i + 1)
        }
        self.lineStartOffsets = starts
        self.byteCount = bytes.count
    }

    /// 1-based line/column → 0-based UTF-8 offset. 범위 밖이면 nil.
    package func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStartOffsets.count, column >= 1 else { return nil }
        let offset = lineStartOffsets[line - 1] + (column - 1)
        guard offset <= byteCount else { return nil }
        return offset
    }
}
