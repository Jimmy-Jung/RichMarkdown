행렬 \(A = \begin{pmatrix} 2 & 1 \\ 1 & 3 \end{pmatrix}\)의 고윳값을 구합니다.

특성방정식 \(\det(A - \lambda I) = 0\):

\[
\det\begin{pmatrix} 2-\lambda & 1 \\ 1 & 3-\lambda \end{pmatrix} = (2-\lambda)(3-\lambda) - 1 = \lambda^2 - 5\lambda + 5 = 0
\]

\[
\lambda = \frac{5 \pm \sqrt{5}}{2}
\]

- \(\lambda_1 \approx 3.618\), 고유벡터 \(\mathbf{v}_1 = \begin{pmatrix} 1 \\ 1.618 \end{pmatrix}\)
- \(\lambda_2 \approx 1.382\), 고유벡터 \(\mathbf{v}_2 = \begin{pmatrix} 1 \\ -0.618 \end{pmatrix}\)

> 대칭행렬이므로 고유벡터는 서로 직교합니다: \(\mathbf{v}_1 \cdot \mathbf{v}_2 = 1 - 1 = 0\).

행렬식과 대각합으로 검산하면 \(\det A = 5 = \lambda_1\lambda_2\), \(\operatorname{tr} A = 5 = \lambda_1 + \lambda_2\)입니다.
