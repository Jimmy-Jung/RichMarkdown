// Author: JunyoungJung
// Date: 2026-10-14

import Foundation
import UIKit
import XCTest

/// 반복별 측정값을 metric 식별자별로 모은다.
final class MeasurementRecorder {
    struct Series {
        let identifier: String
        let label: String
        let unit: String
        var values: [Double]
    }

    private(set) var series: [Series] = []

    func append(_ measurements: [XCTPerformanceMeasurement]) {
        for measurement in measurements {
            if let index = series.firstIndex(where: { $0.identifier == measurement.identifier }) {
                series[index].values.append(measurement.doubleValue)
            } else {
                series.append(Series(
                    identifier: measurement.identifier,
                    label: measurement.displayName,
                    unit: measurement.unitSymbol,
                    values: [measurement.doubleValue]
                ))
            }
        }
    }

    /// `BENCH {...}` 한 줄씩 표준 출력에 쓴다. `scripts/bench/collect.py`가 이 줄만 읽는다.
    ///
    /// XCTest는 `iterations`회 앞에 버리는 예열 1회를 더 돈다(실측: 값 11개 중 첫 값이 예열).
    /// 통계에서 빼되 `warmup`으로 남긴다. 단위는 측정 객체의 기본 단위(ns·byte·I·C) 그대로다.
    func emit(name: String, iterations: Int) {
        for item in series {
            var object: [String: Any] = [
                "name": name,
                "metric": item.identifier,
                "label": item.label,
                "unit": item.unit,
                "values": Array(item.values.suffix(iterations)),
            ]
            if item.values.count > iterations, let warmup = item.values.first {
                object["warmup"] = warmup
            }
            BenchmarkOutput.print(tag: "BENCH", object)
        }
    }
}

/// XCTest 내장 metric을 감싸 반복별 측정값을 가로챈다.
///
/// XCTest가 부르는 hook을 그대로 위임하므로 xcresult에 남는 값과 BENCH 줄의 값이 같다.
/// `measure`는 측정값을 돌려주는 API가 없어서 이 경로가 결과를 읽는 유일한 공개 방법이다.
final class RecordingMetric: NSObject, XCTMetric {
    private let inner: any XCTMetric
    private let recorder: MeasurementRecorder

    init(_ inner: any XCTMetric, recorder: MeasurementRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func copy(with zone: NSZone? = nil) -> Any {
        let innerCopy = (inner.copy(with: zone) as? any XCTMetric) ?? inner
        return RecordingMetric(innerCopy, recorder: recorder)
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp,
        to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        let measurements = try inner.reportMeasurements(from: startTime, to: endTime)
        recorder.append(measurements)
        return measurements
    }

    func willBeginMeasuring() { inner.willBeginMeasuring?() }
    func didStopMeasuring() { inner.didStopMeasuring?() }

    // 내장 metric(메모리·CPU)은 공개 hook 외의 표본 수집 메시지도 받는다(위임 없이 감싸면
    // `-[MXMMemoryMetric harvestData:error:]` assertion으로 실패 — 실측). 모르는 메시지는 그대로 넘긴다.
    override func conforms(to aProtocol: Protocol) -> Bool {
        super.conforms(to: aProtocol) || inner.conforms(to: aProtocol)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || inner.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        inner.responds(to: aSelector) ? inner : super.forwardingTarget(for: aSelector)
    }
}

enum BenchmarkOutput {
    /// 측정 직전의 열 상태·충전 상태. 결과 해석(스로틀링 여부)에 쓴다.
    @MainActor
    static func printEnvironment(_ name: String) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let thermal = ["nominal", "fair", "serious", "critical"]
        let battery = ["unknown", "unplugged", "charging", "full"]
        print(tag: "BENCH_ENV", [
            "name": name,
            "model": device.model,
            "os": device.systemVersion,
            "thermal": thermal[min(ProcessInfo.processInfo.thermalState.rawValue, thermal.count - 1)],
            "battery": battery[min(device.batteryState.rawValue, battery.count - 1)],
            "batteryLevel": device.batteryLevel,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ])
    }

    /// 기계 판독용 한 줄. 키 정렬로 줄 비교가 안정적이다.
    static func print(tag: String, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        Swift.print("\(tag) \(String(decoding: data, as: UTF8.self))")
    }
}

extension XCTestCase {
    /// 시계·메모리·CPU 3종을 `iterations`회 측정하고 BENCH 줄을 남긴다.
    /// `measure`는 테스트 메서드당 한 번만 부를 수 있으므로 벤치마크 하나에 메서드 하나다.
    ///
    /// 교차 확인(`scripts/bench/ios-micro.sh`, `CROSS_CHECK=1`)에서는 `RICHMARKDOWN_BENCH_TRACE=1`이면
    /// xctrace 녹화 시작 알림을 기다린 뒤 측정하고, `RICHMARKDOWN_BENCH_ITERATIONS`로 반복 수를 바꾼다.
    @MainActor
    func benchmark(_ name: String, iterations: Int = 10, _ block: () -> Void) {
        let environment = ProcessInfo.processInfo.environment
        let iterations = environment["RICHMARKDOWN_BENCH_ITERATIONS"].flatMap(Int.init) ?? iterations
        let traced = environment["RICHMARKDOWN_BENCH_TRACE"] == "1"
        BenchmarkOutput.printEnvironment(name)
        if traced { TraceGate.waitForRecording(name) }
        let start = Date()
        defer { if traced { TraceGate.emitWindow(name, start: start, end: Date()) } }

        let recorder = MeasurementRecorder()
        let builtIn: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric()]
        let metrics = builtIn.map { RecordingMetric($0, recorder: recorder) }
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        measure(metrics: metrics, options: options, block: block)
        recorder.emit(name: name, iterations: iterations)
    }
}

/// xctrace 녹화와 측정 구간을 맞춘다. 스크립트가 녹화 시작 뒤 `devicectl device notification post`로
/// 보내는 Darwin 알림을 기다린다 (데모 `PerfScenarioUITests`와 같은 이름·방식).
enum TraceGate {
    static let notification = "dev.richmarkdown.perf.tracing-started"

    @MainActor
    static func waitForRecording(_ name: String, timeout: TimeInterval = 180) {
        let signal = DarwinSignal(name: notification)
        emit("PERF_READY \(name)")
        let deadline = Date().addingTimeInterval(timeout)
        while !signal.hasFired, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        Thread.sleep(forTimeInterval: 1)
    }

    static func emitWindow(_ name: String, start: Date, end: Date) {
        emit(String(
            format: "PERF_WINDOW %@ start_ms=0 end_ms=0 start_epoch=%.3f end_epoch=%.3f",
            name, start.timeIntervalSince1970, end.timeIntervalSince1970
        ))
    }

    /// 버퍼 없이 바로 쓴다. 스크립트가 xcodebuild 출력에서 이 줄을 기다린다.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

private final class DarwinSignal: @unchecked Sendable {
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

    var hasFired: Bool { lock.withLock { fired } }

    private func markFired() { lock.withLock { fired = true } }
}
