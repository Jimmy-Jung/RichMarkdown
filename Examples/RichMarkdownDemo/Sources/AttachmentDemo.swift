// Created by JunyoungJung on 2026-08-24.

import RichMarkdown
import RichMarkdownBlockEditor
import SwiftUI
import UIKit

/// 데모 공용 수식 블록 정렬 옵션. 블록 에디터(`BlockAlignmentConfiguration`)와
/// 렌더러(`RichMarkdownTheme.equationAlignment`) 두 주입점에 매핑된다.
enum EquationAlignmentOption: String, CaseIterable, Identifiable {
    case leading = "좌측"
    case center = "중앙"
    case trailing = "우측"

    var id: String { rawValue }

    var textAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    var latexAlignment: LatexEquationAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// 데모 공용 "블록 수식 정렬" 서브메뉴 (부모 메뉴 버튼 아래에 좌/중앙/우 선택).
struct EquationAlignmentMenu: View {
    @Binding var selection: EquationAlignmentOption

    var body: some View {
        Menu("블록 수식 정렬") {
            Picker("블록 수식 정렬", selection: $selection) {
                ForEach(EquationAlignmentOption.allCases) { alignment in
                    Text(verbatim: alignment.rawValue).tag(alignment)
                }
            }
        }
        .accessibilityIdentifier("demo.equationAlignment")
    }
}


/// `EquationTextAttachment` 단독 사용 확인 화면.
///
/// 블록 에디터 없이 attributed string에 수식을 넣는 두 경로를 나란히 확인한다.
/// 1. **직접 구성** — 임의 텍스트 사이에 attachment를 손으로 배치한다
///    (README 예시 1). attachment 문자에 `.font`를 부여해야 baseline이 맞는다.
/// 2. **MarkdownStyler** — 블록 모델을 읽기 전용 문서로 스타일링한다
///    (편집기 없는 미리보기, `editingEquationIDs` 기본값이라 모든 수식이 attachment).
/// 테마 메뉴는 attachment가 init 시점 테마를 캡처하므로 문서를 재구성해야
/// 반영된다는 계약(README 예시 2)을 확인한다.
struct AttachmentDemoView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case handBuilt = "직접 구성"
        case styler = "MarkdownStyler"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .handBuilt
    // seed가 달러 수식·통화 보호 케이스를 시연하므로 기본 on. 꺼서 비교한다.
    @State private var parsesDollarMath = true
    @State private var equationAlignment: EquationAlignmentOption = .center
    @State private var preset = RichMarkdownThemePreset.fromLaunchArguments()

    private var blockAlignment: BlockAlignmentConfiguration {
        BlockAlignmentConfiguration(equation: equationAlignment.textAlignment)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("표시 방식", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(verbatim: mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("attachmentDemo.mode")

            ReadOnlyEquationDocumentView(
                mode: mode,
                theme: preset.theme,
                parsesDollarMath: parsesDollarMath,
                blockAlignment: blockAlignment
            )
        }
        .background(Color(.systemBackground))
        .navigationTitle("수식 Attachment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                        .accessibilityIdentifier("attachmentDemo.parsesDollarMath")
                    EquationAlignmentMenu(selection: $equationAlignment)
                    Picker("테마", selection: $preset) {
                        ForEach(RichMarkdownThemePreset.allCases) { preset in
                            Text(verbatim: preset.rawValue).tag(preset)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
                .accessibilityIdentifier("attachmentDemo.options")
            }
        }
    }
}

/// 읽기 전용 TextKit 2 문서 뷰.
/// 인라인 코드 칩 렌더까지 확인하려고 package의 `BlockDocumentUITextView`를 재사용한다.
struct ReadOnlyEquationDocumentView: UIViewRepresentable {
    @Environment(\.sizeCategory) private var sizeCategory

    let mode: AttachmentDemoView.Mode
    let theme: RichMarkdownTheme
    let parsesDollarMath: Bool
    let blockAlignment: BlockAlignmentConfiguration

    func makeUIView(context: Context) -> BlockDocumentUITextView {
        let view = BlockDocumentUITextView()
        view.isEditable = false
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = "attachmentDemoTextView"
        view.accessibilityLabel = "수식 attachment 미리보기"
        view.attributedText = Self.document(
            mode: mode,
            theme: theme,
            parsesDollarMath: parsesDollarMath,
            blockAlignment: blockAlignment,
            traitCollection: view.traitCollection
        )
        return view
    }

    func updateUIView(_ view: BlockDocumentUITextView, context: Context) {
        // attachment는 init 시점 테마를 캡처하므로 테마·모드·Dynamic Type 변경마다
        // 문서를 재구성한다. 읽기 전용이라 선택 보존 부담이 없다.
        view.attributedText = Self.document(
            mode: mode,
            theme: theme,
            parsesDollarMath: parsesDollarMath,
            blockAlignment: blockAlignment,
            traitCollection: view.traitCollection
        )
    }

    static func document(
        mode: AttachmentDemoView.Mode,
        theme: RichMarkdownTheme,
        parsesDollarMath: Bool,
        blockAlignment: BlockAlignmentConfiguration,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        switch mode {
        case .handBuilt:
            handBuiltDocument(
                theme: theme,
                parsesDollarMath: parsesDollarMath,
                blockAlignment: blockAlignment,
                traitCollection: traitCollection
            )
        case .styler:
            stylerDocument(
                theme: theme,
                parsesDollarMath: parsesDollarMath,
                blockAlignment: blockAlignment,
                traitCollection: traitCollection
            )
        }
    }

    /// 임의 UITextView 문서에 attachment를 직접 배치하는 경로.
    ///
    /// 확인 대상: ① 주변 폰트 descender 기준 인라인 baseline ② 긴 문단 줄바꿈에
    /// 걸친 인라인 수식 ③ display 수식의 블록 배치와 폭 clamp ④ `pointSize`가
    /// 주변 폰트(제목·본문)를 따라가는 계약 ⑤ `LatexInlineMathScanner`로 원문을
    /// 스캔해 attachment로 치환하는 경로 (`$` 토글 연동).
    static func handBuiltDocument(
        theme: RichMarkdownTheme,
        parsesDollarMath: Bool,
        blockAlignment: BlockAlignmentConfiguration = .default,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        let body = theme.bodyFont.resolvedUIFont(compatibleWith: traitCollection)
        let textColor = UIColor(theme.textColor)
        let result = NSMutableAttributedString()

        func attributes(font: UIFont) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: textColor]
        }
        func append(_ text: String, font: UIFont = body) {
            result.append(NSAttributedString(string: text, attributes: attributes(font: font)))
        }
        func appendHeading(_ text: String, level: Int) {
            let font = theme.headingFont(level: level).resolvedUIFont(
                compatibleWith: traitCollection
            )
            append(text, font: font)
        }
        // 인라인 수식 — attachment 문자에 주변 폰트의 `.font`를 함께 부여해야
        // attachmentBounds가 descender를 읽어 baseline을 맞춘다.
        func appendInline(_ latex: String, source: String? = nil, font: UIFont = body) {
            result.append(attachmentString(
                EquationTextAttachment(
                    latex: latex,
                    source: source ?? "\\(\(latex)\\)",
                    theme: theme,
                    isDisplay: false,
                    pointSize: font.pointSize
                ),
                attributes: attributes(font: font)
            ))
        }
        // 원문을 `LatexInlineMathScanner`로 스캔해 수식 span만 attachment로 치환한다.
        // `$` 구분자는 parsesDollarMath 토글을 따르고, 통화 표기는 걸러진다.
        func appendScanned(_ text: String, font: UIFont = body) {
            let spans = LatexInlineMathScanner.scan(
                text,
                parsesDollarMath: parsesDollarMath,
                excluding: []
            )
            let nsText = text as NSString
            var cursor = 0
            for span in spans {
                if span.range.location > cursor {
                    append(nsText.substring(
                        with: NSRange(location: cursor, length: span.range.location - cursor)
                    ), font: font)
                }
                appendInline(span.latex, source: span.source, font: font)
                cursor = NSMaxRange(span.range)
            }
            if cursor < nsText.length {
                append(nsText.substring(from: cursor), font: font)
            }
        }
        // display 수식 — isDisplay가 baseline을 줄 높이만큼 내려 블록처럼 배치한다.
        // 정렬은 메뉴에서 주입한 `BlockAlignmentConfiguration.equation`을 따른다.
        func appendDisplay(_ latex: String) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = blockAlignment.equation
            paragraph.paragraphSpacing = 12
            var displayAttributes = attributes(font: body)
            displayAttributes[.paragraphStyle] = paragraph
            result.append(attachmentString(
                EquationTextAttachment(
                    latex: latex,
                    source: "\\[ \(latex) \\]",
                    theme: theme,
                    isDisplay: true,
                    pointSize: body.pointSize
                ),
                attributes: displayAttributes
            ))
        }

        appendHeading("직접 구성 문서\n", level: 1)
        append("가우스 적분은 ")
        appendInline(#"e^{-x^2}"#)
        append(" 형태의 적분입니다. 한글 사이에 ")
        appendInline(#"\sqrt{x^2+1}"#)
        append(" 근호, ")
        appendInline(#"x_{i}^{2}"#)
        append(" 첨자, ")
        appendInline(#"\frac{a}{b}"#)
        append(" 분수를 섞어도 baseline이 맞아야 합니다. 이모지 🙂 옆의 ")
        appendInline(#"\alpha + \beta"#)
        append(" 도 확인하세요.\n")
        appendDisplay(#"\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}"#)

        append("\n")
        appendHeading("행렬과 급수\n", level: 2)
        append("display 수식은 문단 중앙에 블록으로 배치되고, 좁은 화면에서는 line fragment 폭 안으로 clamp됩니다.\n")
        appendDisplay(#"\det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc"#)
        append("\n")
        appendDisplay(#"e^{x} = \sum_{n=0}^{\infty} \frac{x^n}{n!}"#)

        append("\n")
        appendHeading("달러 수식 스캔 (토글 확인)\n", level: 2)
        append("아래 문단은 원문을 LatexInlineMathScanner로 스캔해 attachment로 치환합니다. 우측 상단 토글을 꺼서 비교하세요.\n")
        appendScanned("토글이 켜지면 $a + b$ 와 $x^2 + y^2 = z^2$ 는 수식, 꺼지면 그냥 텍스트입니다. 괄호 구분자 \\(\\alpha + \\beta\\) 는 토글과 무관하게 항상 수식입니다. 통화 표기 가격 $5 와 범위 $5 and $10 은 토글이 켜져도 텍스트로 보호됩니다.\n")

        append("\n")
        appendHeading("줄바꿈과 폰트 상속\n", level: 2)
        append("긴 한글 문단 안에서도 인라인 수식 ")
        appendInline(#"\lim_{n \to \infty} \frac{1}{n} = 0"#)
        append(" 의 baseline과 줄바꿈이 자연스러워야 합니다. 이 문단은 일부러 길게 써서 인라인 attachment가 줄 끝에 걸리는 경우를 만듭니다. 좌우 여백을 바꾸거나 기기를 회전해도 수식이 앞뒤 글자와 어긋나지 않는지 확인하세요.\n\n")

        let heading3 = theme.headingFont(level: 3).resolvedUIFont(
            compatibleWith: traitCollection
        )
        append("제목 크기 문맥의 ", font: heading3)
        appendInline(#"E = mc^2"#, font: heading3)
        append(" 수식은 pointSize가 주변 폰트를 따라 커집니다.\n\n", font: heading3)

        append("마지막으로 오일러 공식 ")
        appendInline(#"e^{i\pi} + 1 = 0"#)
        append(" 을 본문 크기로 확인합니다.")
        return result
    }

    /// 편집기 없는 읽기 전용 미리보기 — `MarkdownStyler.styledDocument` 단독 사용.
    static func stylerDocument(
        theme: RichMarkdownTheme,
        parsesDollarMath: Bool,
        blockAlignment: BlockAlignmentConfiguration = .default,
        traitCollection: UITraitCollection?
    ) -> NSAttributedString {
        let blocks = BlockEditorModel(markdown: seedMarkdown).blocks
        return MarkdownStyler.styledDocument(
            blocks,
            parsesDollarMath: parsesDollarMath,
            theme: theme,
            alignment: blockAlignment,
            traitCollection: traitCollection
        )
    }

    /// `MarkdownStyler`가 지원하는 블록·인라인 케이스를 한 문서에 모은 fixture.
    /// 제목 3단계, 인라인 서식 4종, 수식(괄호·달러·블록), 목록 3종과 중첩,
    /// 번호 연속, 인용, 코드 블록 리터럴, 통화 표기 보호, escape를 확인한다.
    static let seedMarkdown = #"""
    # 읽기 전용 미리보기

    편집기 없이 **블록 모델**을 스타일링합니다. *기울임*, ~~취소선~~,
    `인라인 코드` 칩과 인라인 수식 \( a^2 + b^2 = c^2 \), 달러 수식
    $e^{i\pi} + 1 = 0$ 을 함께 확인합니다.

    ## 달러 수식 (토글 확인)

    우측 상단 `$ 수식 파싱` 토글을 끄면 아래 달러 구분자는 전부 그냥 텍스트입니다.

    인라인: $a + b$ 그리고 $x^2 + y^2 = z^2$

    괄호 구분자 \( \alpha + \beta \) 는 토글과 무관하게 항상 수식입니다.

    ## 수식 블록

    피타고라스 정리 \( x^2 + y^2 = z^2 \) 다음에 블록 수식 두 개가 옵니다.

    \[ \det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc \]

    \[ \sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6} \]

    ## 목록과 들여쓰기

    - 순서 없는 항목 \(x_1\)
      - 중첩 항목 — 2칸 들여쓰기가 NSTextList 깊이로 반영됩니다
    - **굵은** 항목과 `코드` 칩

    1. 번호 목록 첫째
    2. 번호가 이어지는 둘째 \( \frac{d}{dx} x^n = n x^{n-1} \)

    - [ ] 미완료 할 일
    - [x] 완료한 할 일

    ### 인용·코드·보호 규칙

    > 인용문은 Notion처럼 본문 색을 유지하고 왼쪽 세로 바로 구분합니다.
    > 두 번째 줄까지 바가 이어지고, 수식 \( \frac{1}{n} \to 0 \) 도 함께 렌더됩니다.

    ```swift
    // 코드 블록은 리터럴 — **강조**도 $x$ 수식도 해석하지 않습니다
    let answer = 42
    ```

    통화 표기는 달러 수식 opt-in과 무관하게 텍스트입니다: 가격 $5 와 범위
    $5 and $10, escape한 \$100 도 그대로 보입니다. \*별표\* escape 해제도 확인.
    """#

    private static func attachmentString(
        _ attachment: NSTextAttachment,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }
}
