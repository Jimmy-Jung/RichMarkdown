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
    package static let allowedSchemes: Set<String> = ["https", "http", "mailto"]

    package static func allowedURL(from destination: String?) -> URL? {
        guard let destination,
              let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }
}
