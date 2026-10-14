// Author: JunyoungJung
// Date: 2026-10-14

import Foundation
import Testing
import UIKit
@testable import RichMarkdown

/// 대표 fixture의 `RichMarkdownUIView` 렌더 스냅샷 (의존성 없음).
///
/// 폭 375pt · scale 1로 그려 `__Snapshots__/RenderSnapshotTests/*.png`와 픽셀 비교한다.
/// 채널 차이가 8을 넘는 픽셀이 0.5%를 넘으면 실패하고 실제·diff PNG를
/// `RICHMARKDOWN_SNAPSHOT_ARTIFACTS`(기본: 빌드 산출물 옆 `SnapshotArtifacts`)에 쓴다.
///
/// - 기록: `TEST_RUNNER_RICHMARKDOWN_RECORD_SNAPSHOTS=1 xcodebuild test …`
/// - 참조 이미지는 한 destination(iPhone 17 Pro · iOS 26.5 시뮬레이터)에 묶인다.
///   글꼴 래스터라이즈가 OS·기기마다 달라 다른 곳에서는 건너뛴다.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: SnapshotDestination.isReference,
        "렌더 스냅샷 참조는 iPhone 17 Pro(iPhone18,1) · iOS 26.5 시뮬레이터 전용이다"
    )
)
struct RenderSnapshotTests {

    nonisolated static let fixtures = [
        "samples/math-quadratic",
        "samples/math-calculus-integral",
        "samples/math-linear-algebra",
        "samples/statistics-normal",
        "samples/table-comparison",
        "samples/list-steps-nested",
        "samples/code-swift-explanation",
        "samples/english-mixed",
        "math/greek-and-operators",
        "unicode/mixed-scripts",
    ]

    struct Variant: Sendable, CustomTestStringConvertible {
        let dark: Bool
        let accessibilitySize: Bool

        var name: String { "\(dark ? "dark" : "light").\(accessibilitySize ? "axXL" : "default")" }
        var testDescription: String { name }

        static let all = [false, true].flatMap { dark in
            [false, true].map { Variant(dark: dark, accessibilitySize: $0) }
        }
    }

    private nonisolated static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    private static let fixturesDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let referenceDirectory = testsDirectory.appendingPathComponent("__Snapshots__/RenderSnapshotTests")

    /// 기본은 `xcodebuild -derivedDataPath`의 Build 폴더 아래다. 없으면 임시 폴더.
    private static var artifactsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["RICHMARKDOWN_SNAPSHOT_ARTIFACTS"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let products = environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"]?.split(separator: ":").first {
            return URL(fileURLWithPath: String(products), isDirectory: true)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SnapshotArtifacts/RenderSnapshotTests", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("RenderSnapshotTests", isDirectory: true)
    }

    private static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RICHMARKDOWN_RECORD_SNAPSHOTS"] == "1"
    }

    @Test(arguments: fixtures, Variant.all)
    func renderMatchesReference(_ fixture: String, _ variant: Variant) async throws {
        let markdown = try String(
            contentsOf: Self.fixturesDirectory.appendingPathComponent("\(fixture).md"),
            encoding: .utf8
        )
        let png = try #require(try await render(markdown, variant).pngData())
        let name = "\(fixture.replacingOccurrences(of: "/", with: "-")).\(variant.name)"
        let referenceURL = Self.referenceDirectory.appendingPathComponent("\(name).png")

        if Self.isRecording {
            try FileManager.default.createDirectory(at: Self.referenceDirectory, withIntermediateDirectories: true)
            try png.write(to: referenceURL)
            return
        }
        guard let referenceData = try? Data(contentsOf: referenceURL) else {
            try writeArtifacts(name: name, actual: png, diff: nil)
            Issue.record("참조 이미지가 없다: \(referenceURL.lastPathComponent). RICHMARKDOWN_RECORD_SNAPSHOTS=1로 기록한다.")
            return
        }

        let actual = try #require(Bitmap(png: png))
        let reference = try #require(Bitmap(png: referenceData))
        let comparison = actual.compare(with: reference, channelTolerance: 8)
        guard comparison.differingRatio > 0.005 else { return }
        try writeArtifacts(name: name, actual: png, diff: comparison.diffPNG)
        Issue.record(
            "\(name): \(comparison.summary) — 실제·diff PNG: \(Self.artifactsDirectory.path)"
        )
    }

    // MARK: - 렌더

    private func render(_ markdown: String, _ variant: Variant) async throws -> UIImage {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 1_000))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }
        if #available(iOS 17.0, *) {
            host.traitOverrides.userInterfaceStyle = variant.dark ? .dark : .light
            host.traitOverrides.preferredContentSizeCategory = variant.accessibilitySize ? .accessibilityExtraLarge : .large
            host.traitOverrides.displayScale = 1
        }

        let view = RichMarkdownUIView(markdown: markdown)
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: 375),
        ])
        try await waitUntilSettled(view)

        let traits = view.traitCollection
        #expect(traits.displayScale == 1)
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = 1
        format.opaque = true
        // 8-bit sRGB. 기본 범위(automatic)는 16-bit PNG가 되어 파일이 두 배다.
        format.preferredRange = .standard
        let background = UIColor.systemBackground.resolvedColor(with: traits)
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            background.setFill()
            context.fill(view.bounds)
            view.layer.render(in: context.cgContext)
        }
    }

    /// 완료 신호: worker가 마지막 generation(수식 raster hydration 게시 포함)을 끝내고
    /// (`hasOutstandingWork == false`), 그 게시가 예약한 rebuild까지 반영된 상태
    /// (`hasPendingRebuild == false`). trait 반영으로 재제출이 늦게 올 수 있어 레이아웃 뒤
    /// 두 번 연속 확인한다.
    private func waitUntilSettled(_ view: RichMarkdownUIView, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var settledChecks = 0
        while settledChecks < 2 {
            try #require(Date() < deadline, "렌더가 제한 시간 안에 끝나야 한다")
            view.window?.layoutIfNeeded()
            if view.model.hasOutstandingWork || view.hasPendingRebuild {
                settledChecks = 0
            } else {
                settledChecks += 1
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        view.window?.layoutIfNeeded()
        Self.displayRecursively(view.layer)
        #expect(view.bounds.height > 0)
    }

    private static func displayRecursively(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach(displayRecursively)
    }

    private func writeArtifacts(name: String, actual: Data, diff: Data?) throws {
        let directory = Self.artifactsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try actual.write(to: directory.appendingPathComponent("\(name).actual.png"))
        try diff?.write(to: directory.appendingPathComponent("\(name).diff.png"))
    }
}

/// 참조 이미지를 기록한 destination. Suite 특성에서 자기 타입을 참조하면 매크로가 순환하므로 밖에 둔다.
private enum SnapshotDestination {
    static var isReference: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone18,1"
            && version.majorVersion == 26 && version.minorVersion == 5
    }
}

/// sRGB RGBA8 비트맵. PNG를 같은 색공간으로 풀어 채널 단위로 비교한다.
private struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    struct Comparison {
        let differingRatio: Double
        let summary: String
        let diffPNG: Data?
    }

    init?(png: Data) {
        guard let image = UIImage(data: png)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (w, h) = (image.width, image.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    private init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 채널 차이가 `channelTolerance`를 넘는 픽셀 비율. 크기가 다르면 전부 다른 것으로 본다.
    /// diff는 다른 픽셀을 빨강, 같은 픽셀을 참조의 옅은 회색으로 칠한다.
    func compare(with reference: Bitmap, channelTolerance: Int) -> Comparison {
        guard width == reference.width, height == reference.height else {
            return Comparison(
                differingRatio: 1,
                summary: "크기 \(width)×\(height) ≠ 참조 \(reference.width)×\(reference.height)",
                diffPNG: nil
            )
        }
        var diff = [UInt8](repeating: 255, count: pixels.count)
        var differing = 0
        var maxDelta = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(pixels[offset + channel]) - Int(reference.pixels[offset + channel])))
            }
            maxDelta = max(maxDelta, delta)
            if delta > channelTolerance {
                differing += 1
                (diff[offset], diff[offset + 1], diff[offset + 2]) = (255, 0, 0)
            } else {
                let gray = UInt8(170 + Int(reference.pixels[offset]) / 3)
                (diff[offset], diff[offset + 1], diff[offset + 2]) = (gray, gray, gray)
            }
        }
        let ratio = Double(differing) / Double(width * height)
        return Comparison(
            differingRatio: ratio,
            summary: "다른 픽셀 \(differing)개(\(String(format: "%.3f", ratio * 100))%), 최대 채널 차 \(maxDelta)",
            diffPNG: Bitmap(width: width, height: height, pixels: diff).pngData()
        )
    }

    private func pngData() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
