// Created by JunyoungJung on 2026-08-24.

import SwiftLatex
import UIKit

/// 인용문 왼쪽 세로 바의 색 정보. attribute 값으로 실린다.
///
/// Notion처럼 인용문은 본문 색을 유지하고 왼쪽 세로 바로만 구분한다.
/// 바는 이 값을 읽는 `QuoteBarDecorationView`가 텍스트 뒤에 직접 그린다.
public final class QuoteBarStyle: NSObject, Sendable {
    public let color: UIColor

    public init(theme: LatexTheme) {
        color = UIColor(theme.quoteBar)
    }
}

public extension NSAttributedString.Key {
    /// 인용 블록 구간 표시. 값은 `QuoteBarStyle`.
    static let blockQuoteBar = NSAttributedString.Key("SwiftLatexBlockEditor.blockQuoteBar")
}

enum QuoteBarMetrics {
    static let width: CGFloat = 3
    /// 텍스트 컨테이너 왼쪽 inset에서 바까지의 여백.
    static let leadingOffset: CGFloat = 2
}

/// `UITextView`(TextKit 2) 텍스트 **뒤**에 인용문 세로 바를 그리는 밑판.
/// `InlineCodeDecorationView`와 같은 계약이다:
/// 1. 소유 text view가 `layoutSubviews` 끝에서 `refresh()`를 부른다.
/// 2. 텍스트를 프로그램적으로 바꿀 때 `invalidate()`를 부른다.
public final class QuoteBarDecorationView: UIView {
    override public class var layerClass: AnyClass { CAShapeLayer.self }

    private weak var textView: UITextView?
    private var barStyle: QuoteBarStyle?
    private var needsPathRebuild = true
    private var lastLayoutSize: CGSize = .zero

    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    @discardableResult
    public static func install(on textView: UITextView) -> QuoteBarDecorationView {
        let view = QuoteBarDecorationView(textView: textView)
        textView.insertSubview(view, at: 0)
        return view
    }

    private init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextDidChange),
            name: UITextView.textDidChangeNotification,
            object: textView
        )
        if #available(iOS 17.0, *) {
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self,
                UITraitDisplayScale.self,
            ]) { (view: Self, _: UITraitCollection) in
                view.applyColors()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuoteBarDecorationView는 코드로만 생성합니다")
    }

    @available(iOS, deprecated: 17.0)
    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { applyColors() }
    }

    /// 인용 범위가 바뀌었을 수 있음을 알린다. 다음 layout pass에서 경로를 다시 만든다.
    public func invalidate() {
        needsPathRebuild = true
        textView?.setNeedsLayout()
    }

    @objc private func handleTextDidChange() {
        invalidate()
    }

    /// 소유 text view의 `layoutSubviews` 끝에서 부른다.
    public func refresh() {
        guard let textView else { return }
        let size = CGSize(
            width: max(textView.contentSize.width, textView.bounds.width),
            height: max(textView.contentSize.height, textView.bounds.height)
        )
        guard needsPathRebuild || size != lastLayoutSize else { return }
        needsPathRebuild = false
        lastLayoutSize = size
        frame = CGRect(origin: .zero, size: size)
        rebuildPath()
        applyColors()
    }

    private func rebuildPath() {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let attributed = textView.attributedText,
              attributed.length > 0
        else {
            barStyle = nil
            shapeLayer.path = nil
            return
        }

        let inset = textView.textContainerInset
        let path = CGMutablePath()
        var style: QuoteBarStyle?
        attributed.enumerateAttribute(
            .blockQuoteBar,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let bar = value as? QuoteBarStyle else { return }
            style = bar
            let documentStart = contentManager.documentRange.location
            guard let start = contentManager.location(documentStart, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }

            // 연속 인용 블록 run 하나가 세로로 이어진 바 하나가 되도록
            // 세그먼트들의 min/max Y를 합쳐 rect 하나로 만든다.
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            layoutManager.enumerateTextSegments(
                in: textRange,
                type: .standard,
                options: .rangeNotRequired
            ) { _, segmentFrame, _, _ in
                if segmentFrame.height > 0 {
                    top = min(top, segmentFrame.minY)
                    bottom = max(bottom, segmentFrame.maxY)
                }
                return true
            }
            guard bottom > top else { return }
            let rect = CGRect(
                x: inset.left + QuoteBarMetrics.leadingOffset,
                y: top + inset.top,
                width: QuoteBarMetrics.width,
                height: bottom - top
            )
            let radius = QuoteBarMetrics.width / 2
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        barStyle = style
        shapeLayer.path = path.isEmpty ? nil : path
    }

    private func applyColors() {
        guard let style = barStyle else {
            shapeLayer.fillColor = nil
            return
        }
        shapeLayer.fillColor = style.color.resolvedColor(with: traitCollection).cgColor
        shapeLayer.strokeColor = nil
    }
}
