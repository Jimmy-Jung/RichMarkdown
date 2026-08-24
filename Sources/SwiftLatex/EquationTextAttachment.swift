// Created by JunyoungJung on 2026-08-24.

import UIKit

/// TextKit 2 문서 흐름 안에 LaTeX 수식을 라이브 뷰(`LatexEquationUIView`)로 배치하는
/// attachment.
///
/// 비트맵 이미지 attachment가 아니라 실제 뷰라서 다크 모드 전환이 즉시 반영된다.
/// `attachmentBounds`가 수식 뷰의 `intrinsicContentSize`를 line fragment 폭 안으로
/// clamp하고, display 수식은 줄 높이만큼 baseline을 내려 블록처럼 배치한다.
/// inline 수식은 주변 폰트의 `descender`에 맞춰 baseline을 정렬하므로,
/// **attachment 문자에도 `.font` attribute를 부여해야 한다.**
public final class EquationTextAttachment: NSTextAttachment {
    /// 렌더할 LaTeX 본문 (구분자 제외).
    public let latex: String
    /// 편집기에서 attachment ↔ 원문 왕복에 쓰는 원문. 뷰어 전용이면 `latex`와 같아도 된다.
    public let source: String
    public let theme: LatexTheme
    /// display 수식이면 별도 문단 블록처럼 배치한다.
    public let isDisplay: Bool
    /// 주변 텍스트의 point size. 수식 크기의 기준이 된다.
    public let pointSize: CGFloat

    public init(
        latex: String,
        source: String,
        theme: LatexTheme,
        isDisplay: Bool,
        pointSize: CGFloat
    ) {
        self.latex = latex
        self.source = source
        self.theme = theme
        self.isDisplay = isDisplay
        self.pointSize = pointSize
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
        lineLayoutPadding = 0
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("EquationTextAttachment는 코드로만 생성합니다")
    }

    override public func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        EquationAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}

private final class EquationAttachmentViewProvider: NSTextAttachmentViewProvider {
    override init(
        textAttachment: NSTextAttachment,
        parentView: UIView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        super.loadView()
        guard let attachment = textAttachment as? EquationTextAttachment else { return }
        // TextKit 2가 main thread에서 호출하지만 provider API는 nonisolated다.
        // Sendable 값만 건네고 self는 unsafe로 표시해 region 진단을 통과한다.
        let latex = attachment.latex
        let source = attachment.source
        let theme = attachment.theme
        let isDisplay = attachment.isDisplay
        let pointSize = attachment.pointSize
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            let equationView = LatexEquationUIView(
                latex: latex,
                source: source,
                theme: theme,
                isDisplay: isDisplay,
                pointSize: pointSize
            )
            equationView.isUserInteractionEnabled = false
            provider.view = equationView
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        // TextKit 2가 main thread에서 호출하지만 provider API는 nonisolated다.
        nonisolated(unsafe) let provider = self
        let intrinsic: CGSize? = MainActor.assumeIsolated {
            (provider.view as? LatexEquationUIView)?.intrinsicContentSize
        }
        guard let attachment = textAttachment as? EquationTextAttachment,
              let intrinsic else {
            return super.attachmentBounds(
                for: attributes,
                location: location,
                textContainer: textContainer,
                proposedLineFragment: proposedLineFragment,
                position: position
            )
        }
        // 남은 공간(`- position.x`)으로 clamp하면 줄 끝의 수식을 실제보다 좁게 보고해
        // TextKit이 줄을 바꾸지 않고 뒤 텍스트를 이어 붙인다(오른쪽 잘림). 줄 전체 폭을
        // 기준으로 clamp해야 안 들어가는 수식이 다음 줄로 내려간다.
        let availableWidth = max(proposedLineFragment.width, 1)
        let width = min(max(intrinsic.width, 1), availableWidth)
        let font = attributes[.font] as? UIFont
        return CGRect(
            x: 0,
            y: attachment.isDisplay ? -(font?.lineHeight ?? 0) : (font?.descender ?? 0),
            width: width,
            height: max(intrinsic.height, font?.lineHeight ?? 1)
        )
    }
}
