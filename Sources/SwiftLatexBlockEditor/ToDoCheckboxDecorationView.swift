// Created by JunyoungJung on 2026-08-24.

import UIKit

/// 할 일 체크박스 표시. attribute 값으로 실린다.
///
/// Notion처럼 미완료는 둥근 테두리 박스, 완료는 액센트 채움 + 흰 체크로 그린다.
/// 블록마다 새 인스턴스를 실어 인접 블록의 attribute run이 합쳐져도
/// 문단 시작 판정으로 박스를 하나씩 그린다.
public final class ToDoCheckboxStyle: NSObject, Sendable {
    public let isChecked: Bool

    public init(isChecked: Bool) {
        self.isChecked = isChecked
    }
}

public extension NSAttributedString.Key {
    /// 할 일 블록 구간 표시. 값은 `ToDoCheckboxStyle`.
    static let toDoCheckbox = NSAttributedString.Key("SwiftLatexBlockEditor.toDoCheckbox")
}

enum ToDoCheckboxMetrics {
    static let side: CGFloat = 18
    static let cornerRadius: CGFloat = 4
    /// 박스 오른쪽 끝에서 텍스트 시작까지의 여백.
    static let trailingGap: CGFloat = 6
    /// 할 일 텍스트의 들여쓰기. NSTextList 마커 대신 수동 indent로 자리를 확보한다
    /// — 마커 글리프가 있으면 취소선이 마커까지 상속돼 박스 위로 선이 그려진다.
    static let textIndent: CGFloat = 28
}

/// `UITextView`(TextKit 2) 텍스트 **뒤**에 할 일 체크박스를 그리는 밑판.
/// `InlineCodeDecorationView`·`QuoteBarDecorationView`와 같은 계약이다.
///
/// 상태별 색이 달라 layer 3장을 쓴다: 미완료 테두리 / 완료 채움 / 흰 체크.
public final class ToDoCheckboxDecorationView: UIView {
    private weak var textView: UITextView?
    private var hasBoxes = false
    private var needsPathRebuild = true
    private var lastLayoutSize: CGSize = .zero

    private let uncheckedLayer = CAShapeLayer()
    private let checkedFillLayer = CAShapeLayer()
    private let checkMarkLayer = CAShapeLayer()

    @discardableResult
    public static func install(on textView: UITextView) -> ToDoCheckboxDecorationView {
        let view = ToDoCheckboxDecorationView(textView: textView)
        textView.insertSubview(view, at: 0)
        return view
    }

    private init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(uncheckedLayer)
        layer.addSublayer(checkedFillLayer)
        layer.addSublayer(checkMarkLayer)
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
        fatalError("ToDoCheckboxDecorationView는 코드로만 생성합니다")
    }

    @available(iOS, deprecated: 17.0)
    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0) { applyColors() }
    }

    override public func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    /// 할 일 범위가 바뀌었을 수 있음을 알린다. 다음 layout pass에서 경로를 다시 만든다.
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
        rebuildPaths()
        applyColors()
    }

    private func rebuildPaths() {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let attributed = textView.attributedText,
              attributed.length > 0
        else {
            hasBoxes = false
            uncheckedLayer.path = nil
            checkedFillLayer.path = nil
            checkMarkLayer.path = nil
            return
        }

        let inset = textView.textContainerInset
        let text = attributed.string as NSString
        let uncheckedPath = CGMutablePath()
        let checkedPath = CGMutablePath()
        let checkMarkPath = CGMutablePath()

        attributed.enumerateAttribute(
            .toDoCheckbox,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let style = value as? ToDoCheckboxStyle else { return }
            // run 병합·분할과 무관하게 문단 시작마다 박스 하나를 그린다.
            for offset in range.location..<NSMaxRange(range) {
                let isParagraphStart = offset == 0
                    || text.character(at: offset - 1) == 0x0A // "\n"
                guard isParagraphStart else { continue }
                guard let lineRect = firstCharacterRect(
                    at: offset,
                    layoutManager: layoutManager,
                    contentManager: contentManager
                ) else { continue }

                let side = min(ToDoCheckboxMetrics.side, max(lineRect.height - 2, 8))
                let box = CGRect(
                    x: lineRect.minX + inset.left - ToDoCheckboxMetrics.trailingGap - side,
                    y: lineRect.midY + inset.top - side / 2,
                    width: side,
                    height: side
                )
                let radius = min(ToDoCheckboxMetrics.cornerRadius, side / 2)
                if style.isChecked {
                    checkedPath.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
                    addCheckMark(in: box, to: checkMarkPath)
                } else {
                    uncheckedPath.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
                }
            }
        }

        hasBoxes = !(uncheckedPath.isEmpty && checkedPath.isEmpty)
        uncheckedLayer.path = uncheckedPath.isEmpty ? nil : uncheckedPath
        checkedFillLayer.path = checkedPath.isEmpty ? nil : checkedPath
        checkMarkLayer.path = checkMarkPath.isEmpty ? nil : checkMarkPath
    }

    private func firstCharacterRect(
        at offset: Int,
        layoutManager: NSTextLayoutManager,
        contentManager: NSTextContentManager
    ) -> CGRect? {
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: offset),
              let end = contentManager.location(start, offsetBy: 1),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var rect: CGRect?
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: .rangeNotRequired
        ) { _, segmentFrame, _, _ in
            if segmentFrame.height > 0 {
                rect = segmentFrame
                return false
            }
            return true
        }
        return rect
    }

    private func addCheckMark(in box: CGRect, to path: CGMutablePath) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y)
        }
        path.move(to: point(0.26, 0.53))
        path.addLine(to: point(0.43, 0.70))
        path.addLine(to: point(0.75, 0.32))
    }

    private func applyColors() {
        guard hasBoxes else {
            uncheckedLayer.strokeColor = nil
            checkedFillLayer.fillColor = nil
            checkMarkLayer.strokeColor = nil
            return
        }
        let traits = traitCollection
        uncheckedLayer.fillColor = nil
        uncheckedLayer.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traits).cgColor
        uncheckedLayer.lineWidth = 1.5

        checkedFillLayer.fillColor = tintColor.resolvedColor(with: traits).cgColor
        checkedFillLayer.strokeColor = nil

        checkMarkLayer.fillColor = nil
        checkMarkLayer.strokeColor = UIColor.white.cgColor
        checkMarkLayer.lineWidth = 2
        checkMarkLayer.lineCap = .round
        checkMarkLayer.lineJoin = .round
    }
}
