# 벡터 공간 요약

## 1. 주제 1

벡터 공간 \(V\)의 부분집합 \(W_{1}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^1\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{1}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{1}\)
- 조건 3: \(c\mathbf{u} \in W_{1}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^1\) | 1 | 표준 기저 |
| \(P_1\) | 2 | \(1, x, \ldots, x^1\) |

```python
import numpy as np
A = np.eye(1)
print(np.linalg.matrix_rank(A))  # 1
```

> 참고 1: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 2. 주제 2

벡터 공간 \(V\)의 부분집합 \(W_{2}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^2\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{2}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{2}\)
- 조건 3: \(c\mathbf{u} \in W_{2}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^2\) | 2 | 표준 기저 |
| \(P_2\) | 3 | \(1, x, \ldots, x^2\) |

```python
import numpy as np
A = np.eye(2)
print(np.linalg.matrix_rank(A))  # 2
```

> 참고 2: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 3. 주제 3

벡터 공간 \(V\)의 부분집합 \(W_{3}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^3\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{3}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{3}\)
- 조건 3: \(c\mathbf{u} \in W_{3}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^3\) | 3 | 표준 기저 |
| \(P_3\) | 4 | \(1, x, \ldots, x^3\) |

```python
import numpy as np
A = np.eye(3)
print(np.linalg.matrix_rank(A))  # 3
```

> 참고 3: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 4. 주제 4

벡터 공간 \(V\)의 부분집합 \(W_{4}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^4\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{4}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{4}\)
- 조건 3: \(c\mathbf{u} \in W_{4}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^4\) | 4 | 표준 기저 |
| \(P_4\) | 5 | \(1, x, \ldots, x^4\) |

```python
import numpy as np
A = np.eye(4)
print(np.linalg.matrix_rank(A))  # 4
```

> 참고 4: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 5. 주제 5

벡터 공간 \(V\)의 부분집합 \(W_{5}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^5\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{5}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{5}\)
- 조건 3: \(c\mathbf{u} \in W_{5}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^5\) | 5 | 표준 기저 |
| \(P_5\) | 6 | \(1, x, \ldots, x^5\) |

```python
import numpy as np
A = np.eye(5)
print(np.linalg.matrix_rank(A))  # 5
```

> 참고 5: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 6. 주제 6

벡터 공간 \(V\)의 부분집합 \(W_{6}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^6\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{6}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{6}\)
- 조건 3: \(c\mathbf{u} \in W_{6}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^6\) | 6 | 표준 기저 |
| \(P_6\) | 7 | \(1, x, \ldots, x^6\) |

```python
import numpy as np
A = np.eye(6)
print(np.linalg.matrix_rank(A))  # 6
```

> 참고 6: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 7. 주제 7

벡터 공간 \(V\)의 부분집합 \(W_{7}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^7\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{7}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{7}\)
- 조건 3: \(c\mathbf{u} \in W_{7}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^7\) | 7 | 표준 기저 |
| \(P_7\) | 8 | \(1, x, \ldots, x^7\) |

```python
import numpy as np
A = np.eye(7)
print(np.linalg.matrix_rank(A))  # 7
```

> 참고 7: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 8. 주제 8

벡터 공간 \(V\)의 부분집합 \(W_{8}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^8\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{8}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{8}\)
- 조건 3: \(c\mathbf{u} \in W_{8}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^8\) | 8 | 표준 기저 |
| \(P_8\) | 9 | \(1, x, \ldots, x^8\) |

```python
import numpy as np
A = np.eye(8)
print(np.linalg.matrix_rank(A))  # 8
```

> 참고 8: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 9. 주제 9

벡터 공간 \(V\)의 부분집합 \(W_{9}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^9\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{9}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{9}\)
- 조건 3: \(c\mathbf{u} \in W_{9}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^9\) | 9 | 표준 기저 |
| \(P_9\) | 10 | \(1, x, \ldots, x^9\) |

```python
import numpy as np
A = np.eye(9)
print(np.linalg.matrix_rank(A))  # 9
```

> 참고 9: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

## 10. 주제 10

벡터 공간 \(V\)의 부분집합 \(W_{10}\)가 부분공간이려면 **영벡터**를 포함하고 덧셈과 스칼라배에 닫혀 있어야 합니다. 예를 들어 \(\mathbb{R}^10\)에서 원점을 지나는 초평면이 그렇습니다.

- 조건 1: \(\mathbf{0} \in W_{10}\)
- 조건 2: \(\mathbf{u} + \mathbf{v} \in W_{10}\)
- 조건 3: \(c\mathbf{u} \in W_{10}\)

| 공간 | 차원 | 기저 |
|---|---:|---|
| \(\mathbb{R}^10\) | 10 | 표준 기저 |
| \(P_10\) | 11 | \(1, x, \ldots, x^10\) |

```python
import numpy as np
A = np.eye(10)
print(np.linalg.matrix_rank(A))  # 10
```

> 참고 10: 차원 정리 \(\dim V = \dim \ker T + \dim \operatorname{im} T\).

