import SwiftUI
import SwiftLatex

/// SwiftUI용 Mermaid 다이어그램 뷰. 폭은 부모가 정하고, 높이는 렌더 결과를 따른다.
///
/// ```swift
/// MermaidDiagramView(source: "flowchart LR\n  A --> B")
/// ```
public struct MermaidDiagramView: View {
    private let source: String
    private let theme: LatexTheme

    @State private var height: CGFloat = MermaidDiagramUIView.placeholderHeight

    public init(source: String, theme: LatexTheme = .default) {
        self.source = source
        self.theme = theme
    }

    public var body: some View {
        Host(source: source, theme: theme) { measured in
            guard abs(measured - height) > 0.5 else { return }
            height = measured
        }
        .frame(height: height)
    }

    /// `UIViewRepresentable`은 intrinsic content size를 자동으로 따라오지 않는다.
    /// 렌더가 끝난 높이를 SwiftUI state로 올려 `frame(height:)`로 확정한다.
    private struct Host: UIViewRepresentable {
        let source: String
        let theme: LatexTheme
        let onHeight: @MainActor (CGFloat) -> Void

        func makeUIView(context: Context) -> MermaidDiagramUIView {
            let view = MermaidDiagramUIView(source: source, theme: theme)
            attachSizeCallback(to: view)
            return view
        }

        func updateUIView(_ view: MermaidDiagramUIView, context: Context) {
            view.source = source
            view.theme = theme
            // 이전 View 값을 캡처한 클로저를 남기지 않는다.
            attachSizeCallback(to: view)
        }

        static func dismantleUIView(_ view: MermaidDiagramUIView, coordinator: ()) {
            view.onSizeChange = nil
        }

        private func attachSizeCallback(to view: MermaidDiagramUIView) {
            let onHeight = onHeight
            view.onSizeChange = { [weak view] in
                guard let view else { return }
                onHeight(view.intrinsicContentSize.height)
            }
        }
    }
}
