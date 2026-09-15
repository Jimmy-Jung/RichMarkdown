//
//  Deprecated.swift
//  RichMarkdown
//
//  Created by JunyoungJung on 2026-09-15.
//
//  0.8.0에서 SwiftLatex → RichMarkdown으로 개명하며 남긴 호환 별칭. 0.9.0에서 제거한다.
//  수식 도메인 타입(LatexEquationUIView·LatexEquationAlignment·LatexDollarMathOptions·
//  LatexInlineMathScanner·LatexInlineMathSpan·LatexMathFont)은 이름이 그대로라 별칭이 없다.
//

import SwiftUI

@available(*, deprecated, renamed: "RichMarkdownView")
public typealias LatexMarkdownView = RichMarkdownView

@available(*, deprecated, renamed: "RichMarkdownUIView")
public typealias LatexMarkdownUIView = RichMarkdownUIView

@available(*, deprecated, renamed: "RichMarkdownTheme")
public typealias LatexTheme = RichMarkdownTheme

@available(*, deprecated, renamed: "RichMarkdownFont")
public typealias LatexFont = RichMarkdownFont

@available(*, deprecated, renamed: "RichMarkdownFontWeight")
public typealias LatexFontWeight = RichMarkdownFontWeight

@available(*, deprecated, renamed: "RichMarkdownTextStyle")
public typealias LatexTextStyle = RichMarkdownTextStyle

@available(*, deprecated, renamed: "RichMarkdownStreamingOptions")
public typealias LatexStreamingOptions = RichMarkdownStreamingOptions

@available(*, deprecated, renamed: "RichMarkdownStreamingTextBuffer")
public typealias LatexStreamingTextBuffer = RichMarkdownStreamingTextBuffer

@available(*, deprecated, renamed: "RichMarkdownCodeBlockOptions")
public typealias LatexCodeBlockOptions = RichMarkdownCodeBlockOptions

@available(*, deprecated, renamed: "RichMarkdownHighlightSpan")
public typealias LatexHighlightSpan = RichMarkdownHighlightSpan

@available(*, deprecated, renamed: "RichMarkdownHighlightKind")
public typealias LatexHighlightKind = RichMarkdownHighlightKind

@available(*, deprecated, renamed: "RichMarkdownSyntaxColors")
public typealias LatexSyntaxColors = RichMarkdownSyntaxColors

@available(*, deprecated, renamed: "RichMarkdownSyntaxHighlighting")
public typealias LatexSyntaxHighlighting = RichMarkdownSyntaxHighlighting

@available(*, deprecated, renamed: "RichMarkdownDiagramRendering")
public typealias LatexDiagramRendering = RichMarkdownDiagramRendering

public extension View {
    @available(*, deprecated, renamed: "richMarkdownTheme(_:)")
    func latexTheme(_ theme: RichMarkdownTheme) -> some View {
        richMarkdownTheme(theme)
    }

    @available(*, deprecated, renamed: "richMarkdownStreaming(_:)")
    func latexStreaming(_ options: RichMarkdownStreamingOptions?) -> some View {
        richMarkdownStreaming(options)
    }

    @available(*, deprecated, renamed: "richMarkdownCodeBlocks(_:)")
    func latexCodeBlocks(_ options: RichMarkdownCodeBlockOptions) -> some View {
        richMarkdownCodeBlocks(options)
    }
}
