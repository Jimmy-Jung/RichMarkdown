// Created by JunyoungJung on 2026-08-24.

import Foundation
import SwiftLatex
import SwiftLatexBlockEditor
import Testing
import UIKit
@testable import SwiftLatexDemo

@Suite("데모 UI 컴포넌트", .serialized)
struct DemoComponentTests {
    @Test("키보드 툴바의 +는 블록 메뉴이고 Aa는 인라인 서식을 펼친다")
    @MainActor
    func keyboardToolbarUsesNotionButtonRoles() throws {
        var receivedActions: [String] = []
        let toolbar = BlockKeyboardToolbar(
            kind: .paragraph,
            canUndo: true,
            canRedo: true
        ) { action in
            switch action {
            case let .insert(kind):
                receivedActions.append("insert:\(kind.title)")
            case .format(.bold):
                receivedActions.append("bold")
            default:
                receivedActions.append("unexpected")
            }
        }

        if #available(iOS 26.0, *) {
            let surface = try #require(
                toolbar.subviews.compactMap { $0 as? UIVisualEffectView }.first
            )
            let glass = try #require(surface.effect as? UIGlassEffect)
            #expect(!glass.isInteractive)
        }

        func button(_ identifier: String, in view: UIView) -> UIButton? {
            if let button = view as? UIButton,
               button.accessibilityIdentifier == identifier {
                return button
            }
            return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
        }

        let addButton = try #require(button("blockToolbar.add", in: toolbar))
        let formatButton = try #require(button("blockToolbar.format", in: toolbar))
        let boldButton = try #require(button("blockToolbar.bold", in: toolbar))

        #expect(addButton.showsMenuAsPrimaryAction)
        #expect(addButton.menu?.children.count == 10)
        #expect(formatButton.menu == nil)
        #expect(boldButton.isHidden)

        formatButton.sendActions(for: .touchUpInside)
        #expect(!boldButton.isHidden)

        boldButton.sendActions(for: .touchUpInside)
        #expect(receivedActions == ["bold"])
    }
}

/// 수식 Attachment 데모의 문서 구성 검증.
@Suite("수식 Attachment 데모 문서")
struct AttachmentDemoDocumentTests {
    @Test("직접 구성 문서는 $ 토글에 따라 스캔 attachment 수가 달라진다")
    func handBuiltDocumentContainsAttachments() throws {
        func attachments(parsesDollarMath: Bool) -> [SwiftLatex.EquationTextAttachment] {
            let document = ReadOnlyEquationDocumentView.handBuiltDocument(
                theme: .default,
                parsesDollarMath: parsesDollarMath,
                traitCollection: nil
            )
            var result: [SwiftLatex.EquationTextAttachment] = []
            document.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: document.length)
            ) { value, _, _ in
                if let equation = value as? SwiftLatex.EquationTextAttachment {
                    result.append(equation)
                }
            }
            return result
        }

        // 토글 off: 직접 배치 8 + 스캔된 괄호 수식 1. 통화·달러는 텍스트.
        let off = attachments(parsesDollarMath: false)
        #expect(off.filter { !$0.isDisplay }.count == 9)
        #expect(off.filter(\.isDisplay).count == 3)

        // 토글 on: 달러 수식 2개가 추가되고 통화 표기($5, $5 and $10)는 여전히 텍스트.
        let on = attachments(parsesDollarMath: true)
        #expect(on.filter { !$0.isDisplay }.count == 11)
        #expect(on.filter(\.isDisplay).count == 3)
        #expect(on.contains { $0.source == "$a + b$" })
        #expect(!on.contains { $0.source.contains("$5") })

        // 제목 문맥의 인라인 수식은 pointSize가 주변 폰트를 따라 커진다.
        let bodyPointSize = LatexTheme.default.bodyFont
            .resolvedUIFont(compatibleWith: nil).pointSize
        let headingInline = try #require(
            on.first { $0.latex == #"E = mc^2"# }
        )
        #expect(headingInline.pointSize > bodyPointSize)
    }

    @Test("MarkdownStyler 문서는 수식 블록을 attachment로, 인라인 코드를 칩으로 렌더한다")
    func stylerDocumentRendersEquationsAndChips() throws {
        let document = ReadOnlyEquationDocumentView.stylerDocument(
            theme: .default,
            parsesDollarMath: true,
            traitCollection: nil
        )

        var hasEquationAttachment = false
        var hasInlineCodeChip = false
        document.enumerateAttributes(
            in: NSRange(location: 0, length: document.length)
        ) { attributes, _, _ in
            if attributes[.attachment] is SwiftLatex.EquationTextAttachment {
                hasEquationAttachment = true
            }
            if attributes[.inlineCodeChip] != nil {
                hasInlineCodeChip = true
            }
        }

        #expect(hasEquationAttachment)
        #expect(hasInlineCodeChip)
    }
}

/// UIKit 챗 데모의 셀 수명 회귀 (빠른 스크롤 왕복에서 빈 버블).
///
/// 화면 밖으로 나간 셀은 `prepareForReuse` 없이 reuse pool에 머물다가 다음 dequeue
/// 때에야 정리된다. 그 사이 같은 메시지가 다른 셀에 attach되면 캐시된 뷰가 새 셀로
/// 이사하는데, 이후 pooled 셀의 늦은 `prepareForReuse`가 뷰를 무조건
/// `removeFromSuperview`하면 화면에 보이는 셀에서 뷰를 뜯어내 빈 버블이 남는다.
@MainActor
@Suite struct UIKitChatCellReuseTests {

    @Test func stalePrepareForReuseDoesNotStealMovedMessageView() {
        let message = ChatMessage.answer("케이스", "재사용 검증 본문")
        let cache = AssistantMessageViewCache()
        let entry = cache.entry(for: message)
        let configuration = UIKitChatConfiguration()

        let frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        let cellX = AssistantMessageCell(frame: frame)
        cellX.configure(message, configuration: configuration, entry: entry)
        #expect(entry.view.isDescendant(of: cellX), "첫 셀에 뷰가 붙는다")

        // cellX가 화면 밖(reuse pool)에 있는 동안 같은 메시지가 다른 셀에 붙는다.
        let cellY = AssistantMessageCell(frame: frame)
        cellY.configure(message, configuration: configuration, entry: entry)
        #expect(entry.view.isDescendant(of: cellY), "뷰는 최신 셀로 이사한다")

        // pooled cellX가 다른 메시지용으로 재-dequeue될 때의 늦은 정리.
        cellX.prepareForReuse()

        #expect(
            entry.view.isDescendant(of: cellY),
            "늦은 prepareForReuse가 이사한 뷰를 화면의 셀에서 뜯어내면 안 된다"
        )
        #expect(entry.view.superview != nil)
    }

    /// 뷰가 아직 자기 셀에 있을 때의 prepareForReuse는 기존대로 뷰를 떼어낸다.
    @Test func prepareForReuseDetachesOwnedView() {
        let message = ChatMessage.answer("케이스", "정상 detach 본문")
        let cache = AssistantMessageViewCache()
        let entry = cache.entry(for: message)

        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        cell.configure(message, configuration: UIKitChatConfiguration(), entry: entry)
        #expect(entry.view.isDescendant(of: cell))

        cell.prepareForReuse()
        #expect(entry.view.superview == nil, "자기 셀의 뷰는 정상적으로 떼어낸다")
    }
}
