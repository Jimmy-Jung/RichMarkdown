// Author: JunyoungJung
// Date: 2026-09-04

import Combine
import SwiftUI

/// 스트리밍 중인 문서의 **표시** 옵션. 파싱 결과·렌더 요청은 바꾸지 않는다.
/// `nil`이면 스트리밍이 아니며 현행 렌더와 같다.
public struct LatexStreamingOptions: Sendable, Equatable {
    /// tail 문단 끝에서 alpha를 낮출 grapheme 수. 0이면 페이드 없음.
    public var tailFadeGraphemeCount: Int
    /// tail 문단의 미닫힌 `**`·백틱·`\(`·`$` opener를 closer가 도착할 때까지 숨긴다.
    public var hidesUnclosedInlineMarks: Bool

    public init(tailFadeGraphemeCount: Int = 12, hidesUnclosedInlineMarks: Bool = true) {
        self.tailFadeGraphemeCount = max(0, tailFadeGraphemeCount)
        self.hidesUnclosedInlineMarks = hidesUnclosedInlineMarks
    }

    public static let `default` = LatexStreamingOptions()
}

/// tail 블록에만 전달되는 표시 문맥. `dollarMath`는 `$`·`$$` opener 판정에 쓴다.
struct LatexStreamingTailContext: Equatable {
    let options: LatexStreamingOptions
    let dollarMath: LatexDollarMathOptions
}

private struct LatexStreamingKey: EnvironmentKey {
    static let defaultValue: LatexStreamingOptions? = nil
}

extension EnvironmentValues {
    var latexStreaming: LatexStreamingOptions? {
        get { self[LatexStreamingKey.self] }
        set { self[LatexStreamingKey.self] = newValue }
    }
}

public extension View {
    /// 스트리밍 중인 메시지 뷰에 건다. 컨테이너에 걸면 아래의 모든 `LatexMarkdownView`가
    /// 스트리밍으로 표시되므로 메시지 단위로 적용한다. 스트림이 끝나면 `nil`을 넘긴다.
    func latexStreaming(_ options: LatexStreamingOptions?) -> some View {
        environment(\.latexStreaming, options)
    }
}

/// 토큰 도착 속도와 화면 갱신 속도를 분리하는 latest-wins 버퍼.
///
/// 렌더러는 누적 전체 문자열을 받으므로(README «스트리밍») 호출자가 갱신 빈도를 합쳐야 한다.
/// 간격 안에 도착한 갱신은 마지막 값만 남기고, 간격이 끝나면 trailing 게시 1회로 흘려 보낸다 —
/// 마지막 조각이 다음 조각까지 화면에 못 오르는 일이 없다.
@MainActor
public final class LatexStreamingTextBuffer: ObservableObject {
    @Published public private(set) var text: String
    public let interval: Duration

    private var pending: String?
    private var lastPublished: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?

    public init(interval: Duration = .milliseconds(100), text: String = "") {
        self.interval = interval
        self.text = text
    }

    /// 누적 전체 문자열을 넘긴다. 첫 호출과 간격 경과 뒤 호출은 동기 게시, 그 사이는 trailing 예약.
    public func update(_ latest: String) {
        pending = latest
        guard let lastPublished else {
            publishPending()
            return
        }
        let elapsed = ContinuousClock.now - lastPublished
        if elapsed >= interval {
            publishPending()
            return
        }
        guard trailing == nil else { return }
        let remaining = interval - elapsed
        trailing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, !Task.isCancelled else { return }
            self.trailing = nil
            self.publishPending()
        }
    }

    /// 델타를 이어 붙인다. 아직 게시되지 않은 pending이 있으면 그 뒤에 붙는다.
    public func append(_ delta: String) {
        update((pending ?? text) + delta)
    }

    /// 스트림 종료·오류 시 남은 pending을 즉시 게시한다.
    public func flush() {
        cancelTrailing()
        publishPending()
    }

    /// 새 스트림 시작. pending과 간격 상태를 버리고 `text`를 즉시 바꾼다.
    public func reset(_ text: String = "") {
        cancelTrailing()
        pending = nil
        lastPublished = nil
        if self.text != text {
            self.text = text
        }
    }

    private func publishPending() {
        guard let pending else { return }
        self.pending = nil
        if pending != text {
            text = pending
        }
        lastPublished = .now
    }

    private func cancelTrailing() {
        trailing?.cancel()
        trailing = nil
    }
}
