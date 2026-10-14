import Foundation

/// DEVELOPMENT.md §6 입력 보호.
/// 원문 UTF-8 byte·block quote 깊이 상한은 첫 `Document(parsing:)` 전에 검사한다.
/// 초과 시 내부 표시 상한까지 `Character` 경계로 자르고 marker를 붙인다.
package enum InputLimits {
    // ponytail: 상한 수치는 P0 adversarial fixture/측정 전 잠정값. v1 공개 API로 고정하지 않는다.
    package static let maxInputUTF8Bytes = 262_144        // 256 KiB
    package static let displayPrefixUTF8Bytes = 65_536    // 초과 시 표시 상한 64 KiB
    package static let maxBlockQuoteDepth = 64
    /// 목록 항목 표식 앞 들여쓰기 열 상한(탭 = 4열). 목록은 들여쓰기로 중첩되고 swift-markdown 변환이 재귀라
    /// 깊이에 비례해 스택을 쓴다. 실측(2026-10-14, 협력 스레드 512 KB 스택): 56단계 통과, 65단계 SIGBUS → 48열(2칸 들여쓰기
    /// 기준 24단계)로 제한해 2배 이상 여유를 둔다 (fixture pathological/nested-list-24·26·500).
    package static let maxListIndentColumns = 48
    package static let maxMathSourceUTF8Bytes = 4_096     // 수식 parser 진입 전 source 상한
    package static let maxTableColumns = 32
    package static let maxTableCells = 512
    package static let truncationMarker = "… [입력 제한 초과]"

    package struct BoundedInput: Sendable, Equatable {
        package let text: String
        package let wasTruncated: Bool

        package init(text: String, wasTruncated: Bool) {
            self.text = text
            self.wasTruncated = wasTruncated
        }
    }

    /// 상한 초과 입력을 Character 경계의 bounded prefix + 명시적 생략 marker로 바꾼다.
    package static func bound(_ input: String) -> BoundedInput {
        let byteBounded = boundUTF8Bytes(normalizedForParsing(input))
        guard let lineStart = firstLineExceedingNestingLimits(in: byteBounded.text) else {
            return byteBounded
        }

        return BoundedInput(
            text: truncatedText(prefix: String(byteBounded.text[..<lineStart])),
            wasTruncated: true
        )
    }

    /// 선두 BOM(U+FEFF)은 내용이 아니므로 버리고, NUL은 U+FFFD로 바꾼다. cmark는 NUL을 내부에서 U+FFFD(3바이트)로
    /// 치환하므로 그대로 두면 1차·2차 파싱의 UTF-8 offset이 어긋나 수식 mask가 복원되지 않는다 (fixture security/null-and-control-chars).
    private static func normalizedForParsing(_ input: String) -> String {
        var text = input
        while text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.utf8.contains(0) { text = text.replacingOccurrences(of: "\0", with: "\u{FFFD}") }
        return text
    }

    private static func boundUTF8Bytes(_ input: String) -> BoundedInput {
        let utf8 = input.utf8
        guard let limit = utf8.index(
            utf8.startIndex,
            offsetBy: maxInputUTF8Bytes,
            limitedBy: utf8.endIndex
        ), limit != utf8.endIndex else {
            return BoundedInput(text: input, wasTruncated: false)
        }

        var end = input.startIndex
        var byteCount = 0
        var index = input.startIndex
        while index < input.endIndex {
            let next = input.index(after: index)
            let charBytes = input[index..<next].utf8.count
            if byteCount + charBytes > displayPrefixUTF8Bytes { break }
            byteCount += charBytes
            index = next
            end = index
        }
        return BoundedInput(text: truncatedText(prefix: String(input[..<end])), wasTruncated: true)
    }

    /// Block quote와 목록은 swift-markdown 변환과 내부 모델 모두 재귀로 처리하므로 parse 전에 깊이를 제한한다.
    package static func firstLineExceedingNestingLimits(in input: String) -> String.Index? {
        var lineStart = input.startIndex
        var openFence: CodeFence?

        while lineStart < input.endIndex {
            let lineEnd = lineTerminator(in: input, from: lineStart) ?? input.endIndex
            let line = input[lineStart..<lineEnd]
            let quotePrefix = quotePrefix(in: line)

            if let fence = openFence {
                if quotePrefix.depth < fence.quoteDepth {
                    // quote container를 벗어나면 그 안에서 열었던 fence도 끝난다. 같은 줄을
                    // 일반 Markdown으로 재처리해 이후 깊은 quote 제한을 우회하지 못하게 한다.
                    openFence = nil
                } else {
                    // fenced code 안의 `>`는 코드 문자일 뿐이라 block quote 재귀를 만들지 않는다.
                    // 같은 quote container에서만 닫는 fence로 인정해 코드 본문의 `> ``` `를
                    // 조기 종료로 오인하지 않는다.
                    if quotePrefix.depth == fence.quoteDepth,
                       closesFence(in: line[quotePrefix.contentStart...], matching: fence) {
                        openFence = nil
                    }
                    lineStart = nextLineStart(after: lineEnd, in: input)
                    continue
                }
            }

            // opening fence가 깊은 quote 안에 있더라도 parser는 먼저 quote container를
            // 재귀로 만든다. 따라서 fence 판정보다 앞에서 depth를 제한해야 한다.
            if quotePrefix.depth > maxBlockQuoteDepth {
                return lineStart
            }
            if listMarkerIndentColumns(in: line[quotePrefix.contentStart...]) > maxListIndentColumns {
                return lineStart
            }
            if let fence = openingFence(
                in: line[quotePrefix.contentStart...],
                quoteDepth: quotePrefix.depth
            ) {
                openFence = fence
            }
            lineStart = nextLineStart(after: lineEnd, in: input)
        }
        return nil
    }

    /// CR, LF, CRLF를 모두 한 줄 종료로 취급한다. CommonMark input은 세 형식을 모두
    /// 허용하므로 LF만 찾으면 depth 제한과 fence 종료가 우회될 수 있다.
    private static func lineTerminator(in input: String, from start: String.Index) -> String.Index? {
        input[start...].firstIndex(where: \.isNewline)
    }

    private static func nextLineStart(after terminator: String.Index, in input: String) -> String.Index {
        guard terminator < input.endIndex else { return input.endIndex }
        // Swift `Character`는 CRLF를 하나의 extended grapheme cluster로 다룬다.
        // 따라서 한 번 전진하면 CR, LF, CRLF 모두 정확히 다음 logical line을 가리킨다.
        return input.index(after: terminator)
    }

    /// 줄이 목록 표식(`-`·`+`·`*`, 또는 1~9자리 숫자 뒤 `.`·`)`)으로 시작하면 그 앞 들여쓰기 열 수(탭 = 4열), 아니면 0.
    private static func listMarkerIndentColumns(in content: Substring) -> Int {
        var columns = 0
        var index = content.startIndex
        while index < content.endIndex {
            if content[index] == " " { columns += 1 } else if content[index] == "\t" { columns += 4 - columns % 4 } else { break }
            index = content.index(after: index)
        }
        guard columns > 0, index < content.endIndex, startsWithListMarker(content[index...]) else { return 0 }
        return columns
    }

    private static func startsWithListMarker(_ text: Substring) -> Bool {
        guard let first = text.first else { return false }
        var afterMarker = text.index(after: text.startIndex)
        if first.isASCII, first.isNumber {
            var digits = 1
            while afterMarker < text.endIndex, text[afterMarker].isASCII, text[afterMarker].isNumber, digits < 9 {
                digits += 1
                afterMarker = text.index(after: afterMarker)
            }
            guard afterMarker < text.endIndex, text[afterMarker] == "." || text[afterMarker] == ")" else { return false }
            afterMarker = text.index(after: afterMarker)
        } else if first != "-", first != "+", first != "*" {
            return false
        }
        return afterMarker == text.endIndex || text[afterMarker] == " " || text[afterMarker] == "\t"
    }

    private struct QuotePrefix {
        let depth: Int
        let contentStart: String.Index
    }

    private struct CodeFence {
        let character: Character
        let length: Int
        let quoteDepth: Int
    }

    private struct FenceMarker {
        let character: Character
        let length: Int
        let suffixStart: String.Index
    }

    private static func quotePrefix(in line: Substring) -> QuotePrefix {
        var index = line.startIndex
        var depth = 0

        while index < line.endIndex {
            var candidate = index
            var spaces = 0
            while candidate < line.endIndex, line[candidate] == " ", spaces < 4 {
                spaces += 1
                candidate = line.index(after: candidate)
            }
            guard spaces < 4, candidate < line.endIndex, line[candidate] == ">" else { break }

            depth += 1
            index = line.index(after: candidate)
            if index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
        }

        return QuotePrefix(depth: depth, contentStart: index)
    }

    private static func openingFence(in content: Substring, quoteDepth: Int) -> CodeFence? {
        guard let marker = fenceMarker(in: content) else { return nil }

        // CommonMark의 backtick info string에는 backtick을 다시 쓸 수 없다. 이 경우를
        // fence로 오인해 남은 입력의 depth 검사를 건너뛰면 안 된다.
        if marker.character == "`", content[marker.suffixStart...].contains("`") {
            return nil
        }
        return CodeFence(
            character: marker.character,
            length: marker.length,
            quoteDepth: quoteDepth
        )
    }

    private static func closesFence(in content: Substring, matching fence: CodeFence) -> Bool {
        guard let marker = fenceMarker(in: content),
              marker.character == fence.character,
              marker.length >= fence.length
        else {
            return false
        }
        return content[marker.suffixStart...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 최대 3 spaces 뒤에 오는 3개 이상 backtick/tilde fence만 인식한다.
    private static func fenceMarker(in content: Substring) -> FenceMarker? {
        var index = content.startIndex
        var indentation = 0
        while index < content.endIndex, content[index] == " ", indentation < 3 {
            indentation += 1
            index = content.index(after: index)
        }

        guard index < content.endIndex,
              content[index] == "`" || content[index] == "~"
        else {
            return nil
        }

        let character = content[index]
        var length = 0
        while index < content.endIndex, content[index] == character {
            length += 1
            index = content.index(after: index)
        }
        guard length >= 3 else { return nil }
        return FenceMarker(character: character, length: length, suffixStart: index)
    }

    private static func truncatedText(prefix: String) -> String {
        prefix + "\n\n" + truncationMarker
    }
}
