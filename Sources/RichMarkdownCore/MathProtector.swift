import Foundation

/// byte-length-preserving mask. DEVELOPMENT.md §3 보호 버퍼.
///
/// 수식 span의 각 non-newline UTF-8 byte를 ASCII `x` 한 byte로 바꾼다.
/// LF/CRLF는 그대로 둔다. 보호 버퍼와 원문의 UTF-8 byte 길이가 항상 같으므로
/// 2차 AST range를 offset 변환 없이 원문 range로 사용할 수 있다.
package enum MathProtector {
    package static func protect(bytes: [UInt8], spans: [ProtectedMathSpan]) -> [UInt8] {
        var masked = bytes
        for span in spans {
            for i in span.originalUTF8Range where masked[i] != 0x0A && masked[i] != 0x0D {
                masked[i] = UInt8(ascii: "x")
            }
        }
        return masked
    }

    /// `restore(protect(source)) == source`를 byte 단위로 보장한다.
    package static func restore(masked: [UInt8], original: [UInt8], spans: [ProtectedMathSpan]) -> [UInt8] {
        precondition(masked.count == original.count, "mask는 byte 길이를 보존해야 한다")
        var restored = masked
        for span in spans {
            for i in span.originalUTF8Range {
                restored[i] = original[i]
            }
        }
        return restored
    }
}
