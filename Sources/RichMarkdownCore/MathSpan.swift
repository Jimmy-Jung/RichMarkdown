import Foundation

/// 수식 구분자 종류. DEVELOPMENT.md §3 delimiter 규칙.
package enum MathKind: Sendable, Hashable {
    case inlineParen      // \( ... \)
    case displayBracket   // \[ ... \]  (공백 제외 paragraph 전체일 때만)
    case inlineDollar     // $ ... $    (opt-in)
    case displayDollar    // $$ ... $$  (opt-in, paragraph 전체)
    case inlineDoubleDollar // $$ ... $$ (opt-in .inlineDouble, 문장 안)

    package var isDisplay: Bool {
        switch self {
        case .displayBracket, .displayDollar: return true
        case .inlineParen, .inlineDollar, .inlineDoubleDollar: return false
        }
    }
}

/// opt-in dollar 수식 범위. DEVELOPMENT.md §3 delimiter 규칙.
package struct DollarMathOptions: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `$...$` inline과 paragraph 전체 `$$...$$` block. 기존 `parsesDollarMath: true`와 같다.
    package static let single = DollarMathOptions(rawValue: 1 << 0)
    /// 문장 안 `$$...$$`를 inline 수식으로 해석한다.
    package static let inlineDouble = DollarMathOptions(rawValue: 1 << 1)

    package init(parsesDollarMath: Bool) { self = parsesDollarMath ? [.single] : [] }
}

/// 보호 버퍼로 마스킹되는 수식 span. 원문 UTF-8 range와 delimiter 포함 source를 보존한다.
package struct ProtectedMathSpan: Sendable, Hashable {
    package let originalUTF8Range: Range<Int>
    package let kind: MathKind
    /// 원래 구분자를 포함한 원문 source. 실패 시 이 문자열을 그대로 표시한다.
    package let source: String

    package init(originalUTF8Range: Range<Int>, kind: MathKind, source: String) {
        self.originalUTF8Range = originalUTF8Range
        self.kind = kind
        self.source = source
    }

    /// 수식 renderer에 넘길 delimiter 제거 LaTeX.
    package var latex: String {
        let dropCount: (leading: Int, trailing: Int)
        switch kind {
        case .inlineParen, .displayBracket: dropCount = (2, 2)
        case .displayDollar, .inlineDoubleDollar: dropCount = (2, 2)
        case .inlineDollar: dropCount = (1, 1)
        }
        // 문자 묶음이 아니라 스칼라 단위로 구분자를 뗀다. `$` 뒤 결합 문자(`$\u{301}`)는 한 문자 묶음이라
        // dropFirst가 결합 문자까지 지웠다(퍼즈 패리티, Android는 UTF-16 단위). 구분자는 모두 ASCII 한 스칼라다.
        let scalars = source.unicodeScalars
        guard scalars.count >= dropCount.leading + dropCount.trailing else { return "" }
        let inner = String(String.UnicodeScalarView(scalars.dropFirst(dropCount.leading).dropLast(dropCount.trailing)))
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 내부 diagnostic. 미완성/빈/중첩 delimiter 등은 plain text로 두고 여기 기록한다.
package struct MathDiagnostic: Sendable, Hashable {
    package enum Kind: Sendable, Hashable {
        case unterminatedDelimiter
        case emptyMath
        case nestedDelimiter
        case oversizedMathSource
        case nonParagraphDisplayDelimiter
    }
    package let kind: Kind
    /// 해당 원문 수식 span 전체에 연결한다.
    package let utf8Range: Range<Int>
}
