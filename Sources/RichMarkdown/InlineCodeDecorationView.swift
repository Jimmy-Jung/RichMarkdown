// Created by JunyoungJung on 2026-08-24.

import SwiftUI
import UIKit

/// 인라인 코드 칩(둥근 배경 + 테두리)의 색 정보. attribute 값으로 실린다.
///
/// TextKit의 `.backgroundColor`는 모서리 없는 사각형으로만 칠하므로,
/// 칩 모양은 이 값을 읽는 `InlineCodeDecorationView`가 텍스트 뒤에 직접 그린다.
public final class InlineCodeChipStyle: NSObject, Sendable {
    public let background: UIColor
    public let border: UIColor

    public init(theme: RichMarkdownTheme) {
        background = UIColor(theme.inlineCodeBackground)
        border = UIColor(theme.inlineCodeBorder)
    }
}

public extension NSAttributedString.Key {
    /// 인라인 코드 구간 표시. 값은 `InlineCodeChipStyle`.
    static let inlineCodeChip = NSAttributedString.Key("RichMarkdown.inlineCodeChip")
}

/// UIKit·SwiftUI 두 렌더 경로가 공유하는 칩 규격.
enum InlineCodeChipMetrics {
    static let cornerRadius: CGFloat = 4
    /// 글리프 좌우로 살짝 넓혀 칩답게 보이게 한다. 레이아웃 공간은 차지하지 않으므로
    /// 행 맨 앞(x=0)의 코드는 컨테이너 경계에서 이만큼 잘릴 수 있다 — 허용.
    static let horizontalOutset: CGFloat = 2
}

/// SwiftUI `Text` 경로의 칩 마킹 (iOS 18+). `InlineCodeChipTextRenderer`가 읽는다.
@available(iOS 18.0, *)
struct InlineCodeChipTextAttribute: TextAttribute {}

/// SwiftUI `Text` 뒤에 인라인 코드 칩을 그린다 (iOS 18+).
/// UIKit 경로(`InlineCodeDecorationView`)와 같은 규격을 쓴다.
@available(iOS 18.0, *)
struct InlineCodeChipTextRenderer: TextRenderer {
    let background: Color
    let border: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // 칩을 전부 깐 뒤 텍스트를 그려 글자가 항상 칩 위에 오게 한다.
        for line in layout {
            for rect in chipRects(in: line) {
                let expanded = rect.insetBy(dx: -InlineCodeChipMetrics.horizontalOutset, dy: 0)
                guard expanded.width > 0, expanded.height > 0 else { continue }
                let radius = min(
                    InlineCodeChipMetrics.cornerRadius, expanded.width / 2, expanded.height / 2
                )
                let path = Path(roundedRect: expanded, cornerRadius: radius)
                context.fill(path, with: .color(background))
                context.stroke(path, with: .color(border), lineWidth: 0.5)
            }
        }
        for line in layout {
            context.draw(line)
        }
    }

    /// 한 줄 안에서 이어지는 칩 run들을 하나의 rect로 합친다.
    /// 코드 스팬이 한글·모노 폰트 fallback 경계에서 run이 갈라져도
    /// 칩이 조각나 이음새가 보이지 않게 한다.
    private func chipRects(in line: Text.Layout.Line) -> [CGRect] {
        var merged: [CGRect] = []
        var current: CGRect?
        for run in line {
            guard run[InlineCodeChipTextAttribute.self] != nil else {
                if let rect = current { merged.append(rect) }
                current = nil
                continue
            }
            let rect = run.typographicBounds.rect
            if let existing = current, rect.minX <= existing.maxX + 1 {
                current = existing.union(rect)
            } else {
                if let rect = current { merged.append(rect) }
                current = rect
            }
        }
        if let rect = current { merged.append(rect) }
        return merged
    }
}

/// `UITextView`(TextKit 2) 텍스트 **뒤**에 인라인 코드 칩을 그리는 밑판.
///
/// `CAShapeLayer` 기반이라 문서 길이만큼의 비트맵 backing store를 만들지 않고,
/// 텍스트·크기가 그대로인 `layoutSubviews` 재진입(스크롤 등)에서는 no-op이다.
///
/// 소유 text view가 두 가지를 책임진다:
/// 1. `layoutSubviews` 끝에서 `refresh()` 호출
/// 2. 텍스트를 프로그램적으로 바꿀 때 `invalidate()` 호출
///    (사용자 타이핑은 `textDidChangeNotification`으로 자체 감지한다)
public final class InlineCodeDecorationView: UIView {
    override public class var layerClass: AnyClass { CAShapeLayer.self }

    private weak var textView: UITextView?
    private var chipStyle: InlineCodeChipStyle?
    private var needsPathRebuild = true
    private var lastLayoutSize: CGSize = .zero

    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    @discardableResult
    public static func install(on textView: UITextView) -> InlineCodeDecorationView {
        let view = InlineCodeDecorationView(textView: textView)
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
        fatalError("InlineCodeDecorationView는 코드로만 생성합니다")
    }

    @available(iOS, deprecated: 17.0)
    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { applyColors() }
    }

    /// 칩 범위가 바뀌었을 수 있음을 알린다. 다음 layout pass에서 경로를 다시 만든다.
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
            chipStyle = nil
            shapeLayer.path = nil
            return
        }

        let inset = textView.textContainerInset
        let path = CGMutablePath()
        var style: InlineCodeChipStyle?
        attributed.enumerateAttribute(
            .inlineCodeChip,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let chip = value as? InlineCodeChipStyle else { return }
            style = chip
            let documentStart = contentManager.documentRange.location
            guard let start = contentManager.location(documentStart, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }
            layoutManager.enumerateTextSegments(
                in: textRange,
                type: .standard,
                options: .rangeNotRequired
            ) { _, segmentFrame, _, _ in
                var rect = segmentFrame.offsetBy(dx: inset.left, dy: inset.top)
                rect = rect.insetBy(dx: -InlineCodeChipMetrics.horizontalOutset, dy: 0)
                if rect.width > 0, rect.height > 0 {
                    let radius = min(
                        InlineCodeChipMetrics.cornerRadius, rect.width / 2, rect.height / 2
                    )
                    path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
                }
                return true
            }
        }
        chipStyle = style
        shapeLayer.path = path.isEmpty ? nil : path
    }

    private func applyColors() {
        guard let style = chipStyle else {
            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = nil
            return
        }
        let traits = traitCollection
        shapeLayer.fillColor = style.background.resolvedColor(with: traits).cgColor
        shapeLayer.strokeColor = style.border.resolvedColor(with: traits).cgColor
        shapeLayer.lineWidth = 1 / max(traits.displayScale, 1)
    }
}
