// Created by JunyoungJung on 2026-08-28.

import Combine
import SwiftLatex
import SwiftUI
import UIKit

// MARK: - SwiftUI 껍데기

/// SSE 스트리밍을 UIKit 네이티브 렌더러(`LatexMarkdownUIView`)로 확인하는 화면.
///
/// SwiftUI 화면(`SSEDemoView`)과 같은 디코더(`SSEDecoder`)·줄 분리기(`SSELineSplitter`)·
/// fixture·게시 게이트를 쓰고 렌더러 배선만 다르다. 확인 대상:
/// 1. 스트리밍 append에서 블록 뷰 증분 재사용(0.3.0 성능 작업)이 그대로 동작하는지.
/// 2. `onContentSizeChange` 기반 자동 스크롤.
/// 3. 테마·정렬 교체가 살아 있는 뷰에 반영되는지.
struct UIKitSSEDemoView: View {
    @State private var parsesDollarMath = false
    @State private var equationAlignment: EquationAlignmentOption = .leading
    @State private var preset = LatexThemePreset.fromLaunchArguments()

    private var theme: LatexTheme {
        var theme = preset.theme
        theme.equationAlignment = equationAlignment.latexAlignment
        return theme
    }

    var body: some View {
        UIKitSSEDemoContainer(theme: theme, parsesDollarMath: parsesDollarMath)
            .navigationTitle("SSE 실시간 렌더링 (UIKit)")
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
    }
}

struct UIKitSSEDemoContainer: UIViewControllerRepresentable {
    let theme: LatexTheme
    let parsesDollarMath: Bool

    func makeUIViewController(context: Context) -> UIKitSSEDemoViewController {
        UIKitSSEDemoViewController(theme: theme, parsesDollarMath: parsesDollarMath)
    }

    func updateUIViewController(_ controller: UIKitSSEDemoViewController, context: Context) {
        controller.theme = theme
        controller.parsesDollarMath = parsesDollarMath
    }
}

// MARK: - 컨트롤러

final class UIKitSSEDemoViewController: UIViewController {
    var theme: LatexTheme {
        didSet { messageView.theme = theme }
    }

    var parsesDollarMath: Bool {
        didSet { messageView.parsesDollarMath = parsesDollarMath }
    }

    // 전송 상태 — `SSEDemoView`와 같은 필드 구성. 화면별 배선을 그대로 보여주는 데모라
    // 전송 루프도 그 화면과 동일하게 둔다.
    /// 도착 속도와 화면 갱신을 분리하는 latest-wins 버퍼. 게시마다 `render(_:)`가 뷰를 갱신한다.
    private let buffer = LatexStreamingTextBuffer(interval: SSEDemoLimits.publishInterval)
    private var bufferCancellable: AnyCancellable?
    private var answerCharacters = 0
    private var answerBytes = 0
    private var chunkCount = 0
    /// 재시작 신호. 시작·중지 모두 값을 올려 늦게 풀린 이전 Task가 상태를 덮지 못하게 한다.
    private var runID = 0
    private var streamTask: Task<Void, Never>?
    private var isStreaming = false {
        didSet {
            updateControls()
            // 스트리밍 표시(꼬리 페이드·미닫힌 마크 억제·in-place 갱신)는 스트림 동안만 켠다.
            messageView.streaming = isStreaming ? .default : nil
        }
    }

    private let scrollView = UIScrollView()
    private let messageView = LatexMarkdownUIView()
    private let bubble = UIView()
    private let placeholderLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let startStopButton = UIButton(configuration: .filled())
    private let rateControl = UISegmentedControl(items: SSEDemoRate.allCases.map(\.rawValue))
    private let endpointField = UITextField()
    private let errorLabel = UILabel()

    private var rate: SSEDemoRate {
        let index = rateControl.selectedSegmentIndex
        guard SSEDemoRate.allCases.indices.contains(index) else { return .normal }
        return SSEDemoRate.allCases[index]
    }

    private var trimmedEndpoint: String {
        (endpointField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(theme: LatexTheme, parsesDollarMath: Bool) {
        self.theme = theme
        self.parsesDollarMath = parsesDollarMath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UIKitSSEDemoViewController는 코드로만 생성한다")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        buildTranscript()
        buildControls()
        bufferCancellable = buffer.$text
            .dropFirst()
            .sink { [weak self] text in self?.render(text) }
    }

    /// 버퍼 게시마다 누적 전체 문자열을 다시 넘긴다(라이브러리 계약). 스트리밍 append라
    /// 렌더러가 이전 렌더를 유지한 채 블록 뷰를 증분 재사용한다.
    private func render(_ text: String) {
        guard !text.isEmpty else { return }
        placeholderLabel.isHidden = true
        bubble.isHidden = false
        messageView.markdown = text
        updateStatus()
        scrollToBottom()
    }

    /// 화면을 떠나면 스트림을 멈춘다. SwiftUI 화면의 `.task(id:)` 수명과 같은 의미다.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    // MARK: 레이아웃

    private func buildTranscript() {
        messageView.theme = theme
        messageView.parsesDollarMath = parsesDollarMath
        messageView.translatesAutoresizingMaskIntoConstraints = false
        // 수식 hydration·블록 재구성으로 높이가 바뀌는 시점이 곧 스크롤 하단 추적 시점이다.
        messageView.onContentSizeChange = { [weak self] in
            guard let self, self.isStreaming else { return }
            self.scrollToBottom()
        }

        bubble.backgroundColor = .secondarySystemGroupedBackground
        bubble.layer.cornerRadius = 18
        bubble.isHidden = true
        bubble.addSubview(messageView)

        placeholderLabel.text = "시작을 누르면 SSE 프레임이 도착하는 대로 렌더링합니다."
        placeholderLabel.font = .preferredFont(forTextStyle: .callout)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "uikitSseDemo.status"
        spinner.hidesWhenStopped = true
        updateStatus()

        let statusSpacer = UIView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel, statusSpacer])
        statusRow.spacing = 8
        statusRow.alignment = .center

        let contentStack = UIStackView(arrangedSubviews: [statusRow, placeholderLabel, bubble])
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 14),
            messageView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            messageView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            messageView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -14),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func buildControls() {
        var configuration = startStopButton.configuration ?? .filled()
        configuration.title = "시작"
        startStopButton.configuration = configuration
        startStopButton.accessibilityIdentifier = "uikitSseDemo.startStop"
        startStopButton.setContentHuggingPriority(.required, for: .horizontal)
        startStopButton.addAction(
            UIAction { [weak self] _ in self?.toggleStreaming() },
            for: .touchUpInside
        )

        rateControl.selectedSegmentIndex = SSEDemoRate.allCases.firstIndex(of: .normal) ?? 0
        rateControl.accessibilityIdentifier = "uikitSseDemo.rate"

        endpointField.placeholder = "SSE 엔드포인트 (비우면 로컬 시뮬레이션)"
        endpointField.borderStyle = .roundedRect
        endpointField.font = {
            let callout = UIFont.preferredFont(forTextStyle: .callout)
            guard let descriptor = callout.fontDescriptor.withDesign(.monospaced) else { return callout }
            return UIFont(descriptor: descriptor, size: 0)
        }()
        endpointField.adjustsFontForContentSizeCategory = true
        endpointField.autocapitalizationType = .none
        endpointField.autocorrectionType = .no
        endpointField.keyboardType = .URL
        endpointField.returnKeyType = .done
        endpointField.accessibilityIdentifier = "uikitSseDemo.endpoint"
        endpointField.addAction(
            UIAction { [weak self] _ in self?.updateControls() },
            for: .editingChanged
        )
        endpointField.addAction(
            UIAction { [weak self] _ in self?.endpointField.resignFirstResponder() },
            for: .primaryActionTriggered
        )

        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "uikitSseDemo.error"

        let controlRow = UIStackView(arrangedSubviews: [startStopButton, rateControl])
        controlRow.spacing = 12
        controlRow.alignment = .center

        let controlsStack = UIStackView(arrangedSubviews: [controlRow, endpointField, errorLabel])
        controlsStack.axis = .vertical
        controlsStack.spacing = 10
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlsStack)

        let divider = UIView()
        divider.backgroundColor = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        view.addSubview(container)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),

            controlsStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 키보드가 없을 때는 safe area 하단과 일치하고, 올라오면 그 위로 따라간다.
            container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.topAnchor),
        ])
    }

    // MARK: 상태 반영

    private func updateControls() {
        var configuration = startStopButton.configuration ?? .filled()
        configuration.title = isStreaming ? "중지" : "시작"
        startStopButton.configuration = configuration
        // 실제 엔드포인트에서는 서버가 속도를 정한다 (SwiftUI 화면과 동일).
        rateControl.isEnabled = !isStreaming && trimmedEndpoint.isEmpty
        endpointField.isEnabled = !isStreaming
        if isStreaming { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func updateStatus() {
        statusLabel.text = "\(chunkCount) 청크 · \(answerCharacters)자"
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    private func scrollToBottom() {
        scrollView.layoutIfNeeded()
        let overflow = scrollView.contentSize.height
            + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height
        let top = -scrollView.adjustedContentInset.top
        scrollView.setContentOffset(CGPoint(x: 0, y: max(top, overflow)), animated: false)
    }

    // MARK: 스트리밍 (SSEDemoView와 같은 전송 로직)

    private func toggleStreaming() {
        if isStreaming { stop() } else { start() }
    }

    private func start() {
        buffer.reset()
        answerCharacters = 0
        answerBytes = 0
        chunkCount = 0
        errorLabel.isHidden = true
        endpointField.resignFirstResponder()
        messageView.markdown = ""
        bubble.isHidden = true
        placeholderLabel.isHidden = false
        updateStatus()

        isStreaming = true
        runID += 1
        let run = runID
        streamTask = Task { [weak self] in
            await self?.stream(run: run)
        }
    }

    private func stop() {
        buffer.flush()
        isStreaming = false
        runID += 1
        streamTask?.cancel()
        streamTask = nil
    }

    private func stream(run: Int) async {
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
            showError(error.localizedDescription)
        }
        guard run == runID else { return }
        isStreaming = false
    }

    private func streamSimulated(run: Int, into decoder: inout SSEDecoder) async throws {
        frames: for frame in SSEDemoFixtures.frames() {
            try await Task.sleep(for: rate.interval)
            guard run == runID else { return }
            for line in frame {
                if apply(decoder.consume(line)) { break frames }
            }
        }
    }

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
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("text/event-stream") else {
            throw SSEDemoError.notEventStream(String(contentType.prefix(64)))
        }

        var splitter = SSELineSplitter()
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
                showError("표시 상한(256 KiB)에 도달해 스트림을 끊었습니다.")
                return true
            }
            return false

        case let .failure(message):
            buffer.flush()
            showError("서버가 오류를 보냈습니다: \(message)")
            return true

        case .done:
            buffer.flush()
            return true
        }
    }
}
