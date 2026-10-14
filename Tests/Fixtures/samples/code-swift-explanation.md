Swift에서 `actor`로 캐시를 보호하는 예입니다.

```swift
actor ParseCache {
    private var storage: [String: ParsedDocument] = [:]
    private var cost = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(for key: String) -> ParsedDocument? {
        storage[key]
    }

    func insert(_ document: ParsedDocument, for key: String, cost: Int) {
        storage[key] = document
        self.cost += cost
        if self.cost > limit { evictOldest() }
    }
}
```

핵심은 세 가지입니다.

1. **격리**: `actor` 내부 상태는 한 번에 한 호출만 접근합니다.
2. **비용 상한**: `cost`가 `limit`을 넘으면 오래된 항목부터 제거합니다.
3. **호출 측**: `await cache.value(for: key)`처럼 `await`가 필요합니다.

`@MainActor`와 섞어 쓸 때는 메인 스레드에서 긴 작업을 기다리지 않도록 `Task.detached`나 `nonisolated`를 검토하세요.
