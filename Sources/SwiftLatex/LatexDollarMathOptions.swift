// Author: JunyoungJung
// Date: 2026-09-04

import SwiftLatexCore

/// opt-in dollar 수식 범위. `[]`면 `\(...\)`·`\[...\]`만 해석한다.
///
/// ```swift
/// LatexMarkdownView(markdown: text, dollarMath: [.single, .inlineDouble])
/// ```
public struct LatexDollarMathOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `$...$` inline과 paragraph 전체 `$$...$$` block. `parsesDollarMath: true`와 같다.
    public static let single = LatexDollarMathOptions(rawValue: 1 << 0)
    /// 문장 안 `$$...$$`를 inline 수식으로 해석한다. `$...$`와 같은 공백·숫자·줄바꿈 규칙을 따른다.
    /// 기본값이 아닌 이유: `$$5 and $$6` 같은 표기와 충돌할 수 있어 호출자가 켠다.
    public static let inlineDouble = LatexDollarMathOptions(rawValue: 1 << 1)

    /// 기존 Bool API와의 대응. `true` → `[.single]`, `false` → `[]`.
    public init(parsesDollarMath: Bool) { self = parsesDollarMath ? [.single] : [] }

    var core: DollarMathOptions {
        var options: DollarMathOptions = []
        if contains(.single) { options.insert(.single) }
        if contains(.inlineDouble) { options.insert(.inlineDouble) }
        return options
    }
}
