// Created by JunyoungJung on 2026-08-24.

import RichMarkdown
import UIKit

/// 블록 종류별 문단 정렬. 소비 앱이 주입해 기본값을 바꿀 수 있다.
public struct BlockAlignmentConfiguration: Equatable, Sendable {
    /// 코드 블록 정렬. 기본 좌측(`.natural` — RTL 로케일은 우측).
    public var code: NSTextAlignment
    /// 수식 블록 정렬. 기본 중앙.
    public var equation: NSTextAlignment

    public init(code: NSTextAlignment = .natural, equation: NSTextAlignment = .center) {
        self.code = code
        self.equation = equation
    }

    public static let `default` = BlockAlignmentConfiguration()
}

/// 블록 마커는 모델로 분리하고, 인라인 Markdown만 라이브 스타일링한다.
///
/// 폰트·색은 전부 `RichMarkdownTheme`에서 해석한다: 본문·목록·인용은 `bodyFont`,
/// 제목은 `headingFont(level:)`, 코드·수식·인라인 코드는 `codeFont`.
/// 코드·수식 블록의 정렬은 `BlockAlignmentConfiguration`으로 주입한다.
public enum MarkdownStyler {
    public static func baseAttributes(
        for kind: EditorBlockKind,
        theme: RichMarkdownTheme = .default,
        traitCollection: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: kind, theme: theme, traitCollection: traitCollection),
            // Notion처럼 인용문도 본문 색을 유지한다. 구분은 왼쪽 세로 바가 한다.
            .foregroundColor: UIColor(theme.textColor),
        ]
        if kind == .quote {
            attributes[.blockQuoteBar] = QuoteBarStyle(theme: theme)
        }
        if case let .toDo(isChecked) = kind {
            // 박스는 마커 글리프 대신 `ToDoCheckboxDecorationView`가 그린다.
            attributes[.toDoCheckbox] = ToDoCheckboxStyle(isChecked: isChecked)
            if isChecked {
                // Notion처럼 완료 항목은 흐린 색 + 취소선.
                attributes[.foregroundColor] = UIColor.secondaryLabel
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        return attributes
    }

    public static func typingAttributes(
        for block: EditorBlock?,
        theme: RichMarkdownTheme = .default,
        alignment: BlockAlignmentConfiguration = .default,
        traitCollection: UITraitCollection? = nil
    ) -> [NSAttributedString.Key: Any] {
        let block = block ?? EditorBlock(text: "")
        var attributes = baseAttributes(
            for: block.kind,
            theme: theme,
            traitCollection: traitCollection
        )
        attributes[.paragraphStyle] = paragraphStyle(
            for: block,
            numberedListOrdinal: 1,
            theme: theme,
            alignment: alignment,
            traitCollection: traitCollection
        )
        return attributes
    }

    public static func styledDocument(
        _ blocks: [EditorBlock],
        editingEquationIDs: Set<UUID> = [],
        parsesDollarMath: Bool = false,
        theme: RichMarkdownTheme = .default,
        alignment: BlockAlignmentConfiguration = .default,
        selection: NSRange? = nil,
        traitCollection: UITraitCollection? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var numberedCounts: [Int: Int] = [:]
        var previousKinds: [Int: EditorBlockKind] = [:]

        for (index, block) in blocks.enumerated() {
            let depth = block.indentLevel
            numberedCounts = numberedCounts.filter { $0.key <= depth }
            previousKinds = previousKinds.filter { $0.key <= depth }

            let ordinal: Int
            if block.kind == .numberedList {
                ordinal = previousKinds[depth] == .numberedList
                    ? (numberedCounts[depth] ?? 0) + 1
                    : 1
                numberedCounts[depth] = ordinal
            } else {
                ordinal = 1
                numberedCounts[depth] = 0
            }
            previousKinds[depth] = block.kind

            let start = result.length
            if block.kind == .equation,
               !editingEquationIDs.contains(block.id),
               !block.text.isEmpty {
                result.append(equationAttachment(
                    for: block,
                    theme: theme,
                    traitCollection: traitCollection
                ))
            } else {
                let localSelection = selection.flatMap {
                    selectionWithinBlock($0, blockStart: start, blockLength: block.text.utf16.count)
                }
                result.append(styled(
                    block,
                    parsesDollarMath: parsesDollarMath,
                    theme: theme,
                    selection: localSelection,
                    traitCollection: traitCollection
                ))
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: baseAttributes(
                        for: block.kind,
                        theme: theme,
                        traitCollection: traitCollection
                    )
                ))
            }
            let range = NSRange(location: start, length: result.length - start)
            if range.length > 0 {
                result.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(
                        for: block,
                        numberedListOrdinal: ordinal,
                        theme: theme,
                        alignment: alignment,
                        traitCollection: traitCollection
                    ),
                    range: range
                )
            }
        }

        assert(result.length == blocks.map(\.text).joined(separator: "\n").utf16.count)
        return result
    }

    public static func inlineMathRanges(
        in blocks: [EditorBlock],
        intersecting selection: NSRange,
        parsesDollarMath: Bool
    ) -> [NSRange] {
        var blockStart = 0
        var result: [NSRange] = []
        for (index, block) in blocks.enumerated() {
            let blockRange = NSRange(location: blockStart, length: block.text.utf16.count)
            if intersects(blockRange, selection: selection) {
                for span in inlineMathSpans(in: block, parsesDollarMath: parsesDollarMath) {
                    let documentRange = NSRange(
                        location: blockStart + span.range.location,
                        length: span.range.length
                    )
                    if intersects(documentRange, selection: selection) {
                        result.append(documentRange)
                    }
                }
            }
            blockStart += block.text.utf16.count
            if index < blocks.count - 1 { blockStart += 1 }
        }
        return result
    }

    public static func styled(
        _ block: EditorBlock,
        parsesDollarMath: Bool = false,
        theme: RichMarkdownTheme = .default,
        selection: NSRange? = nil,
        traitCollection: UITraitCollection? = nil
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: block.text,
            attributes: baseAttributes(
                for: block.kind,
                theme: theme,
                traitCollection: traitCollection
            )
        )
        guard !block.kind.preservesLineBreaks else { return text }
        let mono = theme.codeFont.resolvedUIFont(compatibleWith: traitCollection)

        for format in InlineFormat.allCases {
            for mark in block.inlineMarks where mark.format == format && mark.range.length > 0 {
                guard mark.range.location >= 0, NSMaxRange(mark.range) <= text.length else { continue }
                switch mark.format {
                case .bold:
                    applyFontTraits(.traitBold, range: mark.range, to: text)
                case .italic:
                    applyFontTraits(.traitItalic, range: mark.range, to: text)
                case .strikethrough:
                    text.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: mark.range
                    )
                case .code:
                    text.addAttribute(.font, value: mono, range: mark.range)
                    // 칩(둥근 배경+테두리)은 `.backgroundColor` 대신
                    // `InlineCodeDecorationView`가 이 attribute를 읽어 그린다.
                    text.addAttribute(
                        .foregroundColor,
                        value: UIColor(theme.inlineCodeForeground),
                        range: mark.range
                    )
                    text.addAttribute(
                        .inlineCodeChip,
                        value: InlineCodeChipStyle(theme: theme),
                        range: mark.range
                    )
                }
            }
        }

        let inlineMathSpans = inlineMathSpans(in: block, parsesDollarMath: parsesDollarMath)
        for span in inlineMathSpans where !intersects(span.range, selection: selection) {
            text.replaceCharacters(
                in: span.range,
                with: equationAttachment(
                    latex: span.latex,
                    source: span.source,
                    sourceLength: span.range.length,
                    kind: block.kind,
                    theme: theme,
                    isDisplay: false,
                    traitCollection: traitCollection
                )
            )
        }
        return text
    }

    private static func equationAttachment(
        for block: EditorBlock,
        theme: RichMarkdownTheme,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        equationAttachment(
            latex: block.text,
            source: block.text,
            sourceLength: block.text.utf16.count,
            kind: block.kind,
            theme: theme,
            isDisplay: true,
            traitCollection: traitCollection
        )
    }

    private static func equationAttachment(
        latex: String,
        source: String,
        sourceLength: Int,
        kind: EditorBlockKind,
        theme: RichMarkdownTheme,
        isDisplay: Bool,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        let attributes = baseAttributes(
            for: kind,
            theme: theme,
            traitCollection: traitCollection
        )
        let pointSize = (attributes[.font] as? UIFont)?.pointSize
            ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        let attachment = EquationTextAttachment(
            latex: latex,
            source: source,
            theme: theme,
            isDisplay: isDisplay,
            pointSize: pointSize
        )
        let result = NSMutableAttributedString(attachment: attachment)
        if sourceLength > 1 {
            result.append(NSAttributedString(
                string: String(repeating: "\u{2063}", count: sourceLength - 1)
            ))
        }
        result.addAttributes(
            attributes,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private static func inlineMathSpans(
        in block: EditorBlock,
        parsesDollarMath: Bool
    ) -> [LatexInlineMathSpan] {
        guard !block.kind.preservesLineBreaks else { return [] }
        let codeRanges = block.inlineMarks.compactMap { mark in
            mark.format == .code ? mark.range : nil
        }
        return LatexInlineMathScanner.scan(
            block.text,
            parsesDollarMath: parsesDollarMath,
            excluding: codeRanges
        )
    }

    private static func selectionWithinBlock(
        _ selection: NSRange,
        blockStart: Int,
        blockLength: Int
    ) -> NSRange? {
        let blockRange = NSRange(location: blockStart, length: blockLength)
        if selection.length == 0 {
            guard selection.location >= blockStart,
                  selection.location <= NSMaxRange(blockRange)
            else { return nil }
            return NSRange(location: selection.location - blockStart, length: 0)
        }
        let intersection = NSIntersectionRange(selection, blockRange)
        guard intersection.length > 0 else { return nil }
        return NSRange(
            location: intersection.location - blockStart,
            length: intersection.length
        )
    }

    private static func intersects(_ range: NSRange, selection: NSRange?) -> Bool {
        guard let selection else { return false }
        if selection.length == 0 {
            return selection.location >= range.location
                && selection.location < NSMaxRange(range)
        }
        return NSIntersectionRange(range, selection).length > 0
    }

    private static func paragraphStyle(
        for block: EditorBlock,
        numberedListOrdinal: Int,
        theme: RichMarkdownTheme,
        alignment: BlockAlignmentConfiguration,
        traitCollection: UITraitCollection?
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = block.kind == .paragraph ? 8 : 10
        if block.kind == .equation {
            style.paragraphSpacing += font(
                for: block.kind,
                theme: theme,
                traitCollection: traitCollection
            ).ascender
        }

        switch block.kind {
        case .bulletedList, .numberedList:
            style.textLists = (0...block.indentLevel).map { depth in
                textList(
                    for: block.kind,
                    startingItemNumber: depth == block.indentLevel ? numberedListOrdinal : 1
                )
            }
        case .toDo:
            // NSTextList를 쓰지 않는다 — 마커 글리프가 취소선을 상속해 박스 위로
            // 선이 그려진다. 수동 indent로 자리만 확보하고 박스는 데코레이션이 그린다.
            style.firstLineHeadIndent = ToDoCheckboxMetrics.textIndent
            style.headIndent = ToDoCheckboxMetrics.textIndent
        case .quote:
            style.firstLineHeadIndent = 16
            style.headIndent = 16
            style.tailIndent = -16
        case .code:
            style.alignment = alignment.code
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
        case .equation:
            style.alignment = alignment.equation
            style.firstLineHeadIndent = 12
            style.headIndent = 12
            style.tailIndent = -12
        case .paragraph, .heading:
            break
        }
        let nestingIndent = CGFloat(block.indentLevel) * 20
        style.firstLineHeadIndent += nestingIndent
        style.headIndent += nestingIndent
        return style
    }

    private static func textList(
        for kind: EditorBlockKind,
        startingItemNumber: Int
    ) -> NSTextList {
        switch kind {
        case .bulletedList:
            NSTextList(markerFormat: .disc, options: [], startingItemNumber: 1)
        case .numberedList:
            NSTextList(
                markerFormat: .decimal,
                options: [],
                startingItemNumber: max(startingItemNumber, 1)
            )
        default:
            preconditionFailure("목록 블록만 NSTextList를 만들 수 있습니다")
        }
    }

    private static func font(
        for kind: EditorBlockKind,
        theme: RichMarkdownTheme,
        traitCollection: UITraitCollection?
    ) -> UIFont {
        switch kind {
        case .code, .equation:
            theme.codeFont.resolvedUIFont(compatibleWith: traitCollection)
        case let .heading(level):
            theme.headingFont(level: level).resolvedUIFont(compatibleWith: traitCollection)
        case .paragraph, .bulletedList, .numberedList, .toDo, .quote:
            theme.bodyFont.resolvedUIFont(compatibleWith: traitCollection)
        }
    }

    private static func withTraits(_ traits: UIFontDescriptor.SymbolicTraits, font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(traits)
        ) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func applyFontTraits(
        _ traits: UIFontDescriptor.SymbolicTraits,
        range: NSRange,
        to text: NSMutableAttributedString
    ) {
        var runs: [(UIFont, NSRange)] = []
        text.enumerateAttribute(.font, in: range) { value, runRange, _ in
            if let font = value as? UIFont { runs.append((font, runRange)) }
        }
        for (font, runRange) in runs {
            text.addAttribute(.font, value: withTraits(traits, font: font), range: runRange)
        }
    }
}
