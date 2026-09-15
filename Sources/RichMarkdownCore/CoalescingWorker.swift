import Foundation

/// latest-wins coalescing 실행기 (DEVELOPMENT.md §4).
///
/// - 장수명 worker 하나만 요청을 소비한다.
/// - 실행 중 1개 + 최신 대기 1개만 유지한다. 새 제출은 대기 요청을 교체한다.
package actor CoalescingWorker<Input: Sendable> {
    private var pending: Input?
    private var isRunning = false
    private var latestGeneration: Int?
    private let perform: @Sendable (Input) async -> Void

    package init(perform: @escaping @Sendable (Input) async -> Void) {
        self.perform = perform
    }

    package func submit(_ input: Input) {
        pending = input
        guard !isRunning else { return }
        isRunning = true
        Task { await self.drain() }
    }

    /// generation이 작은 늦은 제출은 최신 대기 입력을 덮을 수 없다.
    /// 이 actor turn에는 `await`가 없어 ingress 순서가 곧 high-water 판정 순서다.
    package func submit(_ input: Input, generation: Int) {
        guard latestGeneration.map({ generation > $0 }) ?? true else { return }
        latestGeneration = generation
        submit(input)
    }

    /// 입력 종료 후 idle 검증용. 실행 중이거나 대기가 남아 있으면 true.
    package var hasOutstandingWork: Bool {
        isRunning || pending != nil
    }

    private func drain() async {
        while let next = takePending() {
            await perform(next)
        }
        isRunning = false
    }

    private func takePending() -> Input? {
        defer { pending = nil }
        return pending
    }
}
