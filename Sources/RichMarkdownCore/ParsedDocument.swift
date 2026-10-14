import Foundation

/// RichMarkdownCore의 package-private 내부 모델. 공개 AST product가 아니다 (DEVELOPMENT.md §1 비목표).
package struct ParsedDocument: Sendable, Hashable {
    package var blocks: [ParsedBlock]
    package var wasTruncated: Bool
    package var diagnostics: [MathDiagnostic]

    package init(blocks: [ParsedBlock], wasTruncated: Bool = false, diagnostics: [MathDiagnostic] = []) {
        self.blocks = blocks
        self.wasTruncated = wasTruncated
        self.diagnostics = diagnostics
    }

    /// hydration 대상 수식 segment (문서 순서, 중복 제거).
    package var allMathSegments: [MathSegment] {
        var seen = Set<MathSegment>()
        var ordered: [MathSegment] = []
        func visit(_ blocks: [ParsedBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let runs), .heading(_, let runs):
                    for run in runs {
                        if case .math(let segment) = run.content, seen.insert(segment).inserted {
                            ordered.append(segment)
                        }
                    }
                case .blockMath(let segment):
                    if seen.insert(segment).inserted { ordered.append(segment) }
                case .blockQuote(let children):
                    visit(children)
                case .unorderedList(let items):
                    items.forEach(visit)
                case .orderedList(_, let items):
                    items.forEach(visit)
                case .table(let table):
                    for runs in table.header + table.rows.flatMap({ $0 }) {
                        for run in runs {
                            if case .math(let segment) = run.content, seen.insert(segment).inserted {
                                ordered.append(segment)
                            }
                        }
                    }
                case .codeBlock, .thematicBreak:
                    break
                }
            }
        }
        visit(blocks)
        return ordered
    }
}

package enum ParsedBlock: Sendable, Hashable {
    case paragraph([InlineRun])
    case heading(level: Int, runs: [InlineRun])
    case codeBlock(language: String?, code: String)
    case blockMath(MathSegment)
    case blockQuote([ParsedBlock])
    case unorderedList(items: [[ParsedBlock]])
    case orderedList(start: Int, items: [[ParsedBlock]])
    case table(ParsedTable)
    case thematicBreak
}

package struct ParsedTable: Sendable, Hashable {
    package enum ColumnAlignment: Sendable, Hashable {
        case left
        case center
        case right
    }

    package let columnAlignments: [ColumnAlignment?]
    package let header: [[InlineRun]]
    package let rows: [[[InlineRun]]]
}

package struct MathSegment: Sendable, Hashable {
    /// 원래 구분자를 포함한 원문. 렌더 실패 시 이 값을 표시한다.
    package let source: String
    /// delimiter 제거 LaTeX.
    package let latex: String
    package let kind: MathKind

    package init(span: ProtectedMathSpan) {
        self.source = span.source
        self.latex = span.latex
        self.kind = span.kind
    }
}

package struct InlineRun: Sendable, Hashable {
    package enum Content: Sendable, Hashable {
        case text(String)
        case code(String)
        case math(MathSegment)
        case link(text: String, destination: URL)
        case hardBreak
        case softBreak
    }

    package var content: Content
    package var bold: Bool
    package var italic: Bool
    package var strikethrough: Bool

    package init(content: Content, bold: Bool = false, italic: Bool = false, strikethrough: Bool = false) {
        self.content = content
        self.bold = bold
        self.italic = italic
        self.strikethrough = strikethrough
    }
}

/// 자동 링크 allowlist. `https`, `http`, `mailto`만 허용 (DEVELOPMENT.md §5).
package enum LinkPolicy {
    /// iOS 17 이상 `URL(string:)`은 RFC 3986에 맞지 않는 구성 요소를 통째로 퍼센트 인코딩하고(그 안의 `%`도 `%25`),
    /// iOS 16은 nil을 돌려준다(fixture regressions/link-second-hash·security/link-percent-encoded, iOS 16.4 시뮬레이터 실측).
    /// 사용자 정보·경로·쿼리·조각에 같은 규칙을 적용해 OS 간 결과를 맞춘다. 호스트·포트는 인코딩하지 않아 깨진 호스트는
    /// 계속 실패한다. 다만 호스트의 비ASCII는 퍼센트 인코딩한다 — iOS 17은 punycode로 바꾸므로 표기만 다르다
    /// (패리티 예외 security/link-idn-homoglyph).
    package static func percentEncodingInvalidCharacters(_ text: String) -> String {
        var rest = Substring(text)
        var fragment: Substring?
        if let hash = rest.firstIndex(of: "#") {
            fragment = rest[rest.index(after: hash)...]
            rest = rest[..<hash]
        }
        var query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }
        var out = ""
        if let colon = rest.firstIndex(of: ":"), isScheme(rest[..<colon]) {
            out += rest[...colon]
            rest = rest[rest.index(after: colon)...]
            if rest.hasPrefix("//") {
                rest = rest.dropFirst(2)
                let end = rest.firstIndex(of: "/") ?? rest.endIndex
                let authority = rest[..<end]
                rest = rest[end...]
                out += "//"
                if let at = authority.lastIndex(of: "@") {
                    out += encoded(authority[..<at], allowing: userinfoCharacters) + "@"
                    out += encodingNonASCII(authority[authority.index(after: at)...])
                } else {
                    out += encodingNonASCII(authority)
                }
            }
        }
        out += encoded(rest, allowing: pathCharacters)
        if let query { out += "?" + encoded(query, allowing: queryCharacters) }
        if let fragment { out += "#" + encoded(fragment, allowing: queryCharacters) }
        return out
    }

    private static let unreservedAndSubDelims = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=".utf8)
    private static let userinfoCharacters = unreservedAndSubDelims.union(":".utf8)
    private static let pathCharacters = unreservedAndSubDelims.union(":@/".utf8)
    private static let queryCharacters = pathCharacters.union("?".utf8)

    private static func isScheme(_ text: Substring) -> Bool {
        guard let first = text.utf8.first, (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else { return false }
        return text.utf8.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }

    /// 구성 요소가 이미 규격에 맞으면(허용 글자와 올바른 `%XX`만) 그대로, 아니면 허용 글자 밖의 모든 바이트를 인코딩한다.
    private static func encoded(_ component: Substring, allowing allowed: Set<UInt8>) -> String {
        let bytes = Array(component.utf8)
        var index = 0
        var isValid = true
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) else {
                    isValid = false
                    break
                }
                index += 3
            } else if allowed.contains(bytes[index]) {
                index += 1
            } else {
                isValid = false
                break
            }
        }
        if isValid { return String(component) }
        return bytes.reduce(into: "") { out, byte in
            if allowed.contains(byte) { out.unicodeScalars.append(Unicode.Scalar(byte)) } else { out += String(format: "%%%02X", byte) }
        }
    }

    private static func encodingNonASCII(_ text: Substring) -> String {
        text.utf8.reduce(into: "") { out, byte in
            if byte < 0x80 { out.unicodeScalars.append(Unicode.Scalar(byte)) } else { out += String(format: "%%%02X", byte) }
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    package static let allowedSchemes: Set<String> = ["https", "http", "mailto"]

    /// 주소에 보이지 않는 서식 문자(너비 없는 문자 U+200B~U+200F, 방향 제어 U+202A~U+202E·U+2066~U+2069,
    /// U+2060~U+2064, BOM U+FEFF)가 있으면 링크로 만들지 않는다. 화면의 주소와 실제 이동 대상이 달라 보이게 하는
    /// 속임수를 막고, OS·플랫폼마다 이 문자를 지우거나 남기는 차이(퍼즈 패리티)를 없앤다. Android `LinkPolicy`와 같다.
    package static func containsInvisibleFormatCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: return true
            default: return false
            }
        }
    }

    package static func allowedURL(from destination: String?) -> URL? {
        guard let destination, !containsInvisibleFormatCharacter(destination),
              let url = URL(string: destination) ?? URL(string: percentEncodingInvalidCharacters(destination)),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme)
        else { return nil }
        // http·https는 호스트가 있어야 한다(`https:#//…` 같은 깨진 주소를 링크로 만들지 않는다, Android와 같다).
        if scheme != "mailto", (url.host ?? "").isEmpty { return nil }
        // 포트는 숫자만. iOS 16 파서는 `http://a.com:80[/p`를 `80%5B`로 받아들이지만 iOS 17 이상과 Android는 거부한다.
        guard hasNumericPort(destination) else { return nil }
        return url
    }

    /// `scheme://[userinfo@]host[:port]`의 포트 자리가 비었거나 숫자뿐인지. 권한 부분이 없으면 true.
    private static func hasNumericPort(_ destination: String) -> Bool {
        guard let start = destination.range(of: "://")?.upperBound else { return true }
        let rest = destination[start...]
        let authority = rest[..<(rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex)]
        var hostPort = authority[(authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex)...]
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            hostPort = hostPort[hostPort.index(after: close)...]
        }
        guard let colon = hostPort.lastIndex(of: ":") else { return true }
        return hostPort[hostPort.index(after: colon)...].allSatisfy { $0.isASCII && $0.isNumber }
    }
}
