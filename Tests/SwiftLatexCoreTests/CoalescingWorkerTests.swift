import Foundation
import Testing
@testable import SwiftLatexCore

/// 비동기 계약 테스트 (DEVELOPMENT.md §8): latest-wins, 동시 실행 1, out-of-order 방지.
@Suite struct CoalescingWorkerTests {

    actor Recorder {
        private(set) var executed: [Int] = []
        private(set) var maxConcurrent = 0
        private var inFlight = 0

        func begin(_ value: Int) {
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            executed.append(value)
        }

        func end() {
            inFlight -= 1
        }
    }

    private func waitForIdle(_ worker: CoalescingWorker<Int>, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await worker.hasOutstandingWork {
            #expect(Date() < deadline, "입력 종료 후 idle 시간 안에 outstanding task가 0이 되어야 한다")
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test func latestWinsAndSingleConcurrency() async throws {
        let recorder = Recorder()
        let worker = CoalescingWorker<Int> { value in
            await recorder.begin(value)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await recorder.end()
        }

        for i in 1...100 {
            await worker.submit(i)
        }
        try await waitForIdle(worker)

        let executed = await recorder.executed
        #expect(await recorder.maxConcurrent == 1, "동시 실행은 최대 1")
        #expect(executed.last == 100, "마지막 실행은 최신 제출 (latest wins)")
        #expect(executed.count < 100, "coalescing으로 제출보다 훨씬 적게 실행된다")
        #expect(executed == executed.sorted(), "실행 순서가 제출 순서를 위반하지 않는다 (out-of-order 없음)")
    }

    @Test func submitAfterIdleRunsAgain() async throws {
        let recorder = Recorder()
        let worker = CoalescingWorker<Int> { value in
            await recorder.begin(value)
            await recorder.end()
        }
        await worker.submit(1)
        try await waitForIdle(worker)
        await worker.submit(2)
        try await waitForIdle(worker)
        #expect(await recorder.executed == [1, 2])
    }

    @Test func lowerGenerationCannotReplaceNewerPendingInput() async throws {
        let recorder = Recorder()
        let worker = CoalescingWorker<Int> { value in
            await recorder.begin(value)
            try? await Task.sleep(nanoseconds: 5_000_000)
            await recorder.end()
        }

        await worker.submit(1, generation: 1)
        await worker.submit(3, generation: 3)
        await worker.submit(2, generation: 2) // 늦게 도착한 과거 generation
        try await waitForIdle(worker)

        let executed = await recorder.executed
        #expect(executed.last == 3)
        #expect(!executed.contains(2))
    }
}
