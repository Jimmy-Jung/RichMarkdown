import Foundation

/// Markdown backslash escape 해제.
///
/// 2차 파싱 결과의 Text 노드는 원문 slice로 되돌려 쓴다(수식 mask 복원 때문).
/// 그래서 파서가 해 주는 escape 해제가 사라진다. span 밖 텍스트에만 직접 적용한다.
/// 수식 span source는 원래 구분자를 보존해야 하므로 건드리지 않는다.
///
/// 수식 구분자 문자(`(`, `)`, `[`, `]`)는 해제하지 않는다. 수식으로 인식되지 않은
/// `\(x + y`나 `\[x+y\]`에서 backslash를 벗기면 사용자가 무엇을 썼는지 알 수 없고,
/// "잘못되거나 미완성인 LaTeX는 원래 구분자를 포함한 source를 표시한다"는 계약이
/// 깨진다. `\\(`처럼 backslash를 escape한 경우는 `\\` → `\` 접힘으로 처리되어
/// 의도한 리터럴 `\(`가 남는다.
package extension String {
    /// escapable ASCII punctuation 앞의 backslash 하나를 제거한다.
    /// `\\`는 `\`가 되고, punctuation이 아닌 문자와 수식 구분자 앞의 backslash는 유지한다.
    func unescapingMarkdownPunctuation() -> String {
        guard contains("\\") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var iterator = self.startIndex
        while iterator < endIndex {
            let character = self[iterator]
            let next = index(after: iterator)
            if character == "\\", next < endIndex, Self.escapablePunctuation.contains(self[next]) {
                result.append(self[next])
                iterator = index(after: next)
                continue
            }
            result.append(character)
            iterator = next
        }
        return result
    }

    /// CommonMark escapable punctuation에서 수식 구분자 `(`, `)`, `[`, `]`를 뺀 집합.
    private static let escapablePunctuation: Set<Character> = Set(
        ##"!"#$%&'*+,-./:;<=>?@\^_`{|}~"##
    )
}
