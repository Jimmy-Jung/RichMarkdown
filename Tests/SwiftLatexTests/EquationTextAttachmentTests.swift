// Created by JunyoungJung on 2026-08-24.

import Foundation
import Testing
import UIKit
@testable import SwiftLatex

@MainActor
@Suite("수식 attachment 줄 배치", .serialized)
struct EquationTextAttachmentTests {
    private static let containerWidth: CGFloat = 320

    /// 컨테이너보다 좁은 수식은 줄 어디에 놓이든 제 크기로 그려져야 한다.
    ///
    /// 남은 공간(`proposedLineFragment.width - position.x`)으로 폭을 clamp하면 줄 끝의
    /// 수식이 실제보다 좁게 보고돼 TextKit이 줄을 바꾸지 않고, 수식은 그 좁은 폭에
    /// 잘려 그려진다 (실측 결함 — 화면에서 근호가 오른쪽에서 잘림). 줄 전체 폭을
    /// 기준으로 clamp하면 안 들어가는 수식이 다음 줄로 내려가 온전히 보인다.
    /// 앞 텍스트 길이를 한 글자씩 늘려 수식이 줄 끝 모든 위치에 걸리게 만든다.
    /// 고정 문장 하나로는 수식이 줄 끝에 안 걸려 결함을 놓친다.
    @Test func inlineEquationIsNeverSqueezedBelowIntrinsicWidth() throws {
        var checked = 0
        for padCount in 0..<28 {
            let textView = makeTextView()
            textView.attributedText = document(hasEquation: true, padCount: padCount)
            let (equations, containerWidth) = layout(textView)

            for equation in equations {
                let intrinsic = equation.intrinsicContentSize.width
                // 컨테이너 자체보다 넓은 수식만 clamp가 정당하다.
                guard intrinsic <= containerWidth else { continue }
                checked += 1
                #expect(
                    equation.bounds.width >= intrinsic - 0.5,
                    "여백 \(padCount)자에서 수식이 \(intrinsic) → \(equation.bounds.width)로 찌그러진다"
                )
            }
        }
        #expect(checked > 0, "수식 뷰가 하나도 만들어지지 않았다")
    }

    /// 수식이 없는 같은 문장은 attachment를 만들지 않는다 — 대조군.
    @Test func plainTextCreatesNoEquationView() throws {
        let textView = makeTextView()
        textView.attributedText = document(hasEquation: false, padCount: 0)
        let (equations, _) = layout(textView)

        #expect(equations.isEmpty)
    }

    // MARK: - 헬퍼

    private func makeTextView() -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: Self.containerWidth, height: 480)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        return textView
    }

    /// `padCount`만큼 앞 글자를 채워 수식의 줄 안 위치를 옮긴다.
    /// Dynamic Type에 흔들리지 않도록 폰트 크기를 고정한다.
    private func document(hasEquation: Bool, padCount: Int) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: 17)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let result = NSMutableAttributedString(
            string: String(repeating: "가", count: padCount),
            attributes: attributes
        )
        for filler in [" 한글 사이에 ", " 조금 더 긴 문장을 두고 ", " 짧게 "] {
            result.append(NSAttributedString(string: filler, attributes: attributes))
            if hasEquation {
                let attachment = EquationTextAttachment(
                    latex: #"\sqrt{x^2+1} + \frac{a}{b}"#,
                    source: #"\(\sqrt{x^2+1} + \frac{a}{b}\)"#,
                    theme: .default,
                    isDisplay: false,
                    pointSize: font.pointSize
                )
                let string = NSMutableAttributedString(attachment: attachment)
                string.addAttributes(
                    attributes,
                    range: NSRange(location: 0, length: string.length)
                )
                result.append(string)
            }
            result.append(NSAttributedString(
                string: " 근호를 섞어도 baseline이 맞아야 합니다. ",
                attributes: attributes
            ))
        }
        return result
    }

    /// 레이아웃 후 그려진 수식 뷰들과 컨테이너 폭을 돌려준다.
    private func layout(
        _ textView: UITextView
    ) -> (equations: [LatexEquationUIView], width: CGFloat) {
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.isHidden = false
        defer { window.isHidden = true }

        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return ([], Self.containerWidth) }
        layoutManager.ensureLayout(for: contentManager.documentRange)
        window.layoutIfNeeded()

        func equationViews(in view: UIView) -> [LatexEquationUIView] {
            if let equation = view as? LatexEquationUIView { return [equation] }
            return view.subviews.flatMap(equationViews)
        }
        return (equationViews(in: textView), textView.textContainer.size.width)
    }
}
