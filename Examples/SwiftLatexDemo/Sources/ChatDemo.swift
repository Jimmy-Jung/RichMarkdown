import SwiftUI
import SwiftLatex

/// LLM 챗봇 형태의 렌더 확인 화면.
/// 한 화면을 스크롤하며 v1 계약의 렌더 케이스를 전부 눈으로 확인하는 것이 목적이다.
struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    /// 이 답변이 확인하려는 케이스 이름. 스크롤하며 찾기 쉽게 헤더로 보여준다.
    let caseName: String

    static func question(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text, caseName: "")
    }

    static func answer(_ caseName: String, _ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, caseName: caseName)
    }
}

enum ChatFixtures {
    /// 질문/답변 쌍. 답변마다 확인 대상 케이스가 다르다.
    static let conversation: [ChatMessage] = [
        .question("원의 넓이 공식이 뭐야?"),
        .answer("인라인 수식 · baseline", #"""
        원의 넓이는 \( A = \pi r^2 \)입니다. 반지름이 \(r = 3\)이면
        \( A = 9\pi \approx 28.27 \)이 됩니다.

        한글 사이에 \(\sqrt{x^2+1}\) 근호, \(x_{i}^{2}\) 첨자, \(\frac{a}{b}\) 분수를
        섞어도 baseline이 맞아야 합니다. 이모지 🙂 옆의 \(\alpha + \beta\)도 확인하세요.
        """#),

        .question("가우스 적분 알려줘"),
        .answer("블록 수식 · 가로 스크롤 · 복사", #"""
        \[ \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi} \]
        """#),

        .question("행렬식은?"),
        .answer("블록 수식 · 큰 구조", #"""
        \[ \det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc \]
        """#),

        .question("피보나치 수열을 Swift로 구현해줘"),
        .answer("코드 블록 · 언어 라벨 · 가로 스크롤", #"""
        점화식은 \( F_n = F_{n-1} + F_{n-2} \)입니다.

        ```swift
        func fibonacci(_ n: Int) -> Int {
            guard n > 1 else { return n }
            var (previous, current) = (0, 1)
            for _ in 2...n { (previous, current) = (current, previous + current) }
            return current
        }
        // 아주 긴 줄: 가로 스크롤이 동작하는지 확인한다. abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz
        ```

        언어 라벨이 없는 블록도 확인합니다.

        ```
        plain fence, no language
        ```
        """#),

        .question("마크다운 블록 요소를 전부 보여줘"),
        .answer("헤딩 · 리스트 · 인용 · 구분선 · 링크", #"""
        # 헤딩 1
        ## 헤딩 2
        ### 헤딩 3

        **굵게**, *기울임*, ~~취소선~~, `인라인 코드`, [절대 URL 링크](https://example.com).

        영문으로도 확인: **bold**, *italic*, ~~strikethrough~~,
        ***bold italic***, **굵게 안의 *기울임***.

        이스케이프: \*별표\*, \_밑줄\_, \$100, 경로 C:\\temp

        - 순서 없는 항목 \(x_1\)
        - 중첩 없는 두 번째 항목
        - 세 번째 항목

        1. 순서 있는 항목
        2. 두 번째
        3. 세 번째

        > 인용문 안의 수식 \( e^{i\pi} + 1 = 0 \)
        > 두 줄짜리 인용문입니다.

        ---

        구분선 아래 문단입니다.
        """#),

        .question("링크는 어떤 것만 열려?"),
        .answer("링크 allowlist · plain text 강등", #"""
        허용: [https](https://example.com), [http](http://example.com),
        [mailto](mailto:someone@example.com).

        비허용(plain text로 표시): [ftp](ftp://example.com),
        [javascript](javascript:alert(1)), [상대 경로](/relative/path),
        [tel](tel:01012345678).

        이미지 문법은 alt text만 표시합니다: ![대체 텍스트만 보입니다](https://example.com/i.png)
        """#),

        .question("수식이 코드나 링크 안에 있으면?"),
        .answer("금지 문맥 보호", #"""
        인라인 코드 안: `\(x\)` 는 수식이 아니라 코드입니다.

        코드 블록 안:

        ```text
        \(x + y\)
        \[ z \]
        ```

        링크 라벨 안: [\(x\)](https://example.com) 도 수식이 아닙니다.

        반대로 수식이 link-like source를 감싸면 수식입니다: \([a](b)\)

        HTML은 실행하지 않고 문자 그대로 표시합니다.

        <div onclick="alert(1)">raw html</div>
        """#),

        .question("Markdown 기호가 수식 안에 있으면 깨져?"),
        .answer("Markdown 기호 포함 수식", #"""
        곱셈 별표: \(a * b\) 와 \(c * d\) — 기울임으로 깨지지 않습니다.

        밑줄과 대괄호: \(x_[i]\), \(y_{j}\)

        백틱 포함: \(f(x) = x^2\) 옆의 `code`
        """#),

        .question("$ 기호로 쓴 수식도 되나?"),
        .answer("Dollar math (opt-in) · 통화 표기", #"""
        opt-in이 꺼져 있으면 아래는 모두 그냥 텍스트입니다. 우측 상단 토글을 켜서
        비교하세요.

        인라인: $a + b$ 그리고 $x^2 + y^2 = z^2$

        블록:

        $$ \sum_{i=1}^{n} i = \frac{n(n+1)}{2} $$

        통화 표기는 토글과 무관하게 수식이 아니어야 합니다:
        가격은 $5 이고 범위는 $5 and $10 입니다. $x$5 도 수식이 아닙니다.
        이스케이프한 \$100 도 그대로 보입니다.
        """#),

        .question("이상한 수식을 넣으면 어떻게 돼?"),
        .answer("실패 시 원문 표시 (fail-open)", #"""
        미완성: \(x + y 는 닫히지 않았습니다.

        빈 수식: \(\) 도 원문 그대로입니다.

        중첩: \(a \(b\) c\)

        렌더 불가한 LaTeX: \(\frac{\) 와 \(\unknowncommand{x}\)

        문단 전체가 아닌 위치의 display 구분자: 이건 \[x+y\] 인라인 위치입니다.
        """#),

        .question("한국어·영어·이모지·RTL이 섞이면?"),
        .answer("다국어 · 결합 문자 · RTL", #"""
        한글과 English와 이모지 🙂🇰🇷 그리고 RTL עברית 사이에
        \(\sum_{k=0}^{n} \binom{n}{k} = 2^n \) 을 넣습니다.

        결합 문자: é (e + U+0301) 와 café 그리고 \(\hat{x}\)

        긴 한글 문단 안에서도 인라인 수식 \(\lim_{n \to \infty} \frac{1}{n} = 0\) 의
        baseline과 줄바꿈이 자연스러워야 합니다.
        """#),

        .question("표는 지원해?"),
        .answer("미지원 노드 강등 (표는 v1 비목표)", #"""
        표는 v1 비목표입니다. 조용히 삭제하지 않고 읽을 수 있는 텍스트로 낮춥니다.

        | 항목 | 값 |
        |---|---|
        | 하나 | 1 |
        | 둘 | 2 |
        """#),

        .question("긴 답변도 잘 나와?"),
        .answer("긴 답변 · 다수 수식 · 스크롤", #"""
        ## 요약

        긴 답변에서 수식이 많아도 렌더가 유지되는지 확인합니다.

        1. 미분: \(\frac{d}{dx} x^n = n x^{n-1}\)
        2. 적분: \(\int x^n dx = \frac{x^{n+1}}{n+1} + C\)
        3. 극한: \(\lim_{x \to 0} \frac{\sin x}{x} = 1\)
        4. 급수: \(\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}\)

        \[ e^{x} = \sum_{n=0}^{\infty} \frac{x^n}{n!} \]

        위 항등식은 모든 실수 \(x\)에 대해 성립하며, 복소수 \(z\)로 확장하면
        \( e^{iz} = \cos z + i \sin z \) 를 얻습니다.

        ```python
        import math
        print(sum(1 / n ** 2 for n in range(1, 100000)))  # ~ pi^2 / 6
        ```

        > 마지막 인용: 수식 \(\pi^2/6 \approx 1.6449\)
        """#),
    ]

    /// UIKit collection 예제에 넣을 답변 본문들.
    static var assistantTexts: [String] {
        conversation.filter { $0.role == .assistant }.map(\.text)
    }
}

struct ChatDemoView: View {
    @State private var parsesDollarMath = false
    @State private var showsCaseLabels = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(ChatFixtures.conversation) { message in
                    ChatBubble(
                        message: message,
                        parsesDollarMath: parsesDollarMath,
                        showsCaseLabel: showsCaseLabels
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("AI 챗봇")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                    Toggle("케이스 라벨 표시", isOn: $showsCaseLabels)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let parsesDollarMath: Bool
    let showsCaseLabel: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if showsCaseLabel, !message.caseName.isEmpty {
                    Text(verbatim: message.caseName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
                LatexMarkdownView(markdown: message.text, parsesDollarMath: parsesDollarMath)
                    .latexTheme(.default)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
    }
}
