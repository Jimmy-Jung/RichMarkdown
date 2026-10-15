// Author: JunyoungJung
// Date: 2026-09-04

import Combine
import SwiftUI

/// 스트리밍 중인 문서의 **표시** 옵션. 파싱 결과·렌더 요청은 바꾸지 않는다.
/// `nil`이면 스트리밍이 아니며 현행 렌더와 같다.
public struct RichMarkdownStreamingOptions: Sendable, Equatable {
    /// tail 문단 끝에서 alpha를 낮출 grapheme 수. 0이면 페이드 없음.
    public var tailFadeGraphemeCount: Int
    /// tail 문단의 미닫힌 `**`·백틱·`\(`·`$` opener를 closer가 도착할 때까지 숨긴다.
    public var hidesUnclosedInlineMarks: Bool

    public init(tailFadeGraphemeCount: Int = 12, hidesUnclosedInlineMarks: Bool = true) {
        self.tailFadeGraphemeCount = max(0, tailFadeGraphemeCount)
        self.hidesUnclosedInlineMarks = hidesUnclosedInlineMarks
    }

    public static let `default` = RichMarkdownStreamingOptions()
}

/// tail 블록에만 전달되는 표시 문맥. `dollarMath`는 `$`·`$$` opener 판정에 쓴다.
struct RichMarkdownStreamingTailContext: Equatable {
    let options: RichMarkdownStreamingOptions
    let dollarMath: LatexDollarMathOptions
}

private struct RichMarkdownStreamingKey: EnvironmentKey {
    static let defaultValue: RichMarkdownStreamingOptions? = nil
}

extension EnvironmentValues {
    var richMarkdownStreaming: RichMarkdownStreamingOptions? {
        get { self[RichMarkdownStreamingKey.self] }
        set { self[RichMarkdownStreamingKey.self] = newValue }
    }
}

public extension View {
    /// 스트리밍 중인 메시지 뷰에 건다. 컨테이너에 걸면 아래의 모든 `RichMarkdownView`가
    /// 스트리밍으로 표시되므로 메시지 단위로 적용한다. 스트림이 끝나면 `nil`을 넘긴다.
    func richMarkdownStreaming(_ options: RichMarkdownStreamingOptions?) -> some View {
        environment(\.richMarkdownStreaming, options)
    }
}

/// 토큰 도착 속도와 화면 갱신 속도를 분리하는 latest-wins 버퍼.
///
/// 렌더러는 누적 전체 문자열을 받으므로(README «스트리밍») 호출자가 갱신 빈도를 합쳐야 한다.
/// 간격 안에 도착한 갱신은 마지막 값만 남기고, 간격이 끝나면 trailing 게시 1회로 흘려 보낸다 —
/// 마지막 조각이 다음 조각까지 화면에 못 오르는 일이 없다.
///
/// 게시(`flush()` 제외)는 간격이 지난 뒤 첫 디스플레이 프레임 첫머리에 한다. 임의 시각에 게시하면
/// 이어지는 뷰 갱신이 프레임 중간에 시작해 렌더 패스를 놓친다. 대가는 최대 한 프레임의 지연이다.
@MainActor
public final class RichMarkdownStreamingTextBuffer: ObservableObject {
    @Published public private(set) var text: String
    public let interval: Duration

    private let frameScheduler: DisplayFrame.Scheduler
    private var pending: String?
    private var lastPublished: ContinuousClock.Instant?
    /// 간격의 남은 시간을 기다리는 예약. 끝나면 프레임을 요청한다.
    private var trailing: Task<Void, Never>?
    /// 요청한 프레임 콜백이 아직 오지 않았다. 그 콜백이 그때의 최신 pending을 게시한다.
    private var awaitingFrame = false

    public convenience init(interval: Duration = .milliseconds(100), text: String = "") {
        self.init(interval: interval, text: text, frameScheduler: { DisplayFrame.next($0) })
    }

    /// 테스트는 수동 프레임을 넣는다.
    init(interval: Duration, text: String = "", frameScheduler: @escaping DisplayFrame.Scheduler) {
        self.interval = interval
        self.text = text
        self.frameScheduler = frameScheduler
    }

    /// 누적 전체 문자열을 넘긴다. 간격이 지난 뒤 첫 프레임에 그때의 마지막 값을 게시한다.
    /// 첫 호출(reset 뒤 포함)은 간격 없이 다음 프레임에 게시한다.
    public func update(_ latest: String) {
        pending = latest
        schedulePublish()
    }

    /// 델타를 이어 붙인다. 아직 게시되지 않은 pending이 있으면 그 뒤에 붙는다.
    public func append(_ delta: String) {
        update((pending ?? text) + delta)
    }

    /// 스트림 종료·오류 시 남은 pending을 프레임을 기다리지 않고 즉시 게시한다.
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

    /// 간격이 끝난 뒤 첫 프레임에 pending을 게시하도록 예약한다. 이미 예약이 있으면 그 예약이
    /// 최신 pending을 게시한다(latest-wins).
    private func schedulePublish() {
        guard pending != nil, trailing == nil, !awaitingFrame else { return }
        let remaining = remainingInterval
        guard remaining > .zero else {
            awaitingFrame = true
            frameScheduler { [weak self] in self?.frameDidFire() }
            return
        }
        trailing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, !Task.isCancelled else { return }
            self.trailing = nil
            self.schedulePublish()
        }
    }

    /// 프레임을 기다리는 사이 flush가 간격을 다시 시작했으면 남은 시간을 다시 기다린다.
    private func frameDidFire() {
        awaitingFrame = false
        guard remainingInterval <= .zero else {
            schedulePublish()
            return
        }
        publishPending()
    }

    private var remainingInterval: Duration {
        guard let lastPublished else { return .zero }
        return interval - (ContinuousClock.now - lastPublished)
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
