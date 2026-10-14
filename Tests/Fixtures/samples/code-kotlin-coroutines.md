Kotlin 코루틴으로 "최신 입력만 처리"를 구현하는 예입니다.

```kotlin
class LatestWinsWorker(private val scope: CoroutineScope) {
    private var running: Job? = null
    private var pending: String? = null

    fun submit(input: String) {
        if (running?.isActive == true) { pending = input; return }
        running = scope.launch {
            var current: String? = input
            while (current != null) {
                process(current)
                current = pending.also { pending = null }
            }
        }
    }
}
```

| 상태 | `running` | `pending` |
|---|---|---|
| 유휴 | null | null |
| 처리 중 | active | 최신 1개만 |

- `pending`은 항상 **마지막 입력**으로 덮어씁니다.
- 처리 중인 작업은 취소하지 않고 끝난 뒤 `pending`을 확인합니다.
- 테스트는 `runTest`와 `advanceUntilIdle()`로 결정적으로 작성합니다.
