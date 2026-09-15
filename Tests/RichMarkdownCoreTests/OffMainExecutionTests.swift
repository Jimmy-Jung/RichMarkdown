import Foundation
import Testing
@testable import RichMarkdownCore

/// MainActor에서 CPU parse가 실행되지 않는지 검증 (DEVELOPMENT.md §4, §8).
/// signpost 구간(dev.richmarkdown / parse·raster)은 Instruments 확인용이고,
/// 여기서는 worker 실행 thread를 직접 확인한다.
@Suite struct OffMainExecutionTests {

    /// Thread.isMainThread는 async 컨텍스트에서 직접 못 쓰므로 sync 헬퍼로 샘플링한다.
    private static func sampleIsMainThread() -> Bool { Thread.isMainThread }

    @Test func workerPerformRunsOffMainThread() async throws {
        let recorder = MainThreadRecorder()
        let worker = CoalescingWorker<String> { markdown in
            await recorder.record(onMain: Self.sampleIsMainThread())
            _ = RichMarkdownParser.parse(markdown: markdown, parsesDollarMath: false)
            await recorder.record(onMain: Self.sampleIsMainThread())
        }
        await worker.submit("본문 \\(x^2\\) 수식")

        let deadline = Date().addingTimeInterval(5)
        while await worker.hasOutstandingWork {
            #expect(Date() < deadline)
            if Date() >= deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let samples = await recorder.samples
        #expect(!samples.isEmpty)
        #expect(!samples.contains(true), "CPU parse는 MainActor/main thread에서 실행되지 않아야 한다")
    }

    actor MainThreadRecorder {
        private(set) var samples: [Bool] = []
        func record(onMain: Bool) { samples.append(onMain) }
    }
}
