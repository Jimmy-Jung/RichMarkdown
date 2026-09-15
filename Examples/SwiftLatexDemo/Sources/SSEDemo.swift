// Created by JunyoungJung on 2026-08-28.

import Foundation
import SwiftLatex
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

// MARK: - 전송 속도

/// 로컬 시뮬레이션의 프레임 간격. README 권장치(~10Hz)의 위·아래를 모두 확인하려고 셋을 둔다.
/// 60Hz에서도 내부 coalescing(실행 1 + 대기 1)이 렌더를 흡수해야 한다.
/// **명목 간격**이라 실제 주기는 렌더 비용만큼 늘어난다 — 루프가 MainActor에서 sleep과
/// 상태 갱신을 직렬로 돌기 때문이다.
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
}

/// 두 SSE 데모 화면(SwiftUI·UIKit)이 공유하는 상한.
enum SSEDemoLimits {
    /// 누적 답변 상한. `SwiftLatexCore.InputLimits.maxInputUTF8Bytes`와 같은 값이다
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
/// 문자열**을 계속 넘기고, `LatexMarkdownView` 내부 `CoalescingWorker`가 연속 갱신을 합쳐
/// 최신 값만 렌더한다. 이 화면은 그 계약을 실제 SSE 프레임으로 확인한다.
///
/// - 엔드포인트가 비면 fixture를 SSE 프레임으로 만들어 로컬에서 흘린다(네트워크 불필요).
/// - 엔드포인트를 넣으면 `URLSession.bytes`로 실제 `text/event-stream`을 읽는다.
///   인증 헤더는 붙이지 않으므로 토큰이 필요한 게이트웨이는 로컬 프록시를 두고 붙인다.
struct SSEDemoView: View {
    private static let bottomAnchor = "sseDemo.bottom"

    /// 도착 속도와 화면 갱신을 분리하는 latest-wins 버퍼. trailing 게시로 마지막 조각도 화면에 오른다.
    @StateObject private var buffer = LatexStreamingTextBuffer(interval: SSEDemoLimits.publishInterval)
    /// 라벨용 카운터. `answer.count`는 매 프레임 전체 grapheme 순회(O(n))라 쓰지 않는다.
    @State private var answerCharacters = 0
    @State private var answerBytes = 0
    @State private var chunkCount = 0
    @State private var isStreaming = false
    /// `.task(id:)` 재시작 신호. 시작·중지 모두 값을 올려 이전 스트림 Task를 취소한다.
    @State private var runID = 0
    @State private var endpoint = ""
    @State private var rate: SSEDemoRate = .normal
    @State private var errorMessage: String?
    @State private var parsesDollarMath = false
    @State private var equationAlignment: EquationAlignmentOption = .leading
    @State private var preset = LatexThemePreset.fromLaunchArguments()
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var endpointFocused: Bool

    private var theme: LatexTheme {
        var theme = preset.theme
        theme.equationAlignment = equationAlignment.latexAlignment
        return theme
    }

    var body: some View {
        VStack(spacing: 0) {
            transcriptView
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
                        ForEach(LatexThemePreset.allCases) { preset in
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
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusRow
                    if buffer.text.isEmpty {
                        Text(verbatim: "시작을 누르면 SSE 프레임이 도착하는 대로 렌더링합니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // README «스트리밍» 패턴 그대로: 버퍼가 게시한 누적 전체 문자열을 넘긴다.
                        // 라이브러리가 스트리밍 append에서 이전 렌더를 유지하므로(모델의
                        // append 계약) 갱신마다 원문으로 되돌아가는 플래시가 없다.
                        LatexMarkdownView(markdown: buffer.text, parsesDollarMath: parsesDollarMath)
                            .latexStreaming(isStreaming ? .default : nil)
                            .latexTheme(theme)
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
            }
            .onAppear { scrollProxy = proxy }
            .onReceive(buffer.$text.dropFirst()) { _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
            Text(verbatim: "\(chunkCount) 청크 · \(answerCharacters)자")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
                .accessibilityIdentifier("sseDemo.status")
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
        answerCharacters = 0
        answerBytes = 0
        chunkCount = 0
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
        frames: for frame in SSEDemoFixtures.frames() {
            try await Task.sleep(for: rate.interval)
            guard run == runID else { return }
            for line in frame {
                if apply(decoder.consume(line)) { break frames }
            }
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
            chunkCount += 1
            answerCharacters += delta.count
            answerBytes += delta.utf8.count
            buffer.append(delta)
            if answerBytes >= SSEDemoLimits.answerByteCap {
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
