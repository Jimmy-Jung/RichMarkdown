import SwiftUI
import RichMarkdown
import UIKit

/// Mermaid 코드 블록을 대체하는 UIKit 뷰.
///
/// 렌더가 끝나면 높이를 intrinsic content size로 확정하고 `onSizeChange`를 호출한다.
/// 실패하면 **원문 코드 블록으로 되돌린다** — 일부만 그려진 다이어그램을 남기지 않는다
/// (DEVELOPMENT.md §1 「실패 시 표시 원칙」).
@MainActor
public final class MermaidDiagramUIView: UIView {
    /// 첫 렌더가 끝나기 전, 그리고 폭을 재기 위해 필요한 최소 높이.
    public static let placeholderHeight: CGFloat = 64

    public var source: String {
        didSet { if source != oldValue { invalidateRender() } }
    }

    public var theme: RichMarkdownTheme {
        didSet { if theme != oldValue { invalidateRender() } }
    }

    /// 높이가 확정·변경될 때 호출된다. 셀 self-sizing 재측정에 쓴다.
    public var onSizeChange: (@MainActor () -> Void)?

    private let renderer = MermaidWebRenderer()
    private let statusLabel = UILabel()
    private let sourceTextView = UITextView()
    private let fallbackStack = UIStackView()

    private var contentHeight: CGFloat = MermaidDiagramUIView.placeholderHeight
    private var renderTask: Task<Void, Never>?
    /// 마지막으로 요청한 (원문, 다크, 폭, 글자 크기). 같은 조합은 다시 그리지 않는다.
    private var renderedKey: String?
    /// 콘텐츠 프로세스 종료 뒤 재시도를 한 번으로 제한한다.
    private var retriedAfterTermination = false

    public init(source: String, theme: RichMarkdownTheme = .default) {
        self.source = source
        self.theme = theme
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MermaidDiagramUIView는 코드로만 생성한다")
    }

    deinit {
        renderTask?.cancel()
    }

    private func setUp() {
        clipsToBounds = true

        let webView = renderer.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = false

        sourceTextView.isEditable = false
        sourceTextView.isSelectable = true
        sourceTextView.isScrollEnabled = false
        sourceTextView.backgroundColor = .clear
        sourceTextView.textContainerInset = .zero
        sourceTextView.textContainer.lineFragmentPadding = 0
        sourceTextView.adjustsFontForContentSizeCategory = false

        fallbackStack.axis = .vertical
        fallbackStack.spacing = 8
        fallbackStack.alignment = .fill
        fallbackStack.isLayoutMarginsRelativeArrangement = true
        fallbackStack.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        fallbackStack.translatesAutoresizingMaskIntoConstraints = false
        fallbackStack.addArrangedSubview(statusLabel)
        fallbackStack.addArrangedSubview(sourceTextView)
        addSubview(fallbackStack)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fallbackStack.topAnchor.constraint(equalTo: topAnchor),
            fallbackStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        showStatus("Mermaid 다이어그램을 그리는 중입니다.", showsSource: false)

        if #available(iOS 17.0, *) {
            registerForTraitChanges(
                [UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]
            ) { (view: Self, _: UITraitCollection) in
                view.setNeedsLayout()
            }
        }
    }

    @available(iOS, deprecated: 17.0)
    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if #unavailable(iOS 17.0) {
            setNeedsLayout()
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        renderIfNeeded()
    }

    /// WKWebView는 window에 붙기 전에는 콘텐츠 프로세스를 띄우지 않아 로드가 끝나지 않는다(실측).
    /// 창에 들어온 시점에 렌더를 시작한다.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    // MARK: - 렌더

    private func invalidateRender() {
        renderedKey = nil
        setNeedsLayout()
    }

    private var bodyFontSize: CGFloat {
        theme.bodyFont.resolvedUIFont(compatibleWith: traitCollection).pointSize
    }

    /// 폭·다크 모드·Dynamic Type·원문 중 하나라도 바뀌면 다시 그린다.
    /// 키에 폭이 들어 있어 높이만 바뀌는 이 경로가 다시 자신을 부르지 않는다.
    private func renderIfNeeded() {
        let width = bounds.width
        // window 밖에서 시작하면 WKWebView가 로드를 끝내지 못해 15초 뒤 timeout으로 실패한다.
        guard width > 1, window != nil else { return }
        let isDark = traitCollection.userInterfaceStyle == .dark
        let fontSize = bodyFontSize
        // U+0001은 Mermaid 원문에 나타나지 않아 구분자로 안전하다.
        let key = "\(source)\u{1}\(isDark)\u{1}\(floor(width))\u{1}\(fontSize)"
        guard key != renderedKey else { return }
        renderedKey = key

        renderTask?.cancel()
        let source = source
        renderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let size = try await self.renderer.render(
                    source: source,
                    dark: isDark,
                    width: width,
                    fontSize: fontSize
                )
                try Task.checkCancellation()
                self.showDiagram(height: size.height)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // WebKit 콘텐츠 프로세스가 죽은 경우는 입력 문제가 아니다. 한 번만 다시 그린다 —
                // 무제한 재시도는 15초 timeout을 반복하는 무한 루프가 된다.
                if case MermaidError.webContentTerminated = error, !self.retriedAfterTermination {
                    self.retriedAfterTermination = true
                    self.renderedKey = nil
                    self.setNeedsLayout()
                    return
                }
                self.showStatus(
                    "Mermaid 다이어그램을 표시하지 못했습니다 · \(error.localizedDescription)",
                    showsSource: true
                )
            }
        }
    }

    private func showDiagram(height: CGFloat) {
        renderer.webView.isHidden = false
        fallbackStack.isHidden = true
        accessibilityLabel = nil
        isAccessibilityElement = false
        setContentHeight(height)
    }

    /// 렌더 전·실패 상태. 실패면 원문을 그대로 보여 준다.
    private func showStatus(_ message: String, showsSource: Bool) {
        renderer.webView.isHidden = true
        fallbackStack.isHidden = false
        statusLabel.font = theme.codeLabelFont.resolvedUIFont(compatibleWith: traitCollection)
        statusLabel.textColor = UIColor(theme.textColor)
        statusLabel.text = message
        sourceTextView.isHidden = !showsSource
        sourceTextView.attributedText = NSAttributedString(string: source, attributes: [
            .font: theme.codeFont.resolvedUIFont(compatibleWith: traitCollection),
            .foregroundColor: UIColor(theme.textColor),
        ])

        let width = bounds.width > 1 ? bounds.width : 320
        let fitted = fallbackStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        setContentHeight(max(Self.placeholderHeight, ceil(fitted.height)))
    }

    private func setContentHeight(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}
