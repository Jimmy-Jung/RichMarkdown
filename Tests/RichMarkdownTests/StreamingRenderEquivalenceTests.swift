// Author: JunyoungJung
// Date: 2026-10-14

import Combine
import Foundation
import Testing
import UIKit
@testable import RichMarkdown
@testable import RichMarkdownCore

/// 렌더 수준 스트리밍 검사 (Tests/Fixtures/README.md §7).
///
/// `streaming/*.md`를 유니코드 스칼라 조각으로 잘라 데모(`UIKitSSEDemo`)와 같은 배선 —
/// `RichMarkdownStreamingTextBuffer` 게시 → `RichMarkdownUIView.markdown` 대입, 스트림 동안
/// `streaming = .default` — 으로 흘린 최종 결과가 전체 원문 한 번 렌더와 같은지 본다.
/// 문서(`ParsedDocument`)는 캐시를 거치지 않는 직접 파싱과, 뷰 계층은 전체 원문을 한 번
/// 대입한 뷰와 비교한다. 스트리밍 tail의 in-place 갱신이 남긴 흔적(페이드·숨긴 opener·
/// 낡은 접근성 label)이 있으면 뷰 계층 비교에서 드러난다.
@MainActor
@Suite(.serialized) struct StreamingRenderEquivalenceTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let chunkSize: Int
        var testDescription: String { "\(name) × \(chunkSize)" }
    }

    /// `#filePath` 두 단계 위의 `Fixtures/streaming`.
    nonisolated static let streamingDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/streaming", isDirectory: true)

    private struct ChunkSpec: Decodable {
        let sizes: [Int]
    }

    /// fixture × `.chunks.json`의 조각 크기. 디렉터리를 읽지 못하면 비어 있고
    /// `fixturesArePresent`가 실패한다.
    nonisolated static let cases: [Case] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: streamingDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".md") }.sorted().flatMap { file -> [Case] in
            let name = String(file.dropLast(3))
            let specURL = streamingDirectory.appendingPathComponent("\(name).chunks.json")
            guard let data = try? Data(contentsOf: specURL),
                  let spec = try? JSONDecoder().decode(ChunkSpec.self, from: data) else { return [] }
            return spec.sizes.map { Case(name: name, chunkSize: $0) }
        }
    }()

    @Test func fixturesArePresent() {
        let names = Set(Self.cases.map(\.name))
        #expect(names.count == 6, "streaming fixture 6종과 각 .chunks.json을 읽어야 한다: \(names.sorted())")
    }

    @Test(arguments: cases)
    func streamedRenderMatchesOneShotRender(_ testCase: Case) async throws {
        let full = try String(
            contentsOf: Self.streamingDirectory.appendingPathComponent("\(testCase.name).md"),
            encoding: .utf8
        )
        let chunks = Self.scalarChunks(full, size: testCase.chunkSize)

        let streamed = makeView()
        streamed.streaming = .default
        var identities: [String] = []
        var fallbacks: [String] = []
        let identitySink = streamed.model.$parseIdentity
            .compactMap { $0?.markdown }
            .sink { identities.append($0) }
        let fallbackSink = streamed.model.$fallbackMarkdown
            .dropFirst()
            .sink { fallbacks.append($0) }
        // 데모는 100ms 간격이다. 조각 사이 1ms 대기와 짧은 간격으로 latest-wins 합치기와
        // trailing 게시, 렌더 중간 게시가 모두 일어나게 한다.
        let buffer = RichMarkdownStreamingTextBuffer(interval: .milliseconds(5))
        let bufferSink = buffer.$text.dropFirst().sink { streamed.markdown = $0 }
        defer {
            identitySink.cancel()
            fallbackSink.cancel()
            bufferSink.cancel()
        }

        for chunk in chunks {
            buffer.append(chunk)
            streamed.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(1))
        }
        buffer.flush()
        streamed.streaming = nil
        try await waitForRender(streamed)

        #expect(buffer.text == full, "버퍼에 쌓인 조각은 원문과 같아야 한다")
        let document = try #require(streamed.model.document)
        #expect(streamed.model.parseIdentity?.markdown == full, "최종 게시는 마지막 제출이다")
        #expect(
            document == RichMarkdownParser.parse(markdown: full, parsesDollarMath: false),
            "스트리밍 최종 문서가 전체 원문 1회 파싱과 다르다"
        )

        // latest-wins: 게시된 문서·fallback 원문은 언제나 앞선 게시를 prefix로 갖는다.
        #expect(Self.firstRegression(in: identities) == nil, "더 새 문서 뒤에 이전 문서가 게시됐다")
        #expect(Self.firstRegression(in: fallbacks) == nil, "더 새 원문 뒤에 이전 원문이 게시됐다")
        #expect(identities.last == full)

        let reference = makeView()
        reference.markdown = full
        try await waitForRender(reference)
        #expect(reference.model.document == document)
        #expect(
            Self.describe(streamed.blockStack) == Self.describe(reference.blockStack),
            "스트리밍으로 만든 뷰 계층이 전체 원문 1회 렌더와 다르다"
        )
    }

    // MARK: - 도움 함수

    private func makeView() -> RichMarkdownUIView {
        let view = RichMarkdownUIView()
        view.frame = CGRect(x: 0, y: 0, width: 375, height: 800)
        return view
    }

    private func waitForRender(_ view: RichMarkdownUIView, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while view.model.hasOutstandingWork || view.hasPendingRebuild {
            try #require(Date() < deadline, "렌더가 제한 시간 안에 idle이 되어야 한다")
            try await Task.sleep(nanoseconds: 10_000_000)
            view.layoutIfNeeded()
        }
        view.layoutIfNeeded()
    }

    /// 유니코드 스칼라 단위 조각. grapheme(결합 문자·ZWJ 이모지)도 가를 수 있다 — README §7.
    nonisolated static func scalarChunks(_ text: String, size: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: size).map { start in
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
            return String(view)
        }
    }

    /// 앞 값을 prefix로 갖지 않는 첫 게시. 없으면 nil.
    nonisolated static func firstRegression(in sequence: [String]) -> (older: String, newer: String)? {
        for (previous, next) in zip(sequence, sequence.dropFirst()) where !next.hasPrefix(previous) {
            return (previous, next)
        }
        return nil
    }

    /// 블록 뷰 종류, 텍스트, 접근성 label, 글자색 alpha 구간, attachment 수를 문서 순서로 적는다.
    /// attachment·폰트 객체는 인스턴스 비교라 넣지 않는다.
    static func describe(_ stack: UIStackView) -> [String] {
        stack.arrangedSubviews.flatMap { block -> [String] in
            ["block \(type(of: block))"] + textViews(in: block).map(describe)
        }
    }

    private static func describe(_ textView: UITextView) -> String {
        let attributed = textView.attributedText ?? NSAttributedString()
        var alphaRuns: [String] = []
        var attachments = 0
        let whole = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            let alpha = (value as? UIColor)?.cgColor.alpha ?? -1
            alphaRuns.append("\(range.location)+\(range.length)@\(String(format: "%.2f", alpha))")
        }
        attributed.enumerateAttribute(.attachment, in: whole) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        return [
            "text \(attributed.string.debugDescription)",
            "label \(textView.accessibilityLabel.debugDescription)",
            "alpha \(alphaRuns.joined(separator: ","))",
            "attachments \(attachments)",
        ].joined(separator: " | ")
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        if view.isHidden { return [] }
        let own = (view as? UITextView).map { [$0] } ?? []
        return own + view.subviews.flatMap(textViews)
    }
}
