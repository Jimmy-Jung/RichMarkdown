import SwiftUI
import UIKit

/// 코드 블록 확장점 (DEVELOPMENT.md §2).
///
/// 코어는 프로토콜만 선언하고 구현은 별도 product가 담당한다. `RichMarkdown`만 쓰는 앱은
/// JavaScriptCore도 WebKit도, 3 MB 넘는 JavaScript 번들도 링크하지 않는다.
///
/// ```swift
/// RichMarkdownView(markdown: message)
///     .richMarkdownCodeBlocks(.init(highlighter: PrismHighlighter.shared, diagram: MermaidDiagramRenderer.shared))
/// ```
public struct RichMarkdownCodeBlockOptions: Sendable, Equatable {
    /// 코드 블록 본문에 색 역할을 부여한다. `nil`이면 지금까지처럼 plain monospace다.
    public var highlighter: (any RichMarkdownSyntaxHighlighting)?
    /// 담당 언어의 코드 블록을 다이어그램 뷰로 대체한다.
    public var diagram: (any RichMarkdownDiagramRendering)?

    public init(
        highlighter: (any RichMarkdownSyntaxHighlighting)? = nil,
        diagram: (any RichMarkdownDiagramRendering)? = nil
    ) {
        self.highlighter = highlighter
        self.diagram = diagram
    }

    /// 아무 확장도 걸지 않은 기본값.
    public static let none = RichMarkdownCodeBlockOptions()

    /// 이 코드 블록 언어를 담당하는 다이어그램 렌더러. 없으면 `nil`이다.
    func diagramRenderer(for language: String?) -> (any RichMarkdownDiagramRendering)? {
        guard let diagram, let language,
              diagram.languages.contains(language.lowercased())
        else { return nil }
        return diagram
    }

    /// 두 확장 모두 참조 타입이라 동일 인스턴스 여부로 비교한다. 구현체의 내부 상태
    /// (JSContext, 이미지 캐시)는 값 비교 대상이 아니다.
    public static func == (lhs: RichMarkdownCodeBlockOptions, rhs: RichMarkdownCodeBlockOptions) -> Bool {
        lhs.highlighter === rhs.highlighter && lhs.diagram === rhs.diagram
    }
}

// MARK: - 신택스 하이라이팅

/// 표시 역할. 엔진의 토큰 이름이 아니라 테마가 색을 붙이는 단위다.
/// 엔진마다 토큰 분류가 다르므로 구현체가 이 7종으로 정규화한다.
public enum RichMarkdownHighlightKind: String, Sendable, Hashable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case property
}

/// 원문의 UTF-16 범위 + 역할. 원문 자체는 절대 바꾸지 않는다 —
/// 실패 시 원문을 표시하는 v1 원칙(DEVELOPMENT.md §1)을 하이라이팅에도 그대로 적용한다.
public struct RichMarkdownHighlightSpan: Sendable, Hashable {
    public let range: NSRange
    public let kind: RichMarkdownHighlightKind

    public init(range: NSRange, kind: RichMarkdownHighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// 코드 블록 하이라이터. 구현은 `RichMarkdownHighlight`의 `PrismHighlighter`다.
///
/// 동기 호출이 아니다: 토큰화는 렌더러의 MainActor 밖에서 끝내고, 도착한 범위만
/// 색으로 반영한다. 미지원 언어와 실패는 **빈 배열**이며 오류를 던지지 않는다.
public protocol RichMarkdownSyntaxHighlighting: AnyObject, Sendable {
    func spans(for code: String, language: String) async -> [RichMarkdownHighlightSpan]
}

// MARK: - 다이어그램

/// 특정 언어의 코드 블록을 통째로 대체하는 뷰 공급자.
/// 구현은 `RichMarkdownMermaid`의 `MermaidDiagramRenderer`다.
public protocol RichMarkdownDiagramRendering: AnyObject, Sendable {
    /// 담당하는 코드 블록 언어 (소문자). 예: `["mermaid"]`.
    var languages: Set<String> { get }

    /// UIKit 렌더러용 뷰. 높이가 확정·변경될 때마다 `onSizeChange`를 호출해야
    /// 셀 self-sizing이 다시 측정된다.
    @MainActor
    func makeUIView(
        source: String,
        theme: RichMarkdownTheme,
        onSizeChange: @escaping @MainActor () -> Void
    ) -> UIView

    /// SwiftUI 렌더러용 뷰.
    @MainActor
    func makeSwiftUIView(source: String, theme: RichMarkdownTheme) -> AnyView
}

// MARK: - 주입

private struct RichMarkdownCodeBlockOptionsKey: EnvironmentKey {
    static let defaultValue = RichMarkdownCodeBlockOptions.none
}

extension EnvironmentValues {
    var richMarkdownCodeBlocks: RichMarkdownCodeBlockOptions {
        get { self[RichMarkdownCodeBlockOptionsKey.self] }
        set { self[RichMarkdownCodeBlockOptionsKey.self] = newValue }
    }
}

public extension View {
    /// 코드 블록 하이라이터·다이어그램 렌더러를 주입한다.
    func richMarkdownCodeBlocks(_ options: RichMarkdownCodeBlockOptions) -> some View {
        environment(\.richMarkdownCodeBlocks, options)
    }
}

// MARK: - 색 구간 계산

/// 원문을 색 구간과 일반 구간으로 나눈다. 두 렌더러가 같은 규칙을 쓴다.
///
/// 잘못된 span은 조용히 버린다: 길이 0, 범위 밖, 앞 span과 겹치는 것,
/// `Character` 경계를 깨는 UTF-16 범위. 어떤 경우에도 원문 글자는 빠지거나 바뀌지 않는다.
enum RichMarkdownHighlightSegments {
    struct Segment {
        let text: Substring
        let kind: RichMarkdownHighlightKind?
    }

    static func segments(code: String, spans: [RichMarkdownHighlightSpan]) -> [Segment] {
        guard !spans.isEmpty else { return [Segment(text: code[...], kind: nil)] }

        let length = code.utf16.count
        var segments: [Segment] = []
        var cursor = 0

        for span in spans.sorted(by: { $0.range.location < $1.range.location }) {
            let start = span.range.location
            let end = span.range.location + span.range.length
            guard start >= cursor, span.range.length > 0, end <= length,
                  let colored = Range(span.range, in: code)
            else { continue }

            if start > cursor,
               let gap = Range(NSRange(location: cursor, length: start - cursor), in: code) {
                segments.append(Segment(text: code[gap], kind: nil))
            }
            segments.append(Segment(text: code[colored], kind: span.kind))
            cursor = end
        }

        if cursor < length,
           let tail = Range(NSRange(location: cursor, length: length - cursor), in: code) {
            segments.append(Segment(text: code[tail], kind: nil))
        }
        return segments
    }

    /// SwiftUI `Text`용. 색을 지정하지 않은 구간은 바깥 `foregroundStyle`을 따른다.
    static func attributedString(
        code: String,
        spans: [RichMarkdownHighlightSpan],
        colors: RichMarkdownSyntaxColors
    ) -> AttributedString {
        var result = AttributedString()
        for segment in segments(code: code, spans: spans) {
            var piece = AttributedString(segment.text)
            if let kind = segment.kind {
                piece.foregroundColor = colors.color(for: kind)
            }
            result.append(piece)
        }
        return result
    }

    /// UIKit `UITextView`용. 폰트와 기본 색은 모든 구간에 동일하게 적용한다 —
    /// 색만 바뀌므로 이미 확정된 코드 블록 레이아웃 크기가 달라지지 않는다.
    static func attributed(
        code: String,
        spans: [RichMarkdownHighlightSpan],
        colors: RichMarkdownSyntaxColors,
        font: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments(code: code, spans: spans) {
            let color = segment.kind.map { UIColor(colors.color(for: $0)) } ?? textColor
            result.append(NSAttributedString(string: String(segment.text), attributes: [
                .font: font,
                .foregroundColor: color,
            ]))
        }
        return result
    }
}
