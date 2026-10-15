// Author: JunyoungJung
// Date: 2026-09-04

import Combine
import Foundation
import Testing
@testable import RichMarkdown

/// latest-wins + trailing flush 계약. 게시(`flush()` 제외)는 간격이 지난 뒤 첫 디스플레이 프레임에 한다.
/// 프레임은 수동으로 흘리고(`ManualFrames`), 간격 경과는 폴링으로 기다린다(고정 sleep 금지).
@MainActor
@Suite struct RichMarkdownStreamingTextBufferTests {

    private func makeBuffer(_ interval: Duration, frames: ManualFrames) -> RichMarkdownStreamingTextBuffer {
        RichMarkdownStreamingTextBuffer(interval: interval, frameScheduler: frames.schedule)
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // 전체 suite 실행 중 다른 suite가 MainActor를 수 초 점유하면, 풀린 뒤 이 continuation이
        // trailing Task의 continuation보다 먼저 재개될 수 있다. 한 번 양보해 게시를 먼저 흘린다.
        await Task.yield()
        #expect(condition(), "조건이 제한 시간 안에 충족되어야 한다")
    }

    @Test func firstUpdatePublishesOnNextFrame() {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(50), frames: frames)
        buffer.update("첫")
        #expect(buffer.text == "", "첫 갱신도 프레임 전에는 게시하지 않는다")
        #expect(frames.waitingCount == 1, "첫 갱신은 간격 없이 바로 다음 프레임을 요청한다")
        frames.tick()
        #expect(buffer.text == "첫")
        #expect(frames.waitingCount == 0, "게시 뒤에는 기다리는 프레임이 없다")
    }

    @Test func updatesWithinIntervalCoalesceIntoOneTrailingPublish() async throws {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(50), frames: frames)
        var published: [String] = []
        let cancellable = buffer.$text.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        buffer.update("a")
        frames.tick()
        buffer.update("ab")
        buffer.update("abc")
        #expect(buffer.text == "a", "간격 안의 갱신은 게시하지 않는다")
        #expect(frames.waitingCount == 0, "간격이 지나기 전에는 프레임을 요청하지 않는다")

        try await waitUntil { frames.waitingCount == 1 }
        #expect(buffer.text == "a", "간격이 지나도 프레임 전에는 게시하지 않는다")
        frames.tick()
        #expect(published == ["a", "abc"], "trailing 게시는 마지막 값 1회다")
        #expect(frames.requestCount == 2)
    }

    @Test func updateAfterIntervalPublishesOnNextFrame() async throws {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(20), frames: frames)
        buffer.update("a")
        frames.tick()
        try await Task.sleep(for: .milliseconds(40))
        buffer.update("ab")
        #expect(buffer.text == "a", "간격이 지났어도 동기 게시하지 않는다")
        #expect(frames.waitingCount == 1, "간격이 지난 갱신은 바로 다음 프레임을 요청한다")
        frames.tick()
        #expect(buffer.text == "ab")
    }

    @Test func flushPublishesPendingSynchronously() {
        let frames = ManualFrames()
        let buffer = makeBuffer(.seconds(10), frames: frames)
        buffer.update("a")
        frames.tick()
        buffer.update("ab")
        #expect(buffer.text == "a")
        buffer.flush()
        #expect(buffer.text == "ab", "flush는 프레임을 기다리지 않는다")
    }

    /// flush가 프레임을 기다리던 값을 먼저 게시하면 남은 프레임은 그 값을 다시 게시하지 않고,
    /// flush가 다시 시작한 간격도 지킨다.
    @Test func frameAfterFlushRespectsRestartedInterval() async throws {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(30), frames: frames)
        var published: [String] = []
        let cancellable = buffer.$text.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        buffer.update("a")
        buffer.flush()
        buffer.update("ab")
        frames.tick()
        #expect(published == ["a"], "flush 뒤 간격 안에서는 남아 있던 프레임이 게시하지 않는다")

        try await waitUntil { frames.waitingCount == 1 }
        frames.tick()
        #expect(published == ["a", "ab"])
    }

    @Test func resetDropsPendingAndCancelsTrailing() async throws {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(30), frames: frames)
        buffer.update("old")
        frames.tick()
        buffer.update("old-pending")
        buffer.reset("")
        #expect(buffer.text == "")
        try await Task.sleep(for: .milliseconds(80))
        #expect(frames.waitingCount == 0, "취소된 trailing 예약은 프레임을 요청하지 않는다")
        frames.tick()
        #expect(buffer.text == "", "취소된 trailing 게시가 이전 값을 되살리지 않는다")

        buffer.update("new")
        #expect(frames.waitingCount == 1, "reset 뒤 첫 갱신은 간격 없이 다음 프레임을 요청한다")
        frames.tick()
        #expect(buffer.text == "new")
    }

    /// 프레임을 기다리는 사이 reset이 오면 그 프레임은 버린 값을 게시하지 않는다.
    @Test func resetWhileFramePendingDropsValue() {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(30), frames: frames)
        buffer.update("old")
        buffer.reset("")
        frames.tick()
        #expect(buffer.text == "")
    }

    @Test func appendAccumulatesOnPending() async throws {
        let frames = ManualFrames()
        let buffer = makeBuffer(.milliseconds(30), frames: frames)
        buffer.append("가")
        frames.tick()
        buffer.append("나")
        buffer.append("다")
        #expect(buffer.text == "가")
        try await waitUntil { frames.waitingCount == 1 }
        frames.tick()
        #expect(buffer.text == "가나다")
    }

    /// 실제 `CADisplayLink` 경로: 기본 init 버퍼도 프레임 콜백에서 게시한다.
    @Test func defaultBufferPublishesOnDisplayLink() async throws {
        let buffer = RichMarkdownStreamingTextBuffer(interval: .milliseconds(20))
        buffer.update("a")
        #expect(buffer.text == "", "동기 게시하지 않는다")
        try await waitUntil { buffer.text == "a" }
        buffer.update("ab")
        try await waitUntil { buffer.text == "ab" }
    }
}
