// Author: JunyoungJung
// Date: 2026-10-14

import Foundation
import UIKit
import XCTest

/// xctrace 시나리오 구동기. `scripts/bench/ios-trace-scenarios.sh`가 실기기에서 한 메서드씩 실행한다.
///
/// 흐름: 화면 진입·첫 렌더 대기 → `PERF_READY` 출력 → 스크립트가 xctrace를 붙이고 녹화가 시작되면
/// `devicectl device notification post`로 Darwin 알림을 보낸다(xctrace `--notify-tracing-started`는 기기 앱에
/// 닿지 않았다 — 실측) → 시나리오 실행 후 `PERF_WINDOW` 출력 → xctrace가 `--time-limit`으로 스스로 끝날 때까지
/// 앱을 살려 둔다(도중에 끊으면 Hitches 트레이스가 깨진다).
/// 조작은 좌표 드래그·고정 대기로 해서 시나리오 중 접근성 조회(앱 메인 스레드 부하)를 줄인다.
final class PerfScenarioUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        try PerfHarness.skipUnlessEnabled()
    }

    @MainActor
    func testChatScrollSwiftUI() throws {
        let app = PerfHarness.launchHome()
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        XCTAssertTrue(PerfHarness.firstSwiftUIBubble(app).waitForExistence(timeout: 30))
        try PerfHarness.record("chat-scroll-swiftui") { PerfHarness.scrollRoundTrip(app) }
    }

    @MainActor
    func testChatScrollUIKit() throws {
        let app = PerfHarness.launchHome()
        app.buttons["AI 챗봇 (UIKit)"].firstMatch.tap()
        let firstAnswer = app.textViews.matching(PerfHarness.firstAnswerPredicate).firstMatch
        XCTAssertTrue(firstAnswer.waitForExistence(timeout: 30))
        try PerfHarness.record("chat-scroll-uikit") { PerfHarness.scrollRoundTrip(app) }
    }

    @MainActor
    func testSSESwiftUI() throws {
        let app = PerfHarness.launchHome()
        app.buttons["SSE 실시간 렌더링 (SwiftUI)"].firstMatch.tap()
        let startStop = app.buttons["sseDemo.startStop"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 20))
        app.buttons["20Hz"].tap()
        try PerfHarness.record("sse-swiftui") {
            startStop.tap()
            Thread.sleep(forTimeInterval: PerfHarness.sseSeconds)
        }
    }

    @MainActor
    func testSSEUIKit() throws {
        let app = PerfHarness.launchHome()
        app.buttons["SSE 실시간 렌더링 (UIKit)"].firstMatch.tap()
        let startStop = app.buttons["uikitSseDemo.startStop"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 20))
        app.buttons["20Hz"].tap()
        try PerfHarness.record("sse-uikit") {
            startStop.tap()
            Thread.sleep(forTimeInterval: PerfHarness.sseSeconds)
        }
    }

    /// 코드 블록 확장 진입(SwiftUI 렌더러) → UIKit 렌더러 전환. 다이어그램 2개가 WKWebView로 그려진다.
    @MainActor
    func testMermaidEntry() throws {
        let app = PerfHarness.launchHome()
        let entry = app.buttons["코드 블록 확장 (Mermaid · Prism)"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        try PerfHarness.record("mermaid-entry") {
            entry.tap()
            Thread.sleep(forTimeInterval: 6)
            app.buttons["UIKit"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 6)
        }
    }

    /// 콜드 런치 → SwiftUI 챗 첫 진입. xctrace가 `--launch`로 앱을 띄우므로 테스트는 붙기만 한다.
    /// 창: 런치(녹화 시작 → 진입 탭), 진입(탭 → 4초).
    @MainActor
    func testColdLaunchToSwiftUIChat() throws {
        let app = XCUIApplication()
        app.terminate()
        let signal = DarwinSignal(name: PerfHarness.tracingStartedNotification)
        PerfHarness.emit("PERF_READY_LAUNCH cold-launch-chat")
        guard signal.wait(timeout: PerfHarness.readyTimeout) else {
            return XCTFail("xctrace 녹화 시작 알림이 오지 않았다")
        }
        let traceStart = Date()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "xctrace가 앱을 띄우지 못했다")
        app.activate()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)

        let tap = Date()
        app.buttons["AI 챗봇 (SwiftUI)"].firstMatch.tap()
        let bubbleVisible = PerfHarness.firstSwiftUIBubble(app).waitForExistence(timeout: 30)
        let firstBubble = Date()
        XCTAssertTrue(bubbleVisible)
        Thread.sleep(forTimeInterval: max(0, 4 - firstBubble.timeIntervalSince(tap)))

        PerfHarness.emitWindow("cold-launch-chat.launch", traceStart: traceStart, start: nil, end: tap)
        PerfHarness.emitWindow("cold-launch-chat.entry", traceStart: traceStart, start: tap, end: tap.addingTimeInterval(4))
        PerfHarness.emit(String(format: "PERF_FIRST_BUBBLE_MS cold-launch-chat %.0f", firstBubble.timeIntervalSince(tap) * 1000))
        PerfHarness.holdUntilTraceEnds(traceStart: traceStart)
    }
}

/// 성능 UI 테스트 공용 도구. `LaunchPerformanceTests`도 쓴다.
enum PerfHarness {
    /// 스크립트가 녹화 시작 뒤 `devicectl device notification post --name`으로 보내는 이름과 같아야 한다.
    static let tracingStartedNotification = "dev.richmarkdown.perf.tracing-started"
    static let readyTimeout: TimeInterval = 180
    /// 20 Hz 로컬 시뮬레이션 fixture 전체가 약 9초다 (DEVELOPMENT.md §7 iPad 측정 기록).
    static let sseSeconds: TimeInterval = 10
    static let firstAnswerPredicate = NSPredicate(
        format: "label CONTAINS %@ OR value CONTAINS %@", "원의 넓이는", "원의 넓이는"
    )

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// xcodebuild에 `TEST_RUNNER_RICHMARKDOWN_PERF=1`을 넘길 때만 돈다. 데모 test plan(CI)에서는 건너뛴다.
    static func skipUnlessEnabled() throws {
        try XCTSkipUnless(environment["RICHMARKDOWN_PERF"] == "1", "성능 측정 전용: TEST_RUNNER_RICHMARKDOWN_PERF=1")
    }

    /// 스크립트가 넘긴 xctrace `--time-limit`(초).
    static var traceSeconds: TimeInterval {
        environment["RICHMARKDOWN_PERF_TRACE_SECONDS"].flatMap(TimeInterval.init) ?? 30
    }

    @MainActor
    static func launchHome() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["RichMarkdown Demo"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    static func firstSwiftUIBubble(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "원의 넓이는")).firstMatch
    }

    /// `PERF_READY` → 녹화 시작 알림 → 1초 안정화 → 시나리오 → `PERF_WINDOW` → 녹화 종료까지 대기.
    @MainActor
    static func record(_ scenario: String, _ body: () -> Void) throws {
        let signal = DarwinSignal(name: tracingStartedNotification)
        emit("PERF_READY \(scenario)")
        guard signal.wait(timeout: readyTimeout) else {
            throw XCTSkip("xctrace 녹화 시작 알림이 오지 않았다: \(scenario)")
        }
        let traceStart = Date()
        emitEnvironment(scenario)
        Thread.sleep(forTimeInterval: 1)
        let start = Date()
        body()
        emitWindow(scenario, traceStart: traceStart, start: start, end: Date())
        holdUntilTraceEnds(traceStart: traceStart)
    }

    /// 6페이지 아래로, 6페이지 위로. 반 화면 드래그 + fling을 한 페이지로 친다.
    @MainActor
    /// XCUITest가 드래그마다 앱 유휴를 기다리므로(드래그 1회 약 2.7초, 실측) 추가 대기는 짧게 둔다.
    static func scrollRoundTrip(_ app: XCUIApplication, pages: Int = 6, pause: TimeInterval = 0.5) {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        for (from, to) in [(lower, upper), (upper, lower)] {
            for _ in 0..<pages {
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
                Thread.sleep(forTimeInterval: pause)
            }
        }
    }

    /// `start_ms`/`end_ms`는 알림 수신 기준이라 알림 지연만큼 늦다. 분석은 기기 시계의 epoch를
    /// 트레이스 TOC 시작 시각과 맞춰 쓴다(`scripts/bench/trace_summary.py`).
    /// `start == nil`은 녹화 시작(0 ms)이다 — 런치는 알림이 닿기 전에 이미 시작된다.
    static func emitWindow(_ scenario: String, traceStart: Date, start: Date?, end: Date) {
        let startMs = start.map { Int($0.timeIntervalSince(traceStart) * 1000) } ?? 0
        let endMs = Int(end.timeIntervalSince(traceStart) * 1000)
        let epochs = String(format: "start_epoch=%.3f end_epoch=%.3f", start?.timeIntervalSince1970 ?? 0, end.timeIntervalSince1970)
        emit("PERF_WINDOW \(scenario) start_ms=\(startMs) end_ms=\(endMs) \(epochs)")
    }

    /// 녹화가 `--time-limit`으로 끝날 때까지 앱을 살려 둔다.
    static func holdUntilTraceEnds(traceStart: Date) {
        let remaining = traceStart.addingTimeInterval(traceSeconds + 3).timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    /// 기기 열 상태(시스템 전체 값)와 충전 상태. 러너 프로세스에서 읽어도 같은 기기 값이다.
    @MainActor
    static func emitEnvironment(_ scenario: String) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let thermal = ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]
        let battery = ["unknown", "unplugged", "charging", "full"][min(device.batteryState.rawValue, 3)]
        emit("PERF_ENV \(scenario) thermal=\(thermal) battery=\(battery) level=\(device.batteryLevel)")
    }

    /// 버퍼 없이 바로 쓴다. 스크립트가 xcodebuild 출력에서 이 줄을 기다린다.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

/// 기기의 Darwin 알림 한 번을 기다린다. xctrace `--notify-tracing-started`가 녹화 시작 시 보낸다.
final class DarwinSignal: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var fired = false

    init(name: String) {
        self.name = name
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinSignal>.fromOpaque(observer).takeUnretainedValue().markFired()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    private var hasFired: Bool { lock.withLock { fired } }

    private func markFired() { lock.withLock { fired = true } }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasFired, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return hasFired
    }
}
