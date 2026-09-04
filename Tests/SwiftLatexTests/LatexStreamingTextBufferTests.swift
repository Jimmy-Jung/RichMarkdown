// Author: JunyoungJung
// Date: 2026-09-04

import Combine
import Foundation
import Testing
@testable import SwiftLatex

/// latest-wins + trailing flush 계약. trailing은 폴링으로 기다린다(고정 sleep 금지).
@MainActor
@Suite struct LatexStreamingTextBufferTests {

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

    @Test func firstUpdatePublishesSynchronously() {
        let buffer = LatexStreamingTextBuffer(interval: .milliseconds(50))
        buffer.update("첫")
        #expect(buffer.text == "첫")
    }

    @Test func updatesWithinIntervalCoalesceIntoOneTrailingPublish() async throws {
        let buffer = LatexStreamingTextBuffer(interval: .milliseconds(50))
        var published: [String] = []
        let cancellable = buffer.$text.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        buffer.update("a")
        buffer.update("ab")
        buffer.update("abc")
        #expect(buffer.text == "a", "간격 안의 갱신은 동기 게시하지 않는다")
        #expect(published == ["a"])

        try await waitUntil { buffer.text == "abc" }
        #expect(published == ["a", "abc"], "trailing 게시는 마지막 값 1회다")
    }

    @Test func updateAfterIntervalPublishesImmediately() async throws {
        let buffer = LatexStreamingTextBuffer(interval: .milliseconds(20))
        buffer.update("a")
        try await Task.sleep(for: .milliseconds(40))
        buffer.update("ab")
        #expect(buffer.text == "ab")
    }

    @Test func flushPublishesPendingSynchronously() {
        let buffer = LatexStreamingTextBuffer(interval: .seconds(10))
        buffer.update("a")
        buffer.update("ab")
        #expect(buffer.text == "a")
        buffer.flush()
        #expect(buffer.text == "ab")
    }

    @Test func resetDropsPendingAndCancelsTrailing() async throws {
        let buffer = LatexStreamingTextBuffer(interval: .milliseconds(30))
        buffer.update("old")
        buffer.update("old-pending")
        buffer.reset("")
        #expect(buffer.text == "")
        try await Task.sleep(for: .milliseconds(80))
        #expect(buffer.text == "", "취소된 trailing 게시가 이전 값을 되살리지 않는다")
        buffer.update("new")
        #expect(buffer.text == "new", "reset 뒤 첫 갱신은 동기 게시다")
    }

    @Test func appendAccumulatesOnPending() async throws {
        let buffer = LatexStreamingTextBuffer(interval: .milliseconds(30))
        buffer.append("가")
        buffer.append("나")
        buffer.append("다")
        #expect(buffer.text == "가")
        try await waitUntil { buffer.text == "가나다" }
    }
}
