가우스 적분은 다음과 같이 계산합니다.

\[
I = \int_{-\infty}^{\infty} e^{-x^2}\,dx
\]

양변을 제곱하고 극좌표로 바꾸면

\[
\begin{aligned}
I^2 &= \int_{-\infty}^{\infty}\int_{-\infty}^{\infty} e^{-(x^2+y^2)}\,dx\,dy \\
    &= \int_0^{2\pi}\int_0^{\infty} e^{-r^2}\, r\,dr\,d\theta \\
    &= 2\pi \cdot \frac{1}{2} = \pi
\end{aligned}
\]

이므로 \(I = \sqrt{\pi}\)입니다.

1. 피적분함수가 짝함수이므로 \(\int_0^\infty e^{-x^2}dx = \frac{\sqrt{\pi}}{2}\)
2. 치환 \(u = r^2\), \(du = 2r\,dr\)
3. 정규분포의 정규화 상수 \(\frac{1}{\sqrt{2\pi}}\)가 여기서 나옵니다.
