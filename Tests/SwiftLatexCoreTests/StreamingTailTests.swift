// Author: JunyoungJung
// Date: 2026-09-04

import Testing
@testable import SwiftLatexCore

/// 스트리밍 tail 표시 변환 계약. 파서를 통과한 실제 run으로 검사한다.
@Suite struct StreamingTailTests {

    private func runs(_ markdown: String, dollar: Bool = false) -> [InlineRun] {
        let document = SwiftLatexParser.parse(markdown: markdown, parsesDollarMath: dollar)
        for block in document.blocks {
            if case .paragraph(let runs) = block { return runs }
        }
        return []
    }

    private func plainText(_ runs: [InlineRun]) -> String {
        runs.map { run in
            switch run.content {
            case .text(let s), .code(let s): return s
            case .math(let segment): return segment.source
            case .link(let label, _): return label
            case .hardBreak: return "\n"
            case .softBreak: return " "
            }
        }.joined()
    }

    private func hidden(_ markdown: String, dollar: Bool = false) -> String {
        plainText(
            StreamingTail.hidingUnclosedOpeners(runs(markdown, dollar: dollar), parsesDollarMath: dollar)
        )
    }

    // MARK: - opener 억제

    @Test func stripsUnclosedOpenersAtTail() {
        #expect(hidden("다음 단계로는 **제가 선생님처") == "다음 단계로는 제가 선생님처")
        #expect(hidden("기울임 *시작") == "기울임 시작")
        #expect(hidden("셋 ***강조") == "셋 강조")
        #expect(hidden("취소 ~~선") == "취소 선")
        #expect(hidden("코드 `foo") == "코드 foo")
        #expect(hidden("코드 ``foo") == "코드 foo")
        #expect(hidden(#"수식 \(a+b"#) == "수식 a+b")
    }

    @Test func keepsMatchedOrNonFlankingMarks() {
        #expect(hidden("5 * 3") == "5 * 3")
        #expect(hidden("5*3") == "5*3")
        #expect(hidden(#"빈 수식 \(\) 뒤"#) == #"빈 수식 \(\) 뒤"#)
        #expect(hidden("물결 ~10% 상승") == "물결 ~10% 상승")
        #expect(hidden("snake_case 유지") == "snake_case 유지")
        #expect(hidden("굵게 **완료**") == "굵게 완료", "닫힌 강조는 별도 run이라 마지막 run에 opener가 없다")
    }

    @Test func dollarOpenerOnlyWhenDollarMathIsEnabledAndLooksLikeMath() {
        #expect(hidden("수식 $x^2", dollar: true) == "수식 x^2")
        #expect(hidden(#"수식 $\frac"#, dollar: true) == #"수식 \frac"#)
        #expect(hidden("수식 $x^2", dollar: false) == "수식 $x^2")
        #expect(hidden("가격 $5", dollar: true) == "가격 $5")
        #expect(hidden("가격 $ x", dollar: true) == "가격 $ x")
        #expect(hidden("$5 and $10", dollar: true) == "$5 and $10")
    }

    @Test func escapesAndLoneBackslash() {
        #expect(hidden(#"이스케이프 \$5 유지"#, dollar: true).contains("$5"))
        #expect(hidden(#"끝에 백슬래시 \"#) == "끝에 백슬래시 ")
        // 파서는 `\\`를 `\` 하나로 디코딩해 넘기므로 run 수준에서는 부분 `\(`와 구분되지 않는다.
        // raw 문자열에 두 개가 남아 있으면 이스케이프로 보고 유지한다.
        #expect(
            StreamingTail.strippingUnclosedOpeners(from: #"두 개 \\"#, parsesDollarMath: false)
                == #"두 개 \\"#
        )
    }

    @Test func emptyParagraphGuardAndRunRemoval() {
        let lone = runs("**")
        #expect(
            StreamingTail.hidingUnclosedOpeners(lone, parsesDollarMath: false) == lone,
            "문단 전체가 비는 억제는 건너뛴다"
        )

        let bolded = runs("**굵게**\n**")
        let result = StreamingTail.hidingUnclosedOpeners(bolded, parsesDollarMath: false)
        #expect(bolded.count == 3)
        #expect(result.count == 2, "마지막 run만 비면 그 run을 지운다")
        #expect(result.first?.bold == true)
        #expect(result.last?.content == .softBreak)
    }

    // MARK: - 꼬리 페이드

    @Test func fadeAnchorsToTheEndRegardlessOfLength() {
        let source = "가나다라마바사아자차카타파하 가나다라마바사아자차카타파하"
        let long = StreamingTail.fadePlan(runs(source), graphemeCount: 12)
        #expect(long.tail.count == 12)
        #expect(long.tail.last?.alpha == StreamingTail.minimumAlpha)
        #expect(long.tail.first!.alpha > long.tail.last!.alpha)
        #expect(plainText(long.head) + long.tail.map(\.text).joined() == source)

        let short = StreamingTail.fadePlan(runs("가나다"), graphemeCount: 12)
        #expect(short.head.isEmpty)
        #expect(short.tail.count == 3)
        #expect(short.tail.last?.alpha == StreamingTail.minimumAlpha)
        #expect(short.tail.first!.alpha > short.tail.last!.alpha)
    }

    @Test func fadeSpansTrailingTextRunsAndKeepsStyle() {
        // "굵은텍스트"(5) + "끝"(1) = 6 grapheme가 페이드 예산을 채우고 "앞 "은 head에 남는다.
        let plan = StreamingTail.fadePlan(runs("앞 **굵은텍스트**끝"), graphemeCount: 6)
        #expect(plan.tail.count == 6)
        #expect(plan.tail.prefix(5).allSatisfy { $0.run.bold })
        #expect(plan.tail.last?.run.bold == false)
        #expect(plan.head.count == 1)
        #expect(plainText(plan.head) == "앞 ")
    }

    @Test func fadeStopsAtNonTextRuns() {
        let mathTail = StreamingTail.fadePlan(runs(#"본문 \(x^2\)"#), graphemeCount: 12)
        #expect(mathTail.tail.isEmpty)
        #expect(mathTail.head.count == 2)

        let codeTail = StreamingTail.fadePlan(runs("본문 `code`"), graphemeCount: 12)
        #expect(codeTail.tail.isEmpty)

        let breakThenEmpty = StreamingTail.hidingUnclosedOpeners(runs("첫 줄\n**"), parsesDollarMath: false)
        let plan = StreamingTail.fadePlan(breakThenEmpty, graphemeCount: 12)
        #expect(plan.tail.isEmpty, "break 뒤가 비면 앞 줄을 페이드하지 않는다")
    }

    @Test func fadeCountsGraphemeClusters() {
        let plan = StreamingTail.fadePlan(runs("가나다👨‍👩‍👧"), graphemeCount: 12)
        #expect(plan.tail.count == 4)
        #expect(plan.tail.last?.text == "👨‍👩‍👧")
    }

    @Test func zeroCountDisablesFade() {
        let original = runs("텍스트")
        let plan = StreamingTail.fadePlan(original, graphemeCount: 0)
        #expect(plan.head == original)
        #expect(plan.tail.isEmpty)
    }

    @Test func alphaRampIsMonotonic() {
        let alphas = (0..<12).map { StreamingTail.alpha(atDistance: $0, count: 12) }
        #expect(alphas.first == StreamingTail.minimumAlpha)
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 < $1 })
        #expect(StreamingTail.alpha(atDistance: 12, count: 12) == 1)
    }
}
