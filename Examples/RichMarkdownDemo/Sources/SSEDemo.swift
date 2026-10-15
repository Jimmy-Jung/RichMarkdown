// Created by JunyoungJung on 2026-08-28.

import Foundation
import notify
import os
import QuartzCore
import RichMarkdown
import SwiftUI

// MARK: - SSE 줄 분리기

/// 바이트 스트림을 SSE 줄로 나눈다. LF·CRLF·CR 세 종류 줄 끝을 처리하고 **빈 줄을 보존**한다.
///
/// `URLSession.AsyncBytes.lines`(=`AsyncLineSequence`)를 쓸 수 없다. 그 시퀀스는 빈 줄을
/// 통째로 건너뛰는데(실측: `"data: a\n\ndata: b\n\n"` → `["data: a", "data: b"]`), SSE에서
/// 빈 줄은 **이벤트 경계**라 그대로 쓰면 이벤트가 한 번도 dispatch되지 않는다. BOM도 남긴다.
struct SSELineSplitter {
    /// 한 줄 상한. 개행 없이 계속 보내는 엔드포인트에서 버퍼가 무한히 자라지 않게 한다.
    /// 정상 SSE 프레임은 이 크기에 닿지 않는다.
    static let maxLineBytes = 1 << 16

    private var buffer: [UInt8] = []
    private var pendingCarriageReturn = false
    private var strippedByteOrderMark = false

    /// 바이트 하나를 넣는다. 줄이 끝나면 그 줄을 돌려준다.
    mutating func consume(_ byte: UInt8) -> String? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            // CRLF의 LF는 이미 끝낸 줄의 일부다.
            if byte == 0x0A { return nil }
        }

        switch byte {
        case 0x0A:
            return takeLine()
        case 0x0D:
            pendingCarriageReturn = true
            return takeLine()
        default:
            buffer.append(byte)
            return buffer.count >= Self.maxLineBytes ? takeLine() : nil
        }
    }

    /// 스트림이 끝났을 때 남은 조각. 마지막 줄에 개행이 없을 수 있다.
    mutating func flush() -> String? {
        buffer.isEmpty ? nil : takeLine()
    }

    private mutating func takeLine() -> String {
        var line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)

        // HTML Living Standard 9.2: UTF-8 decode는 스트림 선두의 BOM 하나를 제거한다.
        if !strippedByteOrderMark {
            strippedByteOrderMark = true
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }
        return line
    }
}

// MARK: - SSE 디코더

/// `text/event-stream` 프레임 디코더 (W3C EventSource의 부분집합).
///
/// `data` 필드만 모으고 `event`/`id`/`retry`는 무시한다. 줄 단위 **동기** 상태 머신이라
/// 네트워크 없이 단위 테스트할 수 있다 (`DemoComponentTests`). 줄 끝 처리는 `SSELineSplitter`가
/// 전담하므로 여기 들어오는 줄에는 CR이 남아 있지 않다.
struct SSEDecoder {
    enum Event: Equatable {
        /// 누적 답변에 이어 붙일 텍스트 조각.
        case text(String)
        /// 서버가 보낸 오류 payload. 스트림을 끝내고 사용자에게 이유를 보여준다.
        case failure(String)
        /// `data: [DONE]` 종료 신호.
        case done
    }

    /// 한 이벤트에 속한 `data` 줄들. 빈 줄을 만나면 하나로 합쳐 dispatch한다.
    private var dataLines: [String] = []

    /// 한 줄을 넣는다. 이벤트가 완성되면 돌려주고, 아직이면 `nil`이다.
    mutating func consume(_ line: String) -> Event? {
        guard !line.isEmpty else { return dispatch() }
        // 콜론으로 시작하는 줄은 주석이다. 프록시가 연결 유지를 위해 보내는 heartbeat다.
        guard !line.hasPrefix(":") else { return nil }

        let field = Self.parseField(line)
        if field.name == "data" { dataLines.append(field.value) }
        return nil
    }

    /// 마지막 blank line 없이 연결이 끊긴 스트림에서 남은 이벤트를 꺼낸다.
    mutating func finish() -> Event? { dispatch() }

    private mutating func dispatch() -> Event? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll()

        // 종료 표식은 게이트웨이마다 공백이 붙는다. 값 비교만 관대하게 한다.
        guard payload.trimmingCharacters(in: .whitespaces) != "[DONE]" else { return .done }
        return Self.event(fromPayload: payload)
        // ponytail: 규격은 값이 빈 이벤트도 발행하지만 렌더에 영향이 없어 만들지 않는다.
        //           프로토콜 수준으로 청크를 세야 하면 .text("")를 살린다.
    }

    /// `field: value`. 콜론이 없으면 줄 전체가 필드 이름이고 값은 빈 문자열이다(W3C).
    /// 값 앞의 공백은 **하나만** 제거한다.
    private static func parseField(_ line: String) -> (name: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }

    /// payload에서 텍스트 델타나 오류를 뽑는다. 게이트웨이마다 모양이 달라 여러 갈래를 받는다.
    /// - OpenAI chat completions — `choices[0].delta.content` (문자열 또는 content-part 배열)
    /// - OpenAI completions — `choices[0].text`
    /// - OpenAI Responses — `delta` (문자열)
    /// - Anthropic Messages — `delta.text`
    /// - 오류 — `error.message` 또는 `error` 문자열
    /// - JSON이 아닌 순수 텍스트 SSE — payload 자체
    ///
    /// 텍스트가 없는 이벤트(role 청크, ping 등)는 `nil`이라 화면에 아무 일도 일어나지 않는다.
    static func event(fromPayload payload: String) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            // JSON처럼 생겼는데 파싱에 실패했다면 잘린 조각이다. 답변에 섞지 않는다.
            let looksLikeJSON = payload.hasPrefix("{") || payload.hasPrefix("[")
            guard !looksLikeJSON, !payload.isEmpty else { return nil }
            return .text(payload)
        }

        if let error = json["error"] {
            let message = (error as? [String: Any])?["message"] as? String
                ?? error as? String
                ?? "알 수 없는 오류"
            return .failure(message)
        }
        guard let text = deltaText(in: json), !text.isEmpty else { return nil }
        return .text(text)
    }

    private static func deltaText(in json: [String: Any]) -> String? {
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any], let content = content(in: delta) {
                return content
            }
            if let text = choice["text"] as? String { return text }
        }
        if let delta = json["delta"] as? [String: Any] { return delta["text"] as? String }
        if let delta = json["delta"] as? String { return delta }
        return nil
    }

    /// `content`는 문자열이거나 content-part 배열이다.
    private static func content(in delta: [String: Any]) -> String? {
        if let content = delta["content"] as? String { return content }
        if let parts = delta["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

// MARK: - 로컬 시뮬레이션 fixture

enum SSEDemoFixtures {
    /// 스트리밍으로 확인할 답변.
    ///
    /// 수식·코드 펜스·표를 모두 포함한다. 아래 `frames(of:chunkSize:)`가 문자 수로 자르므로
    /// 구분자 중간에서 끊기고, 그 구간에서는 파싱이 끝나도 수식이 원문으로 남는
    /// **fail-open**을 눈으로 볼 수 있다.
    ///
    /// 문서를 작게 유지한다. 파싱이 갱신 간격보다 오래 걸리면 렌더 모델의 latest-wins가
    /// 매번 stale 판정을 내려 새 게시가 착지하지 못한다 — 스트리밍 append에서는 이전
    /// 렌더가 유지되지만 새 내용이 스트림이 끝날 때까지 보이지 않는다(README «스트리밍»).
    static let answer = #"""
    ## 정규분포의 넓이

    확률밀도함수는 \( f(x) = \frac{1}{\sigma\sqrt{2\pi}} e^{-\frac{(x-\mu)^2}{2\sigma^2}} \)
    입니다. 전체 넓이가 1이 되는 이유는 가우스 적분에서 옵니다.

    \[ \int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi} \]

    표준화하면 \(z = \frac{x - \mu}{\sigma}\) 이고, 구간별 확률은 다음과 같습니다.

    | 구간 | 확률 | 비고 |
    | :--- | :---: | ---: |
    | \(\mu \pm \sigma\) | 68.27% | 1 시그마 |
    | \(\mu \pm 2\sigma\) | 95.45% | 2 시그마 |
    | \(\mu \pm 3\sigma\) | 99.73% | 3 시그마 |

    Swift로는 이렇게 계산합니다.

    ```swift
    func normalPDF(_ x: Double, mean: Double = 0, sd: Double = 1) -> Double {
        let z = (x - mean) / sd
        return exp(-0.5 * z * z) / (sd * (2 * .pi).squareRoot())
    }
    ```

    정리하면

    1. 밀도는 \(e^{-z^2/2}\) 에 비례합니다.
    2. 정규화 상수는 \(\frac{1}{\sigma\sqrt{2\pi}}\) 입니다.
    3. 누적분포 \(\Phi(z)\) 는 닫힌 형태가 없어 수치적으로 구합니다.

    > 오차함수로 쓰면 \( \Phi(z) = \frac{1}{2}\left[1 + \mathrm{erf}\left(\frac{z}{\sqrt{2}}\right)\right] \) 입니다.
    """#

    /// 성능 측정용 긴 답변(UTF-8 약 5.8 KB, 3,543자). 실제 LLM 답변처럼 헤딩·문단·글머리표/번호 목록(각 6개)·
    /// 표 2개(각 6행, 인라인 수식 셀)·코드 블록 2개·인용·인라인/디스플레이 수식을 섞었다.
    /// `SSEDemoFixture.long`이 12자 청크로 자르면 20Hz에서 약 15초다. 짧은 `answer`는 이전 측정과
    /// 이어 비교하려고 그대로 둔다.
    static let longAnswer = #"""
    ## 선형 회귀를 경사 하강법으로 학습하기

    선형 회귀(linear regression)는 입력 \(x\)와 출력 \(y\)의 관계를 직선 \(\hat{y} = wx + b\)로 근사하는 가장 기본적인 지도 학습 모델입니다. 계산이 빠르고 계수를 그대로 해석할 수 있어서, 복잡한 모델을 시도하기 전에 기준선으로 먼저 학습해 보는 경우가 많습니다. It is surprisingly hard to beat on small tabular datasets.

    ### 1. 손실 함수

    모델이 얼마나 틀렸는지는 평균제곱오차(MSE)로 잽니다. 데이터가 \(n\)개일 때 손실은 다음과 같습니다.

    \[ L(w, b) = \frac{1}{n} \sum_{i=1}^{n} \left( y_i - (w x_i + b) \right)^2 \]

    이 함수는 \(w\)와 \(b\)에 대해 볼록(convex)하므로 지역 최솟값이 곧 전역 최솟값입니다. 그래서 학습률만 적절히 고르면 어디에서 출발하든 같은 해에 도달합니다. 오차를 제곱하기 때문에 큰 오차에 훨씬 큰 벌점이 붙는다는 점도 기억해 두세요.

    ### 2. 기울기 계산

    각 파라미터로 편미분하면 업데이트 방향이 나옵니다.

    \[ \frac{\partial L}{\partial w} = -\frac{2}{n} \sum_{i=1}^{n} x_i \left( y_i - \hat{y}_i \right) \]

    절편 \(b\)에 대한 기울기도 같은 방식으로 구합니다. 두 기울기에 학습률 \(\eta\)를 곱해 반대 방향으로 한 걸음씩 이동합니다: \(w \leftarrow w - \eta \, \partial L / \partial w\). 한 번의 이동을 한 에폭(epoch)이라고 부르며, 손실이 더 이상 줄지 않을 때까지 반복합니다.

    ### 3. 학습률에 따른 수렴

    | 학습률 \(\eta\) | 반복 수 | 최종 손실 | 관찰 |
    | :--- | ---: | ---: | :--- |
    | \(10^{-4}\) | 5000 | 0.4120 | 너무 느리게 내려감 |
    | \(10^{-3}\) | 2000 | 0.0851 | 안정적으로 수렴 |
    | \(5 \times 10^{-3}\) | 800 | 0.0849 | 빠르고 안정적 |
    | \(10^{-2}\) | 400 | 0.0849 | 권장 시작값 |
    | \(5 \times 10^{-2}\) | 120 | 0.0923 | 진동이 시작됨 |
    | \(10^{-1}\) | — | \(\infty\) | 손실이 발산함 |

    학습률이 너무 작으면 수천 번을 반복해도 손실이 거의 줄지 않고, 너무 크면 최솟값을 계속 건너뛰다가 결국 발산합니다. 특징을 표준화한 뒤라면 \(10^{-2}\) 근처에서 시작해, 손실 곡선이 출렁이기 시작할 때마다 절반으로 줄이는 방법이 무난합니다.

    ### 4. 구현

    NumPy로 쓰면 반복문 하나로 충분합니다.

    ```python
    def fit(x, y, lr=0.01, epochs=400):
        w, b, n = 0.0, 0.0, len(x)
        for _ in range(epochs):
            error = y - (w * x + b)
            w += lr * (2 / n) * (x * error).sum()
            b += lr * (2 / n) * error.sum()
        return w, b
    ```

    같은 로직을 Swift로 옮기면 다음과 같습니다. 배열 연산은 `zip`과 `reduce`로 표현합니다.

    ```swift
    func fit(_ x: [Double], _ y: [Double], lr: Double = 0.01) -> (Double, Double) {
        var w = 0.0, b = 0.0
        let n = Double(x.count)
        for _ in 0..<400 {
            let e = zip(x, y).map { $1 - (w * $0 + b) }
            w += lr * 2 / n * zip(x, e).reduce(0) { $0 + $1.0 * $1.1 }
            b += lr * 2 / n * e.reduce(0, +)
        }
        return (w, b)
    }
    ```

    두 구현 모두 전체 데이터를 한 번에 보는 배치 경사 하강법입니다. 데이터가 커지면 아래 참고처럼 미니배치로 바꿉니다.

    ### 5. 평가 지표

    | 지표 | 정의 | 범위 | 해석 |
    | :--- | :--- | :---: | :--- |
    | MSE | \(\frac{1}{n}\sum (y_i - \hat{y}_i)^2\) | \([0, \infty)\) | 작을수록 좋음 |
    | RMSE | \(\sqrt{\mathrm{MSE}}\) | \([0, \infty)\) | 원래 단위로 읽음 |
    | MAE | \(\frac{1}{n}\sum \lvert y_i - \hat{y}_i \rvert\) | \([0, \infty)\) | 이상치에 덜 민감함 |
    | \(R^2\) | \(1 - \mathrm{SS}_{res} / \mathrm{SS}_{tot}\) | \((-\infty, 1]\) | 설명된 분산의 비율 |
    | MAPE | 상대 오차의 평균 | \([0, \infty)\) | 퍼센트로 읽음 |
    | 수정 \(R^2\) | 변수 수 \(p\)로 보정한 \(R^2\) | \((-\infty, 1]\) | 변수를 늘린 효과를 걸러냄 |

    결정계수가 1에 가까울수록 모델이 분산을 잘 설명하지만, 학습 세트에서만 높고 검증 세트에서 낮다면 과적합을 먼저 의심해야 합니다. 지표 하나만 보지 말고 잔차 그림도 함께 살펴보세요.

    ### 6. 실무 체크리스트

    - 특징(feature)을 표준화해 스케일을 맞춥니다. 값이 큰 열 하나가 기울기를 지배하는 일을 막습니다.
    - 학습·검증·테스트 세트를 먼저 나누고, 표준화 통계는 학습 세트에서만 계산합니다.
    - 에폭마다 손실 곡선을 그려 진동이나 정체가 없는지 확인합니다.
    - 이상치가 많으면 MSE 대신 Huber 손실을 고려합니다.
    - 다중공선성이 의심되면 릿지 정규화를 더합니다: \(L + \lambda \lVert w \rVert^2\).
    - 작은 데이터에서는 닫힌 해를 함께 계산해 결과를 교차 확인합니다.

    ### 7. 정리

    1. 선형 회귀는 MSE를 최소화하는 \(w\)와 \(b\)를 찾는 문제입니다.
    2. 손실이 볼록하므로 경사 하강법은 적절한 학습률에서 전역 최솟값으로 수렴합니다.
    3. 학습률은 \(10^{-2}\) 근처에서 시작해 손실 곡선을 보며 조정합니다.
    4. 평가는 RMSE와 \(R^2\)를 함께 보고, 이상치가 많으면 MAE도 확인합니다.
    5. 정규방정식 \(w = (X^\top X)^{-1} X^\top y\)로 결과를 검산할 수 있습니다.
    6. 마지막으로, 평균값만 예측하는 단순 기준선과 반드시 비교합니다.

    > 참고: 데이터가 수백만 행을 넘으면 전체 배치 대신 미니배치 확률적 경사 하강법(SGD)을 씁니다. 업데이트 한 번의 비용이 배치 크기 \(B\)에 비례하는 \(O(B)\)로 줄어 데이터를 메모리에 다 올리지 않아도 되고, 매 걸음의 잡음이 평탄한 구간을 빠져나가는 데 도움이 되기도 합니다.
    """#

    /// fixture를 `chunkSize` 문자씩 잘라 OpenAI 호환 SSE 프레임으로 만든다.
    /// 프레임 하나는 `["data: {…}", ""]`, 마지막 프레임은 `["data: [DONE]", ""]`이다.
    static func frames(of text: String = answer, chunkSize: Int = 6) -> [[String]] {
        chunks(of: text, size: chunkSize).map { ["data: \(jsonPayload(delta: $0))", ""] }
            + [["data: [DONE]", ""]]
    }

    /// `Character` 경계로 자른다. UTF-16 단위로 자르면 이모지·결합 문자가 깨진다.
    static func chunks(of text: String, size: Int) -> [String] {
        guard size > 0 else { return text.isEmpty ? [] : [text] }

        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == size {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func jsonPayload(delta: String) -> String {
        let payload: [String: Any] = ["choices": [["delta": ["content": delta]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            // 도달하지 않는 경로. 인코딩이 실패해도 순수 텍스트 SSE로 계속 흐른다.
            return delta
        }
        return json
    }
}

/// 시뮬레이션 답변 선택. 화면에는 노출하지 않고 `-sseFixture short|long`(성능 측정)으로 고른다.
enum SSEDemoFixture: String {
    /// 기존 답변(약 1.1 KB, 6자 청크).
    case short
    /// 측정용 긴 답변(약 5.8 KB, 12자 청크 — 20Hz에서 약 15초).
    case long

    var text: String {
        switch self {
        case .short: SSEDemoFixtures.answer
        case .long: SSEDemoFixtures.longAnswer
        }
    }

    var chunkSize: Int {
        switch self {
        case .short: 6
        case .long: 12
        }
    }

    var frames: [[String]] { SSEDemoFixtures.frames(of: text, chunkSize: chunkSize) }
}

extension SSEDemoFixtures {
    /// 측정 창 signpost. PointsOfInterest 카테고리라 xctrace `os_signpost`·`Points of Interest` 계측기
    /// 모두에 잡힌다(`scripts/bench/trace_summary.py --window-signpost sse-stream`).
    static let signposter = OSSignposter(subsystem: "dev.richmarkdown.demo", category: .pointsOfInterest)

    /// 두 SSE 화면이 공유하는 로컬 전송 루프. 프레임을 `rate`의 절대 일정으로 한 줄씩 `deliver`에
    /// 넘기고, `deliver`가 `true`를 돌려주면(종료·오류·세대 교체) 멈춘다.
    ///
    /// 첫 프레임을 넘기기 직전부터 루프가 끝난 직후까지를 `sse-stream` 구간으로 남긴다. 구간 끝은 마지막
    /// 프레임(`[DONE]`)의 flush 직후다 — 최종 parse 게시·렌더와 스트리밍 종료 재구성(streaming → nil)은 그 뒤
    /// 비동기로 돈다. 분석 쪽(`trace_summary.py`의 `WINDOW_SLACK_MS`)이 창 끝 여유로 이 꼬리를 덮는다.
    ///
    /// 일정은 다음 vsync(`vsync`, 기본 `SSEDemoVsync.next`)에서 위상 offset(`SSEDemoPhase`)만큼 뒤에 시작한다.
    /// 구간 시작 메시지에 seed·vsync 기준 offset·최대 fps를 남기고, 구간 시작·끝에 기기 상태(`device-state` 이벤트)를 남긴다.
    @MainActor
    static func play(
        _ frames: [[String]],
        rate: SSEDemoRate,
        label: String,
        vsync: @MainActor () async -> ContinuousClock.Instant = SSEDemoVsync.next,
        deliver: (String) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let phase = SSEDemoLaunchOptions.phase()
        let start = await vsync() + phase.offset
        var interval: OSSignpostIntervalState?
        defer {
            if let interval {
                emitDeviceState("end")
                signposter.endInterval("sse-stream", interval)
            }
        }
        for (index, frame) in frames.enumerated() {
            try await Task.sleep(until: rate.deadline(ofFrame: index, from: start), clock: clock)
            if interval == nil {
                interval = signposter.beginInterval(
                    "sse-stream", id: signposter.makeSignpostID(), "\(label, privacy: .public) \(phase.metadata, privacy: .public)"
                )
                emitDeviceState("start")
            }
            for line in frame {
                if deliver(line) { return }
            }
        }
    }

    /// 열 상태·저전력 모드. 둘 다 CPU 클럭을 바꿔 같은 빌드의 측정값을 흔든다 — 분석이 이 값으로 거른다.
    static func deviceState(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> String {
        let name = ["nominal", "fair", "serious", "critical"][min(thermal.rawValue, 3)]
        return "thermal=\(name) low_power=\(lowPower ? 1 : 0)"
    }

    private static func emitDeviceState(_ moment: String) {
        let info = ProcessInfo.processInfo
        let state = deviceState(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
        signposter.emitEvent("device-state", "at=\(moment, privacy: .public) \(state, privacy: .public)")
    }
}

// MARK: - 성능 측정 자동 재생

/// XCUITest 없이(앱 접근성 꺼짐) 측정하는 launch argument. `scripts/bench/ios-trace-scenarios.sh`의
/// `*-auto` 시나리오가 `xctrace record --launch -- <번들> -sseAutoplay swiftui -sseFixture long`처럼 넘긴다.
/// - `-sseAutoplay swiftui|uikit`: 해당 SSE 화면을 루트로 바로 열고, 녹화 시작 알림 1초 뒤 20Hz로 시작한다.
/// - `-sseFixture short|long`: 시뮬레이션 답변(기본 short). 자동 재생이 아니어도 적용된다.
/// - `-ssePhaseSeed <n>`: 첫 청크의 vsync 기준 offset을 정하는 UInt64 seed(`SSEDemoPhase`). 없거나 UInt64로 읽히지 않으면
///   스트림마다 새로 뽑는다. 자동 재생이 아니어도 적용된다.
enum SSEDemoLaunchOptions {
    enum Screen: String {
        case swiftui
        case uikit
    }

    // `-key value` launch argument는 UserDefaults 인자 도메인으로 들어온다.
    static let autoplay = UserDefaults.standard.string(forKey: "sseAutoplay").flatMap(Screen.init(rawValue:))
    static let fixture = UserDefaults.standard.string(forKey: "sseFixture").flatMap(SSEDemoFixture.init(rawValue:)) ?? .short
    static let phaseSeed = UserDefaults.standard.string(forKey: "ssePhaseSeed").flatMap { UInt64($0) }

    /// 이번 스트림의 위상. seed가 없으면 새로 뽑는다 — 뽑은 seed도 메타데이터에 남아 재현할 수 있다.
    @MainActor
    static func phase() -> SSEDemoPhase {
        SSEDemoPhase(seed: phaseSeed ?? .random(in: .min ... .max), framesPerSecond: UIScreen.main.maximumFramesPerSecond)
    }

    /// 스크립트가 녹화 시작 직후 보내는 Darwin 알림. `PerfHarness.tracingStartedNotification`과 같은 이름이다.
    static let tracingStartedNotification = "dev.richmarkdown.perf.tracing-started"

    /// 녹화 시작 알림을 받으면 `settle`만큼 더 기다린다. 알림을 놓쳐도(앱이 뜨기 전에 보낸 경우)
    /// `fallback` 뒤에는 돌아온다.
    @MainActor
    static func waitForTracingStarted(settle: Duration = .seconds(1), fallback: Duration = .seconds(8)) async {
        var posted = false
        var token: Int32 = 0
        let registered = notify_register_dispatch(tracingStartedNotification, &token, .main) { _ in
            posted = true
        } == NOTIFY_STATUS_OK
        defer {
            if registered { notify_cancel(token) }
        }
        let deadline = ContinuousClock.now + fallback
        // ponytail: 50ms 폴링. 녹화 전 대기라 측정 창에 들어가지 않는다.
        while !posted, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if posted { try? await Task.sleep(for: settle) }
    }
}

// MARK: - 전송 속도

/// 로컬 시뮬레이션의 프레임 간격. README 권장치(~10Hz)의 위·아래를 모두 확인하려고 셋을 둔다.
/// 60Hz에서도 내부 coalescing(실행 1 + 대기 1)이 렌더를 흡수해야 한다.
/// 프레임은 시작 시각 기준 **절대 일정**으로 낸다(`deadline(ofFrame:from:)`). 렌더가 메인 스레드를
/// 오래 잡아도 주기가 늘지 않고, 밀린 프레임은 깨어나는 즉시 몰아서 도착한다 — 실제 네트워크와 같다.
enum SSEDemoRate: String, CaseIterable, Identifiable {
    case slow = "5Hz"
    case normal = "20Hz"
    case fast = "60Hz"

    var id: String { rawValue }

    var interval: Duration {
        switch self {
        case .slow: .milliseconds(200)
        case .normal: .milliseconds(50)
        case .fast: .microseconds(16_667)
        }
    }

    /// `index`번째(0부터) 프레임을 낼 시각. 상대 sleep은 렌더가 느린 빌드일수록 주기가 늘어
    /// 걸리는 부하 자체가 줄었다(측정 불공정). 시작 시각에서 곱해 구하므로 오차가 쌓이지 않는다.
    func deadline(ofFrame index: Int, from start: ContinuousClock.Instant) -> ContinuousClock.Instant {
        start + interval * (index + 1)
    }
}

/// 첫 청크의 vsync 기준 offset. 50ms 청크 간격은 60·120Hz vsync의 정수배라 스트림 시작에 걸린 위상이 끝까지 고정되고,
/// 렌더가 vsync 직후 몇 ms 구간에서 시작하면 거의 매번 다음 렌더 패스를 놓친다(위상 의존, 실측). 그래서 일정을
/// CADisplayLink의 다음 vsync(`SSEDemoVsync`)에서 offset만큼 늦춰 시작한다. offset은 seed로 정한 U(0, 1/최대 fps)라
/// 같은 seed는 같은 offset을 재현하고, seed를 새로 뽑으면 offset이 한 프레임 안에 고르게 퍼진다.
/// 보장하는 것은 예정 시각의 vsync 기준 offset뿐이다. 실제 첫 청크 전달은 깨어남 지연만큼 더 늦고, 실제 주사율이 최대
/// fps보다 낮으면(저전력 모드 등) offset이 한 프레임을 다 덮지 못한다. 실제 위상은 `stream_metrics.py`의
/// `phase.measured_ms`로 확인한다.
struct SSEDemoPhase {
    let seed: UInt64
    let framesPerSecond: Int
    let offset: Duration

    init(seed: UInt64, framesPerSecond: Int) {
        var generator = SplitMix64(state: seed)
        self.seed = seed
        self.framesPerSecond = framesPerSecond
        offset = .seconds(Double.random(in: 0..<1, using: &generator) / Double(max(framesPerSecond, 1)))
    }

    /// `sse-stream` 구간 시작 메시지에 붙는다. `scripts/bench/stream_metrics.py`가 key=value로 읽는다.
    var metadata: String {
        "phase_seed=\(seed) phase_vsync_offset_ms=\(String(format: "%.3f", offset / .milliseconds(1))) max_fps=\(framesPerSecond)"
    }
}

/// 화면 vsync 시각. 녹화 알림·sleep 뒤의 `ContinuousClock.now`는 vsync와 무관한 아무 시각이라 위상 기준이 못 된다.
@MainActor
enum SSEDemoVsync {
    /// 다음 CADisplayLink 콜백이 가리키는 vsync(`targetTimestamp`)를 ContinuousClock 시각으로 옮겨 돌려준다.
    static func next() async -> ContinuousClock.Instant {
        await withCheckedContinuation { continuation in
            // CADisplayLink가 target을 붙잡고 있다가 invalidate에서 놓는다.
            CADisplayLink(target: Probe(continuation), selector: #selector(Probe.tick)).add(to: .main, forMode: .common)
        }
    }

    private final class Probe: NSObject {
        let continuation: CheckedContinuation<ContinuousClock.Instant, Never>

        init(_ continuation: CheckedContinuation<ContinuousClock.Instant, Never>) {
            self.continuation = continuation
        }

        @objc func tick(_ link: CADisplayLink) {
            link.invalidate()
            continuation.resume(returning: .now + .seconds(link.targetTimestamp - CACurrentMediaTime()))
        }
    }
}

/// seed 하나로 재현되는 난수(SplitMix64). 표준 라이브러리 생성기는 seed를 받지 않는다.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 두 SSE 데모 화면(SwiftUI·UIKit)이 공유하는 상한.
enum SSEDemoLimits {
    /// 누적 답변 상한. `RichMarkdownCore.InputLimits.maxInputUTF8Bytes`와 같은 값이다
    /// (package 타입이라 데모에서 직접 참조할 수 없다). 이 경계를 넘으면 렌더러가 표시를
    /// 64 KiB로 잘라 화면이 급감하고 이후 도착분이 보이지 않으므로, 그 앞에서 스트림을 끊는다.
    static let answerByteCap = 262_144
    /// 화면 갱신 상한(약 10Hz). 도착 속도와 무관하게 이 간격으로만 화면 상태를 갱신하고
    /// 자동 스크롤을 한다. README «스트리밍»의 «최대 약 10Hz로 합쳐서 전달» 권고를 데모가
    /// 직접 지킨다 — 매 청크 갱신 + 자동 스크롤은 스크롤 레이아웃을 그 빈도로 강제해
    /// 메인 스레드를 포화시키고, 렌더 게시가 밀려 새 게시가 착지하지 못한다(실측).
    static let publishInterval = Duration.milliseconds(100)
}

enum SSEDemoError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case notEventStream(String)

    var errorDescription: String? {
        switch self {
        // 입력한 URL은 바로 아래 텍스트 필드에 이미 보인다. 토큰이 섞인 값을 다시 화면에 박지 않는다.
        case .invalidURL: "http(s) URL이 아닙니다."
        case let .httpStatus(code): "서버가 HTTP \(code)를 반환했습니다."
        case let .notEventStream(type):
            type.isEmpty
                ? "응답이 text/event-stream이 아닙니다."
                : "응답이 text/event-stream이 아닙니다: \(type)"
        }
    }
}

// MARK: - 화면

/// SSE로 도착하는 LLM 답변을 실시간 렌더하는 화면.
///
/// 라이브러리는 증분 parser를 제공하지 않는다(README «스트리밍»). 호출자는 **누적된 전체
/// 문자열**을 계속 넘기고, `RichMarkdownView` 내부 `CoalescingWorker`가 연속 갱신을 합쳐
/// 최신 값만 렌더한다. 이 화면은 그 계약을 실제 SSE 프레임으로 확인한다.
///
/// - 엔드포인트가 비면 fixture를 SSE 프레임으로 만들어 로컬에서 흘린다(네트워크 불필요).
/// - 엔드포인트를 넣으면 `URLSession.bytes`로 실제 `text/event-stream`을 읽는다.
///   인증 헤더는 붙이지 않으므로 토큰이 필요한 게이트웨이는 로컬 프록시를 두고 붙인다.
///
/// 루트는 청크 상태를 읽지 않는다. 도착(20Hz)은 카운터 값만 올리고, 버퍼 게시(≤10Hz)는 본문
/// (`SSETranscriptView`)만 다시 그린다 — 툴바 메뉴·속도 Picker·입력 필드는 스트림 동안 그대로다
/// (p7 실측: 루트의 20Hz 카운터가 화면 전체를 무효화해 hitch 구간 메인 스레드의 17–30%를 썼다).
struct SSEDemoView: View {
    /// 도착 속도와 화면 갱신을 분리하는 latest-wins 버퍼. trailing 게시로 마지막 조각도 화면에 오른다.
    /// `@StateObject`가 아니라 `@State`로 들고 있어 루트는 게시를 구독하지 않는다.
    @State private var buffer = RichMarkdownStreamingTextBuffer(interval: SSEDemoLimits.publishInterval)
    @State private var counter = SSEStreamCounter()
    @State private var isStreaming = false
    /// `.task(id:)` 재시작 신호. 시작·중지 모두 값을 올려 이전 스트림 Task를 취소한다.
    @State private var runID = 0
    @State private var endpoint = ""
    @State private var rate: SSEDemoRate = .normal
    @State private var errorMessage: String?
    @State private var parsesDollarMath = false
    @State private var equationAlignment: EquationAlignmentOption = .leading
    @State private var preset = RichMarkdownThemePreset.fromLaunchArguments()
    @FocusState private var endpointFocused: Bool

    private var theme: RichMarkdownTheme {
        var theme = preset.theme
        theme.equationAlignment = equationAlignment.latexAlignment
        return theme
    }

    var body: some View {
        VStack(spacing: 0) {
            SSETranscriptView(
                buffer: buffer,
                counter: counter,
                isStreaming: isStreaming,
                parsesDollarMath: parsesDollarMath,
                theme: theme
            )
            Divider()
            controls
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("SSE 실시간 렌더링")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("$ 수식 파싱 (opt-in)", isOn: $parsesDollarMath)
                    EquationAlignmentMenu(selection: $equationAlignment)
                    Picker("테마", selection: $preset) {
                        ForEach(RichMarkdownThemePreset.allCases) { preset in
                            Text(verbatim: preset.rawValue).tag(preset)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("렌더 옵션")
            }
        }
        .task(id: runID) {
            guard isStreaming else { return }
            await stream()
        }
        .task {
            // 성능 측정 자동 재생(`SSEDemoLaunchOptions`). 녹화가 시작된 뒤에 스트림을 연다.
            guard SSEDemoLaunchOptions.autoplay == .swiftui else { return }
            await SSEDemoLaunchOptions.waitForTracingStarted()
            guard !Task.isCancelled, !isStreaming else { return }
            start()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(isStreaming ? "중지" : "시작") {
                    if isStreaming { stop() } else { start() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("sseDemo.startStop")

                Picker("전송 속도", selection: $rate) {
                    ForEach(SSEDemoRate.allCases) { rate in
                        Text(verbatim: rate.rawValue).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                // 실제 엔드포인트에서는 서버가 속도를 정한다.
                .disabled(isStreaming || !trimmedEndpoint.isEmpty)
                .accessibilityIdentifier("sseDemo.rate")
            }

            TextField("SSE 엔드포인트 (비우면 로컬 시뮬레이션)", text: $endpoint)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($endpointFocused)
                .disabled(isStreaming)
                .accessibilityIdentifier("sseDemo.endpoint")

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sseDemo.error")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        buffer.reset()
        counter.reset()
        errorMessage = nil
        endpointFocused = false
        isStreaming = true
        runID += 1
    }

    private func stop() {
        buffer.flush()
        isStreaming = false
        runID += 1
    }

    /// 두 원본 모두 같은 디코더를 거친다. 로컬 시뮬레이션도 실제 프레임 문법을 그대로 만든다.
    ///
    /// `.task(id:)`는 이전 Task를 취소하지만 **완료를 기다리지 않는다**. 중지 직후 다시 시작하면
    /// 옛 Task가 뒤늦게 풀리며 새 스트림의 상태를 덮을 수 있어, 자기 세대일 때만 상태를 만진다.
    @MainActor
    private func stream() async {
        let run = runID
        var decoder = SSEDecoder()
        do {
            if trimmedEndpoint.isEmpty {
                try await streamSimulated(run: run, into: &decoder)
            } else {
                try await streamEndpoint(run: run, into: &decoder)
            }
        } catch is CancellationError {
            // 중지 버튼 또는 화면 이탈. 지금까지 받은 답변은 그대로 둔다.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession은 Task 취소를 URLError로 올린다.
        } catch {
            guard run == runID else { return }
            errorMessage = error.localizedDescription
        }
        guard run == runID else { return }
        isStreaming = false
    }

    @MainActor
    private func streamSimulated(run: Int, into decoder: inout SSEDecoder) async throws {
        let fixture = SSEDemoLaunchOptions.fixture
        try await SSEDemoFixtures.play(
            fixture.frames, rate: rate, label: "swiftui \(fixture.rawValue) \(rate.rawValue)"
        ) { line in
            run != runID || apply(decoder.consume(line))
        }
    }

    @MainActor
    private func streamEndpoint(run: Int, into decoder: inout SSEDecoder) async throws {
        guard let url = URL(string: trimmedEndpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else {
            throw SSEDemoError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSEDemoError.notEventStream("") }
        guard (200..<300).contains(http.statusCode) else {
            throw SSEDemoError.httpStatus(http.statusCode)
        }
        // SSE가 아닌 응답(HTML 페이지, 바이너리)을 줄 단위로 삼키지 않는다. 서버가 준 타입만
        // 짧게 되울린다.
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("text/event-stream") else {
            throw SSEDemoError.notEventStream(String(contentType.prefix(64)))
        }

        var splitter = SSELineSplitter()
        // ponytail: 바이트 단위 순회는 토큰 속도(초당 수백 바이트)에 충분하다.
        //           대용량 스트림이 필요해지면 청크 단위 분리기로 올린다.
        for try await byte in bytes {
            guard run == runID else { return }
            guard let line = splitter.consume(byte) else { continue }
            if apply(decoder.consume(line)) { return }
        }
        if let line = splitter.flush(), apply(decoder.consume(line)) { return }
        // 종료 blank line 없이 끊긴 스트림의 마지막 조각도 화면에 남긴다.
        _ = apply(decoder.finish())
    }

    /// 디코더 이벤트를 버퍼에 넣는다. 화면 갱신 빈도는 버퍼가 정한다. 스트림을 끝내야 하면 `true`.
    private func apply(_ event: SSEDecoder.Event?) -> Bool {
        switch event {
        case nil:
            return false

        case let .text(delta):
            counter.record(delta)
            buffer.append(delta)
            if counter.bytes >= SSEDemoLimits.answerByteCap {
                buffer.flush()
                errorMessage = "표시 상한(256 KiB)에 도달해 스트림을 끊었습니다."
                return true
            }
            return false

        case let .failure(message):
            buffer.flush()
            errorMessage = "서버가 오류를 보냈습니다: \(message)"
            return true

        case .done:
            buffer.flush()
            return true
        }
    }
}

/// SSE 화면의 도착 카운터. 청크마다(20Hz) 값만 올리고 화면 갱신을 일으키지 않는다. 상태 칩은 버퍼 게시
/// (≤10Hz) 때 본문과 함께 다시 그려지며 이 값을 읽는다 — UIKit 화면이 `render(_:)`에서 라벨을 고치는 것과
/// 같은 박자다. 모든 청크는 게시나 종료 flush로 끝나므로 스트림이 끝난 뒤의 표시는 항상 최종 값이다.
@MainActor
final class SSEStreamCounter {
    private(set) var chunks = 0
    /// `answer.count`는 매 프레임 전체 grapheme 순회(O(n))라 델타 길이를 더한다.
    private(set) var characters = 0
    private(set) var bytes = 0

    var label: String { "\(chunks) 청크 · \(characters)자" }

    func record(_ delta: String) {
        chunks += 1
        characters += delta.count
        bytes += delta.utf8.count
    }

    func reset() {
        chunks = 0
        characters = 0
        bytes = 0
    }
}

/// SSE 화면 본문. 버퍼를 구독하는 유일한 뷰라 게시마다 이 뷰만 다시 그린다.
private struct SSETranscriptView: View {
    private static let bottomAnchor = "sseDemo.bottom"

    @ObservedObject var buffer: RichMarkdownStreamingTextBuffer
    let counter: SSEStreamCounter
    let isStreaming: Bool
    let parsesDollarMath: Bool
    let theme: RichMarkdownTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SSEStatusChip(label: counter.label, isStreaming: isStreaming)
                    if buffer.text.isEmpty {
                        Text(verbatim: "시작을 누르면 SSE 프레임이 도착하는 대로 렌더링합니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // README «스트리밍» 패턴 그대로: 버퍼가 게시한 누적 전체 문자열을 넘긴다.
                        // 라이브러리가 스트리밍 append에서 이전 렌더를 유지하므로(모델의
                        // append 계약) 갱신마다 원문으로 되돌아가는 플래시가 없다.
                        RichMarkdownView(markdown: buffer.text, parsesDollarMath: parsesDollarMath)
                            .richMarkdownStreaming(isStreaming ? .default : nil)
                            .richMarkdownTheme(theme)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: DemoLayout.readableWidth, alignment: .leading)
                .padding(DemoLayout.horizontalMargin)
                .frame(maxWidth: .infinity)
                .modifier(SSEContentHeightReporter())
            }
            .modifier(SSEBottomFollowing(proxy: proxy, anchorID: Self.bottomAnchor))
        }
    }
}

/// 내용이 자라면 하단을 따라간다. 예전처럼 `onReceive(buffer.$text)`에서 `proxy.scrollTo`를 부르면
/// @Published setter 안에서 그래프 트랜잭션이 동기로 flush된다(p7 실측: 메인 스레드의 14%).
/// - iOS 18+: 크기 변화에만 하단 고정(`.sizeChanges`). 초기 위치와 짧은 내용의 정렬은 위 그대로다.
/// - iOS 17: `defaultScrollAnchor(.bottom)`(역할 구분 API가 없다).
/// - iOS 16: 내용 높이가 바뀔 때만, 게시 밖(다음 런루프)에서 `scrollTo`한다.
private struct SSEBottomFollowing: ViewModifier {
    let proxy: ScrollViewProxy
    let anchorID: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else if #available(iOS 17.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content.onPreferenceChange(SSEContentHeightKey.self) { _ in
                DispatchQueue.main.async { proxy.scrollTo(anchorID, anchor: .bottom) }
            }
        }
    }
}

/// iOS 16 하단 추적용 내용 높이. iOS 17+는 스크롤 앵커가 맡아 측정하지 않는다.
private struct SSEContentHeightReporter: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
        } else {
            content.background(
                GeometryReader { geometry in
                    Color.clear.preference(key: SSEContentHeightKey.self, value: geometry.size.height)
                }
            )
        }
    }
}

private struct SSEContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 받은 청크·글자 수 칩. 입력이 바뀔 때만 다시 그린다. `.fixedSize()`로 이상적 크기를 써서 숫자가 자라도
/// 줄 바꿈·말줄임으로 흔들리지 않는다.
private struct SSEStatusChip: View {
    let label: String
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
            Text(verbatim: label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.label))
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
                .accessibilityIdentifier("sseDemo.status")
        }
    }
}
