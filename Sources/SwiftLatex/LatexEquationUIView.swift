import SwiftUI
import UIKit
import SwiftLatexCore

/// Markdown chrome 없이 블록 LaTeX 하나만 그리는 UIKit 뷰입니다.
///
/// 편집기 attachment처럼 수식만 필요한 화면에서 `LatexMarkdownUIView`의
/// Markdown 파싱·복사 버튼을 함께 만들지 않도록 제공하는 최소 렌더링 표면입니다.
public final class LatexEquationUIView: UIView {
    private var boundedLatex: InputLimits.BoundedInput
    private var contentView: UIView?

    public var latex: String {
        get { boundedLatex.text }
        set {
            let bounded = InputLimits.bound(newValue)
            guard bounded != boundedLatex else { return }
            boundedLatex = bounded
            rebuild()
        }
    }

    public var theme: LatexTheme {
        didSet {
            guard theme != oldValue else { return }
            rebuild()
        }
    }

    public init(latex: String, theme: LatexTheme = .default) {
        self.boundedLatex = InputLimits.bound(latex)
        self.theme = theme
        super.init(frame: .zero)

        isAccessibilityElement = true
        rebuild()

        if #available(iOS 17.0, *) {
            registerForTraitChanges([
                UITraitPreferredContentSizeCategory.self,
                UITraitUserInterfaceStyle.self,
                UITraitDisplayScale.self,
            ]) { (view: Self, _: UITraitCollection) in
                view.rebuild()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LatexEquationUIView는 코드로만 생성합니다")
    }

    @available(iOS, deprecated: 17.0)
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { rebuild() }
    }

    public override var intrinsicContentSize: CGSize {
        guard let contentView else { return .zero }
        return contentView.intrinsicContentSize
    }

    private func rebuild() {
        contentView?.removeFromSuperview()

        let textColor = UIColor(theme.textColor).resolvedColor(with: traitCollection)
        let bodyFont = theme.bodyFont.resolvedUIFont(compatibleWith: traitCollection)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let key = MathRenderKey(
            latex: boundedLatex.text,
            mathFont: theme.mathFont,
            pointSize: bodyFont.pointSize,
            colorRGBA: textColor.rgbaValue,
            isDisplay: true,
            displayScale: scale
        )

        let nextView = BlockMathVectorView.make(key: key, textColor: textColor)
            ?? fallbackLabel(textColor: textColor)
        nextView.isAccessibilityElement = false
        nextView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nextView)
        NSLayoutConstraint.activate([
            nextView.topAnchor.constraint(equalTo: topAnchor),
            nextView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nextView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentView = nextView
        accessibilityLabel = "수식: \(boundedLatex.text)"
        invalidateIntrinsicContentSize()
    }

    private func fallbackLabel(textColor: UIColor) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.text = boundedLatex.text
        label.textColor = textColor
        label.font = theme.codeFont.resolvedUIFont(compatibleWith: traitCollection)
        return label
    }
}
