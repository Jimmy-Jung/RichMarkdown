// Author: JunyoungJung
// Date: 2026-09-04

import Foundation

/// 스트리밍 중 tail 문단(마지막 리프 문단·헤딩)의 **표시 전용** 변환.
///
/// 파싱 결과는 바꾸지 않는다. 렌더러가 표시 직전에 마지막 `.text` run만 손본다.
/// - 미닫힌 opener 억제: swift-markdown이 짝 없는 `**`·백틱·`\(`를 literal로 내보내므로,
///   closer가 도착하기 전까지 그 토큰만 숨긴다. closer가 오면 재파싱이 Strong·code·math로 바꾼다.
/// - 꼬리 페이드: 마지막 N grapheme의 alpha를 끝으로 갈수록 낮춰 도착 위치를 보인다.
package enum StreamingTail {
    package struct Piece: Equatable, Sendable {
        package let run: InlineRun
        package let text: String
        package let alpha: Double

        package init(run: InlineRun, text: String, alpha: Double) {
            self.run = run
            self.text = text
            self.alpha = alpha
        }
    }

    package struct FadePlan: Equatable, Sendable {
        /// 그대로 렌더하는 앞부분.
        package let head: [InlineRun]
        /// 끝에서부터 alpha를 적용하는 grapheme 조각. 앞→뒤 순서.
        package let tail: [Piece]
    }

    /// 마지막 grapheme은 텍스트 길이와 무관하게 항상 이 값이라 tick마다 흔들리지 않는다.
    static let minimumAlpha = 0.2

    // MARK: - 미닫힌 opener 억제

    /// 마지막 `.text` run에서 짝 없는 opener 토큰을 모두 표시에서 지운다.
    /// 문단 전체가 비게 되면 지우지 않는다(높이 0으로 튀는 프레임 방지).
    package static func hidingUnclosedOpeners(
        _ runs: [InlineRun],
        parsesDollarMath: Bool
    ) -> [InlineRun] {
        hidingUnclosedOpeners(runs, dollarMath: DollarMathOptions(parsesDollarMath: parsesDollarMath))
    }

    package static func hidingUnclosedOpeners(
        _ runs: [InlineRun],
        dollarMath: DollarMathOptions
    ) -> [InlineRun] {
        guard let last = runs.last, case .text(let string) = last.content else { return runs }
        let stripped = strippingUnclosedOpeners(from: string, dollarMath: dollarMath)
        guard stripped != string else { return runs }

        var result = runs
        if stripped.isEmpty {
            guard runs.count > 1 else { return runs }
            result.removeLast()
        } else {
            var run = last
            run.content = .text(stripped)
            result[result.count - 1] = run
        }
        return result
    }

    /// 한 literal text run 안의 opener 판정. 같은 run 안에서 짝지을 수 있었던 토큰은 파서가 이미
    /// Strong·code·math로 바꿨으므로, 남은 opener는 대부분 미매칭이다. 예외(`\(\)`, `$5 and $10`)만
    /// "뒤에 closer 없음" 검사로 걸러낸다.
    static func strippingUnclosedOpeners(from string: String, parsesDollarMath: Bool) -> String {
        strippingUnclosedOpeners(from: string, dollarMath: DollarMathOptions(parsesDollarMath: parsesDollarMath))
    }

    static func strippingUnclosedOpeners(from string: String, dollarMath: DollarMathOptions) -> String {
        let chars = Array(string)
        var kept: [Character] = []
        kept.reserveCapacity(chars.count)
        var index = 0
        // closer 존재 여부는 마지막 위치 사전계산으로 O(1)에 판정한다. tail 문단은 tick마다
        // 전체를 다시 스캔하므로 `$`·백틱이 많은 문단에서 O(n²)로 미끄러지지 않게 한다.
        let lastDollar = chars.lastIndex(of: "$")
        let lastDoubleDollar = lastStart(ofSequence: ["$", "$"], in: chars)
        let lastCloseParen = lastStart(ofSequence: ["\\", ")"], in: chars)
        let lastBacktickRunStart = lastBacktickRunStarts(in: chars)

        func character(at offset: Int) -> Character? {
            offset < chars.count ? chars[offset] : nil
        }

        func isLeftFlanking(after end: Int) -> Bool {
            guard let next = character(at: end) else { return true }
            return !next.isWhitespace
        }

        while index < chars.count {
            let current = chars[index]

            if current == "\\" {
                guard let next = character(at: index + 1) else {
                    // 문단 끝에 홀로 남은 백슬래시는 `\(` 같은 토큰의 앞 절반이다.
                    index += 1
                    continue
                }
                if next == "(", !(lastCloseParen.map { $0 >= index + 2 } ?? false) {
                    index += 2
                    continue
                }
                // `\$`·`\*`·`\\` 같은 이스케이프는 그대로 둔다.
                kept.append(current)
                kept.append(next)
                index += 2
                continue
            }

            if current == "*" {
                let runLength = repeatCount(of: "*", in: chars, from: index)
                let end = index + runLength
                let previousIsDigit = kept.last?.isNumber == true
                let nextIsDigit = character(at: end)?.isNumber == true
                if runLength <= 3, isLeftFlanking(after: end), !(previousIsDigit && nextIsDigit) {
                    index = end
                    continue
                }
                kept.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            if current == "~", character(at: index + 1) == "~" {
                let end = index + 2
                if isLeftFlanking(after: end) {
                    index = end
                    continue
                }
                kept.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            if current == "`" {
                let runLength = repeatCount(of: "`", in: chars, from: index)
                let end = index + runLength
                if !(lastBacktickRunStart[runLength].map { $0 >= end } ?? false) {
                    index = end
                    continue
                }
                kept.append(contentsOf: chars[index..<end])
                index = end
                continue
            }

            if current == "$", !dollarMath.isEmpty {
                // `$$` opener는 `.inlineDouble`일 때만 미닫힌 마크다. 그 외 `$$`는 그대로 둔다.
                if character(at: index + 1) == "$" {
                    if dollarMath.contains(.inlineDouble) {
                        let after = character(at: index + 2)
                        let opensMath = after.map { !$0.isWhitespace && !$0.isNumber && $0 != "$" } ?? true
                        let hasLaterDoubleDollar = lastDoubleDollar.map { $0 >= index + 2 } ?? false
                        if opensMath, !hasLaterDoubleDollar {
                            index += 2
                            continue
                        }
                    }
                    kept.append(contentsOf: chars[index..<(index + 2)])
                    index += 2
                    continue
                }
                if dollarMath.contains(.single) {
                    let next = character(at: index + 1)
                    let opensMath = next.map { !$0.isWhitespace && !$0.isNumber } ?? true
                    let hasLaterDollar = lastDollar.map { $0 > index } ?? false
                    if opensMath, !hasLaterDollar {
                        index += 1
                        continue
                    }
                }
                kept.append(current)
                index += 1
                continue
            }

            kept.append(current)
            index += 1
        }
        return String(kept)
    }

    private static func repeatCount(of character: Character, in chars: [Character], from start: Int) -> Int {
        var end = start
        while end < chars.count, chars[end] == character { end += 1 }
        return end - start
    }

    /// `sequence`가 마지막으로 시작하는 위치.
    private static func lastStart(ofSequence sequence: [Character], in chars: [Character]) -> Int? {
        guard sequence.count <= chars.count else { return nil }
        var index = chars.count - sequence.count
        while index >= 0 {
            if Array(chars[index..<(index + sequence.count)]) == sequence { return index }
            index -= 1
        }
        return nil
    }

    /// 백틱 연속 길이별 마지막 시작 위치. 정확히 같은 길이의 연속이 뒤에 있으면 code span이 닫힌 것이다.
    private static func lastBacktickRunStarts(in chars: [Character]) -> [Int: Int] {
        var starts: [Int: Int] = [:]
        var index = 0
        while index < chars.count {
            if chars[index] == "`" {
                let run = repeatCount(of: "`", in: chars, from: index)
                starts[run] = index
                index += run
            } else {
                index += 1
            }
        }
        return starts
    }

    // MARK: - 꼬리 페이드

    /// 끝에서부터 연속한 `.text` run을 grapheme 조각으로 나눈다.
    /// break·math·code·link를 만나면 멈춘다 — 커서가 그 뒤에 있지 않다.
    package static func fadePlan(_ runs: [InlineRun], graphemeCount: Int) -> FadePlan {
        guard graphemeCount > 0 else { return FadePlan(head: runs, tail: []) }

        var head = runs
        var tail: [Piece] = []
        var distanceFromEnd = 0

        while distanceFromEnd < graphemeCount,
              let last = head.last,
              case .text(let string) = last.content {
            let graphemes = Array(string)
            let budget = graphemeCount - distanceFromEnd
            let faded = Array(graphemes.suffix(budget))
            let remaining = graphemes.dropLast(faded.count)

            var pieces: [Piece] = []
            pieces.reserveCapacity(faded.count)
            for (offset, grapheme) in faded.enumerated() {
                // faded의 마지막 원소가 끝에서 거리 distanceFromEnd다.
                let distance = distanceFromEnd + (faded.count - 1 - offset)
                pieces.append(
                    Piece(
                        run: last,
                        text: String(grapheme),
                        alpha: alpha(atDistance: distance, count: graphemeCount)
                    )
                )
            }
            tail.insert(contentsOf: pieces, at: 0)
            distanceFromEnd += faded.count

            head.removeLast()
            if !remaining.isEmpty {
                var prefix = last
                prefix.content = .text(String(remaining))
                head.append(prefix)
                break
            }
        }

        return FadePlan(head: head, tail: tail)
    }

    /// `distance` = 끝에서부터 grapheme 거리(0 = 마지막). N 이상이면 원래 색.
    /// 마지막 grapheme이 정확히 `minimumAlpha`가 되도록 최소값에서 더해 올린다(부동소수 오차 방지).
    static func alpha(atDistance distance: Int, count: Int) -> Double {
        guard distance < count else { return 1 }
        return minimumAlpha + (1 - minimumAlpha) * Double(distance) / Double(count)
    }
}
