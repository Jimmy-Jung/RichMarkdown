The derivative of \(\sin x\) is \(\cos x\). Here's a quick proof sketch using the limit definition:

\[
\frac{d}{dx}\sin x = \lim_{h \to 0} \frac{\sin(x+h) - \sin x}{h}
= \lim_{h \to 0} \left[ \sin x \cdot \frac{\cos h - 1}{h} + \cos x \cdot \frac{\sin h}{h} \right]
\]

Since \(\lim_{h\to 0} \frac{\sin h}{h} = 1\) and \(\lim_{h\to 0} \frac{\cos h - 1}{h} = 0\), the result is \(\cos x\).

**Common mistakes:**

- Forgetting that \(x\) must be in *radians*.
- Mixing up the sign: \(\frac{d}{dx}\cos x = -\sin x\).

See also: [Khan Academy](https://www.khanacademy.org/math/calculus-1) and `numpy.sin`.
