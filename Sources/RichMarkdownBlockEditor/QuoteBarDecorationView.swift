// Created by JunyoungJung on 2026-08-24.

import RichMarkdown
import SwiftUI
import UIKit

/// 인용문 왼쪽 세로 바의 색 정보. attribute 값으로 실린다.
///
/// Notion처럼 인용문은 본문 색을 유지하고 왼쪽 세로 바로만 구분한다.
/// 바는 이 값을 읽는 `QuoteBarDecorationView`가 텍스트 뒤에 직접 그린다.
public final class QuoteBarStyle: NSObject, Sendable {
    public let color: UIColor
    private let themeColor: Color

    public init(theme: RichMarkdownTheme) {
        themeColor = theme.quoteBar
        color = UIColor(theme.quoteBar)
    }

    /// 같은 테마 색이면 같은 값이다. 블록마다 새로 만든 인스턴스라도 연속 인용 블록과
    /// 그 사이 개행의 attribute run이 하나로 합쳐져 바가 끊기지 않는다.
    override public func isEqual(_ object: Any?) -> Bool {
        (object as? QuoteBarStyle)?.themeColor == themeColor
    }

    override public var hash: Int {
        themeColor.hashValue
    }
}

public extension NSAttributedString.Key {
    /// 인용 블록 구간 표시. 값은 `QuoteBarStyle`.
    static let blockQuoteBar = NSAttributedString.Key("RichMarkdownBlockEditor.blockQuoteBar")
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
        let text = attributed.string as NSString
        let path = CGMutablePath()
        var style: QuoteBarStyle?
        attributed.enumerateAttribute(
            .blockQuoteBar,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let bar = value as? QuoteBarStyle else { return }
            style = bar
            // 끝 개행은 텍스트와 같은 줄에 있지만, iOS 26 TextKit 2는 문서 끝 빈 문단 앞의
            // 개행에 다음 줄 segment도 보고해 바가 한 줄 길어진다. 마지막 인용 줄에 내용이
            // 있으면 개행을 빼고 잰다 (빈 인용 줄은 개행이 그 줄의 유일한 문자라 남긴다).
            let last = NSMaxRange(range) - 1
            let trimsNewline = range.length > 1
                && text.character(at: last) == 0x0A
                && text.character(at: last - 1) != 0x0A
            let measured = trimsNewline
                ? NSRange(location: range.location, length: range.length - 1)
                : range
            let documentStart = contentManager.documentRange.location
            guard let start = contentManager.location(documentStart, offsetBy: measured.location),
                  let end = contentManager.location(start, offsetBy: measured.length),
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
