## 정규분포

확률밀도함수:

\[
f(x) = \frac{1}{\sigma\sqrt{2\pi}}\, e^{-\frac{(x-\mu)^2}{2\sigma^2}}
\]

### 경험적 규칙

| 구간 | 확률 |
|---|---:|
| \(\mu \pm 1\sigma\) | 68.27% |
| \(\mu \pm 2\sigma\) | 95.45% |
| \(\mu \pm 3\sigma\) | 99.73% |

### 표준화

\(Z = \frac{X - \mu}{\sigma}\)로 바꾸면 \(Z \sim N(0, 1)\)입니다. 예를 들어 평균 70, 표준편차 10인 시험에서 85점은 \(Z = 1.5\)이고, 상위 약 6.7%입니다.

```python
from scipy.stats import norm
print(1 - norm.cdf(1.5))  # 0.0668
```

> 표본 평균의 분포는 중심극한정리에 따라 \(n\)이 커질수록 정규분포에 가까워집니다: \(\bar{X} \sim N\!\left(\mu, \frac{\sigma^2}{n}\right)\).
