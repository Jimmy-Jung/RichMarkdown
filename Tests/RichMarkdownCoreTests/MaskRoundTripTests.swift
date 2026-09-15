import Testing
@testable import RichMarkdownCore

/// byte-length-preserving mask와 protect/restore round-trip (DEVELOPMENT.md §3, §8).
@Suite struct MaskRoundTripTests {

    private func scan(_ text: String, dollar: Bool = false) -> (bytes: [UInt8], spans: [ProtectedMathSpan]) {
        let bytes = Array(text.utf8)
        let scanner = MathScanner(
            bytes: bytes,
            forbiddenRanges: [],
            paragraphRanges: [0..<bytes.count],
            parsesDollarMath: dollar
        )
        return (bytes, scanner.scan().spans)
    }

    @Test func maskPreservesByteLengthAndNewlines() {
        let text = "앞 \\(a+b\\) 뒤\n\\(c\\) 끝"
        let (bytes, spans) = scan(text)
        #expect(!spans.isEmpty)
        let masked = MathProtector.protect(bytes: bytes, spans: spans)
        #expect(masked.count == bytes.count)
        for (i, b) in bytes.enumerated() where b == 0x0A || b == 0x0D {
            #expect(masked[i] == b, "newline byte는 유지되어야 한다")
        }
        for span in spans {
            for i in span.originalUTF8Range where bytes[i] != 0x0A && bytes[i] != 0x0D {
                #expect(masked[i] == UInt8(ascii: "x"))
            }
        }
    }

    @Test func restoreProtectRoundTripIsExact() {
        let text = "한글 \\(x_[i]\\) 🙂 \\[전체\\] 아님 $a$"
        let (bytes, spans) = scan(text, dollar: true)
        let masked = MathProtector.protect(bytes: bytes, spans: spans)
        let restored = MathProtector.restore(masked: masked, original: bytes, spans: spans)
        #expect(restored == bytes, "restore(protect(source)) == source")
    }

    @Test func spanSourceMatchesOriginalSlice() {
        let text = "이모지🙂와 결합e\u{301} 문자 \\(f(x) = x^2\\) RTLעברית"
        let (bytes, spans) = scan(text)
        for span in spans {
            #expect(String(decoding: bytes[span.originalUTF8Range], as: UTF8.self) == span.source)
        }
    }

    /// seeded fuzz: 임의 다국어 문자열에서 mask 길이 보존과 round-trip을 확인한다.
    @Test func fuzzRoundTrip() {
        var rng = SplitMix64(seed: 0x5EED)
        let alphabet: [String] = [
            "a", "한", "🙂", "\\", "(", ")", "[", "]", "$", " ", "\n", "*", "_", "`", "e\u{301}", "ע",
        ]
        for _ in 0..<300 {
            let length = Int(rng.next() % 60) + 1
            var text = ""
            for _ in 0..<length {
                text += alphabet[Int(rng.next() % UInt64(alphabet.count))]
            }
            let bytes = Array(text.utf8)
            let scanner = MathScanner(
                bytes: bytes,
                forbiddenRanges: [],
                paragraphRanges: [0..<bytes.count],
                parsesDollarMath: true
            )
            let spans = scanner.scan().spans
            let masked = MathProtector.protect(bytes: bytes, spans: spans)
            #expect(masked.count == bytes.count)
            let restored = MathProtector.restore(masked: masked, original: bytes, spans: spans)
            #expect(restored == bytes)
            let sorted = spans.map(\.originalUTF8Range).sorted { $0.lowerBound < $1.lowerBound }
            for pair in zip(sorted, sorted.dropFirst()) {
                #expect(pair.0.upperBound <= pair.1.lowerBound, "span은 겹치지 않는다")
            }
        }
    }

    /// 다국어 수식 앞뒤의 source range가 그대로 유지되는 property test (§3 필수).
    @Test func multilingualSurroundingRangesPreserved() {
        let prefix = "한글🙂 앞부분 "
        let math = "\\(x+y\\)"
        let suffix = " עברית 뒤"
        let (bytes, spans) = scan(prefix + math + suffix)
        #expect(spans.count == 1)
        guard let span = spans.first else { return }
        #expect(span.originalUTF8Range.lowerBound == prefix.utf8.count)
        #expect(span.originalUTF8Range.upperBound == prefix.utf8.count + math.utf8.count)
        let masked = MathProtector.protect(bytes: bytes, spans: spans)
        #expect(Array(masked[0..<span.originalUTF8Range.lowerBound]) == Array(bytes[0..<span.originalUTF8Range.lowerBound]))
        #expect(Array(masked[span.originalUTF8Range.upperBound...]) == Array(bytes[span.originalUTF8Range.upperBound...]))
    }
}

/// 재현 가능한 fuzz용 PRNG.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
