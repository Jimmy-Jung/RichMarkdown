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

/// SSE 실시간 렌더링 데모의 프레임 디코더 검증.
///
/// 디코더가 동기 상태 머신이라 네트워크·타이머 없이 줄 단위로 전부 확인한다.
@Suite("SSE 디코더")
struct SSEDecoderTests {
    /// 줄들을 순서대로 넣고 완성된 이벤트만 모은다.
    private func events(_ lines: [String]) -> [SSEDecoder.Event] {
        var decoder = SSEDecoder()
        return lines.compactMap { decoder.consume($0) }
    }

    @Test("OpenAI 호환 델타에서 content를 뽑는다")
    func decodesOpenAICompatibleDelta() {
        let lines = [#"data: {"choices":[{"delta":{"content":"안녕"}}]}"#, ""]
        #expect(events(lines) == [.text("안녕")])
    }

    @Test("Anthropic content_block_delta에서 text를 뽑는다")
    func decodesAnthropicDelta() {
        // JSON의 `\\(`는 디코딩되면 LaTeX 구분자 `\(`가 된다.
        let lines = [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\\(x\\)"}}"#,
            "",
        ]
        #expect(events(lines) == [.text(#"\(x\)"#)])
    }

    @Test("JSON이 아닌 payload는 순수 텍스트 SSE로 다룬다")
    func decodesPlainTextPayload() {
        #expect(events(["data: hello world", ""]) == [.text("hello world")])
    }

    @Test("한 이벤트의 여러 data 줄은 개행으로 이어 붙인다")
    func joinsMultipleDataLinesWithNewline() {
        #expect(events(["data: 첫 줄", "data: 둘째 줄", ""]) == [.text("첫 줄\n둘째 줄")])
    }

    @Test("주석과 빈 이벤트는 무시하고 [DONE]에서 끝난다")
    func ignoresCommentsAndEndsOnDone() {
        let lines = [": heartbeat", "", "data: 조각", "", "data: [DONE]", ""]
        #expect(events(lines) == [.text("조각"), .done])
    }

    @Test("텍스트 없는 델타는 이벤트를 만들지 않는다")
    func ignoresTextlessDeltas() {
        let lines = [#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, ""]
        #expect(events(lines).isEmpty, "role 청크는 텍스트가 없어 무시된다")
    }

    @Test("OpenAI completions·Responses·content-part 배열에서도 텍스트를 뽑는다")
    func decodesOtherGatewayShapes() {
        #expect(events([#"data: {"choices":[{"text":"안녕","index":0}]}"#, ""]) == [.text("안녕")])
        #expect(
            events([#"data: {"type":"response.output_text.delta","delta":"안녕"}"#, ""])
                == [.text("안녕")]
        )
        #expect(
            events([#"data: {"choices":[{"delta":{"content":[{"type":"text","text":"안녕"}]}}]}"#, ""])
                == [.text("안녕")]
        )
    }

    @Test("서버 오류 payload는 조용히 무시하지 않고 failure로 올린다")
    func surfacesServerErrorPayload() {
        #expect(
            events([#"data: {"error":{"message":"rate limit","type":"server_error"}}"#, ""])
                == [.failure("rate limit")]
        )
        #expect(events([#"data: {"error":"overloaded"}"#, ""]) == [.failure("overloaded")])
    }

    @Test("잘린 JSON 조각은 답변에 섞지 않는다")
    func dropsTruncatedJSONPayload() {
        // 줄이 반토막 난 경우. 순수 텍스트 SSE fallback이 이걸 화면에 넣으면 안 된다.
        #expect(events([#"data: {"choices":[{"delta":{"content":"x"#, ""]).isEmpty)
    }

    @Test("[DONE]은 앞뒤 공백이 붙어도 종료로 본다", arguments: ["data: [DONE]", "data:[DONE]", "data:  [DONE]", "data: [DONE] "])
    func acceptsDoneVariants(line: String) {
        #expect(events([line, ""]) == [.done])
    }

    @Test("시뮬레이션 프레임을 모두 통과시키면 원문이 그대로 복원된다")
    func fixtureFramesRoundTripToOriginalAnswer() {
        var decoder = SSEDecoder()
        var restored = ""
        var finished = false

        for line in SSEDemoFixtures.frames().flatMap({ $0 }) {
            switch decoder.consume(line) {
            case let .text(delta): restored += delta
            case .done: finished = true
            case let .failure(message): Issue.record("시뮬레이션에 오류 이벤트가 없어야 한다: \(message)")
            case nil: break
            }
        }

        #expect(finished, "마지막 프레임은 [DONE]이다")
        #expect(restored == SSEDemoFixtures.answer)
    }

    @Test("청크는 Character 경계로 자른다", arguments: [1, 6, 64])
    func chunksPreserveGraphemeClusters(size: Int) {
        let text = "가나🇰🇷e\u{0301}abc \\(x^2\\)"
        let chunks = SSEDemoFixtures.chunks(of: text, size: size)

        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.count <= size })
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("chunkSize가 0 이하이면 자르지 않는다")
    func chunksRejectNonPositiveSize() {
        #expect(SSEDemoFixtures.chunks(of: "abc", size: 0) == ["abc"])
        #expect(SSEDemoFixtures.chunks(of: "", size: 0).isEmpty)
    }
}

/// 바이트 → 줄 분리 계약. `Foundation.AsyncLineSequence`가 빈 줄을 버려
/// 실제 엔드포인트에서 이벤트가 한 번도 dispatch되지 않던 결함의 회귀 테스트다.
@Suite("SSE 줄 분리기")
struct SSELineSplitterTests {
    /// 문자열을 바이트로 흘려 나온 줄들과, 스트림 종료 시 남은 조각을 함께 돌려준다.
    private func split(_ raw: String) -> (lines: [String], leftover: String?) {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array(raw.utf8) {
            if let line = splitter.consume(byte) { lines.append(line) }
        }
        return (lines, splitter.flush())
    }

    @Test("빈 줄을 보존한다 — 빈 줄이 SSE의 이벤트 경계다")
    func preservesBlankLines() {
        let result = split("data: a\n\ndata: b\n\n")
        #expect(result.lines == ["data: a", "", "data: b", ""])
        #expect(result.leftover == nil)
    }

    @Test("LF·CRLF·CR 세 종류 줄 끝을 모두 처리한다", arguments: ["\n", "\r\n", "\r"])
    func handlesAllLineTerminators(terminator: String) {
        let result = split("data: a\(terminator)\(terminator)")
        #expect(result.lines == ["data: a", ""])
    }

    @Test("스트림 선두의 BOM만 제거한다")
    func stripsLeadingByteOrderMarkOnce() {
        let result = split("\u{FEFF}data: a\ndata: \u{FEFF}b\n")
        #expect(result.lines == ["data: a", "data: \u{FEFF}b"])
    }

    @Test("개행 없이 끝난 마지막 조각은 flush로 나온다")
    func flushReturnsTrailingFragment() {
        let result = split("data: a")
        #expect(result.lines.isEmpty)
        #expect(result.leftover == "data: a")
    }

    @Test("개행이 없어도 한 줄이 상한을 넘으면 끊는다")
    func capsUnboundedLine() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in Array(repeating: UInt8(ascii: "a"), count: SSELineSplitter.maxLineBytes + 10) {
            if let line = splitter.consume(byte) { lines.append(line) }
        }
        #expect(lines.count == 1)
        #expect(lines.first?.count == SSELineSplitter.maxLineBytes)
    }

    @Test("바이트 스트림을 끝까지 통과시키면 델타와 [DONE]이 모두 도착한다")
    func rawByteStreamRoundTripsThroughDecoder() {
        let raw = "\u{FEFF}: heartbeat\r\n\r\n"
            + #"data: {"choices":[{"delta":{"content":"안녕 "}}]}"# + "\r\n\r\n"
            + #"data: {"choices":[{"delta":{"content":"\\(x^2\\)"}}]}"# + "\n\n"
            + "data: [DONE]\n\n"

        var splitter = SSELineSplitter()
        var decoder = SSEDecoder()
        var events: [SSEDecoder.Event] = []
        for byte in Array(raw.utf8) {
            guard let line = splitter.consume(byte) else { continue }
            if let event = decoder.consume(line) { events.append(event) }
        }

        #expect(events == [.text("안녕 "), .text(#"\(x^2\)"#), .done])
    }

    @Test("종료 blank line 없이 끊긴 스트림도 마지막 조각을 잃지 않는다")
    func finishFlushesPendingEvent() {
        var splitter = SSELineSplitter()
        var decoder = SSEDecoder()
        var events: [SSEDecoder.Event] = []
        for byte in Array((#"data: {"choices":[{"delta":{"content":"끝"}}]}"# + "\n").utf8) {
            guard let line = splitter.consume(byte) else { continue }
            if let event = decoder.consume(line) { events.append(event) }
        }
        #expect(events.isEmpty, "blank line이 없으면 아직 dispatch되지 않는다")

        if let event = decoder.finish() { events.append(event) }
        #expect(events == [.text("끝")])
    }
}
