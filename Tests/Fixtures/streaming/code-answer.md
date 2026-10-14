다음은 Kotlin 예제입니다.

```kotlin
fun pdf(x: Double, mu: Double, sigma: Double): Double {
    val z = (x - mu) / sigma
    return exp(-0.5 * z * z) / (sigma * sqrt(2 * PI))
}
```

- `exp`는 지수 함수
- `sqrt`는 제곱근
