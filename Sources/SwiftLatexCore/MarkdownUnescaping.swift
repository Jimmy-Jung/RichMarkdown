import Foundation

/// Markdown backslash escape 해제.
///
/// 2차 파싱 결과의 Text 노드는 원문 slice로 되돌려 쓴다(수식 mask 복원 때문).
/// 그래서 파서가 해 주는 escape 해제가 사라진다. span 밖 텍스트에만 직접 적용한다.
/// 수식 span source는 원래 구분자를 보존해야 하므로 건드리지 않는다.
package extension String {
    /// CommonMark escapable ASCII punctuation 앞의 backslash 하나를 제거한다.
    /// `\\`는 `\`가 되고, punctuation이 아닌 문자 앞의 backslash는 유지한다.
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

    private static let escapablePunctuation: Set<Character> = Set(
        ##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##
    )
}
