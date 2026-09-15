import SwiftUI
import RichMarkdown
import UIKit

/// ```` ```mermaid ```` 코드 블록을 공식 Mermaid 다이어그램으로 대체하는 확장.
///
/// ```swift
/// RichMarkdownView(markdown: message)
///     .richMarkdownCodeBlocks(.init(diagram: MermaidDiagramRenderer.shared))
/// ```
///
/// UIKit 렌더러는 `RichMarkdownUIView.codeBlocks`에 같은 값을 넣는다.
public final class MermaidDiagramRenderer: RichMarkdownDiagramRendering {
    public static let shared = MermaidDiagramRenderer()

    public let languages: Set<String>

    /// - Parameter languages: 다이어그램으로 그릴 코드 블록 언어(소문자).
    ///   기본값은 `["mermaid"]`다.
    public init(languages: Set<String> = ["mermaid"]) {
        self.languages = Set(languages.map { $0.lowercased() })
    }

    @MainActor
    public func makeUIView(
        source: String,
        theme: RichMarkdownTheme,
        onSizeChange: @escaping @MainActor () -> Void
    ) -> UIView {
        let view = MermaidDiagramUIView(source: source, theme: theme)
        view.onSizeChange = onSizeChange
        return view
    }

    @MainActor
    public func makeSwiftUIView(source: String, theme: RichMarkdownTheme) -> AnyView {
        AnyView(MermaidDiagramView(source: source, theme: theme))
    }
}
