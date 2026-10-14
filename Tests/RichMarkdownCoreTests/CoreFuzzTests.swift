import Foundation
import Testing
@testable import RichMarkdownCore

/// 시드 기반 변이 퍼즈 (Tests/Fixtures/README.md §6). 같은 시드에서 Android와 같은 입력열을 낸다.
/// 규모는 `RICHMARKDOWN_FUZZ_ITERATIONS`(기본 10000)·`RICHMARKDOWN_FUZZ_SEED`(기본 0x5EED).
@Suite struct CoreFuzzTests {

    /// README §6 알파벳 — 순서 고정 29개. `é`는 e + U+0301 두 스칼라다.
    static let alphabet: [[Unicode.Scalar]] = [
        "a", "한", "🙂", "👨\u{200D}👩\u{200D}👧", "e\u{301}", "ע", "\\", "(", ")", "[", "]", "$", " ", "\n", "\r\n",
        "*", "_", "`", "~", "#", ">", "-", "|", "<", "!", "\u{200B}", "\u{FEFF}", "1", ".",
    ].map { Array($0.unicodeScalars) }

    /// op 3 구분자 토글 순서.
    static let delimiters: [[Unicode.Scalar]] = ["\\(", "\\)", "\\[", "\\]", "$$", "$"].map { Array($0.unicodeScalars) }

    /// 계약이 옵션을 정하지 않으므로 스캐너 경로를 가장 넓게 여는 전체 opt-in으로 돌린다.
    static let options: DollarMathOptions = [.single, .inlineDouble]
    static let parseBudget: Duration = .milliseconds(500)

    @Test func seededMutationFuzz() throws {
        let seed = try Self.seed()
        let iterations = try Self.iterations()
        let corpus = try FixtureSupport.fuzzCorpusIDs.map { Array(try FixtureSupport.markdown(id: $0).unicodeScalars) }
        try #require(!corpus.isEmpty, "퍼즈 코퍼스가 비어 있음: \(FixtureSupport.rootURL.path)")
        let dump = try FuzzDump(seed: seed)
        FixtureSupport.warmUp()
        var rng = SplitMix64(seed: seed)

        for n in 0..<iterations {
            var scalars = corpus[rng.pick(corpus.count)]
            let mutationCount = 1 + rng.pick(8)
            for _ in 0..<mutationCount { Self.mutate(&scalars, rng: &rng) }

            let outcome = Self.verify(scalars)
            if let failure = outcome.failure {
                let minimized = Self.minimize(scalars)
                let saved = try FixtureSupport.writeRegression(Self.string(minimized), seed: seed, iteration: n)
                Issue.record("퍼즈 실패 seed=\(seed) n=\(n): \(failure) — 최소화 입력(\(minimized.count) 스칼라) 저장: \(saved.path)")
                return
            }
            for _ in 0..<5 {
                let prefix = Array(scalars.prefix(rng.pick(scalars.count + 1)))
                _ = RichMarkdownParser.parse(markdown: Self.string(prefix), dollarMath: Self.options)
            }
            try dump?.write(iteration: n, input: Self.string(scalars), document: outcome.document)
        }
    }

    // MARK: - 설정

    static func seed() throws -> UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["RICHMARKDOWN_FUZZ_SEED"]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return 0x5EED }
        let parsed = raw.lowercased().hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
        guard let parsed else { throw FuzzConfigError.invalid("RICHMARKDOWN_FUZZ_SEED", raw) }
        return parsed
    }

    static func iterations() throws -> Int {
        guard let raw = ProcessInfo.processInfo.environment["RICHMARKDOWN_FUZZ_ITERATIONS"]?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return 10_000 }
        guard let parsed = Int(raw), parsed >= 0 else { throw FuzzConfigError.invalid("RICHMARKDOWN_FUZZ_ITERATIONS", raw) }
        return parsed
    }

    enum FuzzConfigError: Error, CustomStringConvertible {
        case invalid(String, String)
        var description: String {
            switch self { case .invalid(let name, let raw): "\(name) 값을 해석할 수 없음: \(raw)" }
        }
    }

    // MARK: - 변이 (README §6, 위치·길이는 유니코드 스칼라 단위)

    static func mutate(_ scalars: inout [Unicode.Scalar], rng: inout SplitMix64) {
        let length = scalars.count
        switch rng.pick(6) {
        case 0:
            let position = rng.pick(length + 1)
            scalars.insert(contentsOf: alphabet[rng.pick(alphabet.count)], at: position)
        case 1:
            guard length >= 1 else { return }
            scalars.remove(at: rng.pick(length))
        case 2:
            // ponytail: 계약은 빈 입력의 pick(len)을 정의하지 않으므로 삭제와 같이 건너뛴다.
            guard length >= 1 else { return }
            let start = rng.pick(length)
            let end = start + rng.pick(min(64, length - start) + 1)
            let piece = Array(scalars[start..<end])
            scalars.insert(contentsOf: piece, at: end)
        case 3:
            let delimiter = delimiters[rng.pick(delimiters.count)]
            if let range = firstRange(of: delimiter, in: scalars) { scalars.removeSubrange(range) }
        case 4:
            if let newline = scalars.firstIndex(of: "\n") {
                scalars.insert("\r", at: newline)
            } else {
                scalars.append("\n")
            }
        case 5:
            scalars = Array(scalars.prefix(rng.pick(length + 1)))
        default:
            break
        }
    }

    private static func firstRange(of pattern: [Unicode.Scalar], in scalars: [Unicode.Scalar]) -> Range<Int>? {
        guard scalars.count >= pattern.count else { return nil }
        for start in 0...(scalars.count - pattern.count)
        where scalars[start..<(start + pattern.count)].elementsEqual(pattern) {
            return start..<(start + pattern.count)
        }
        return nil
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    // MARK: - 검사 ①~④

    struct Outcome {
        var document: ParsedDocument
        var failure: String?
    }

    /// ① parse 무예외 ② elapsed < 500 ms ③ restore(protect(bytes)) == bytes ④ 제한값 준수.
    static func verify(_ scalars: [Unicode.Scalar]) -> Outcome {
        let text = string(scalars)
        var document = ParsedDocument(blocks: [])
        let elapsed = ContinuousClock().measure {
            document = RichMarkdownParser.parse(markdown: text, dollarMath: options)
        }
        if elapsed >= parseBudget {
            // 공유 CI 러너의 일시 정지가 한 번의 측정을 부풀릴 수 있다(2026-10-14 GitHub Actions 2.15 s, 같은 입력 로컬 릴리스 2 ms).
            // 같은 입력을 세 번 다시 재서 가장 빠른 값으로 판정한다. 입력 자체가 느리면 세 번 모두 상한을 넘는다.
            let retries = (0..<3).map { _ in
                ContinuousClock().measure { _ = RichMarkdownParser.parse(markdown: text, dollarMath: options) }
            }
            if let fastest = retries.min(), fastest >= parseBudget {
                return Outcome(document: document, failure: "parse \(fastest) ≥ \(parseBudget) (재측정 3회 최소값, 첫 측정 \(elapsed))")
            }
        }

        let bytes = Array(text.utf8)
        let spans = MathScanner(
            bytes: bytes,
            forbiddenRanges: [],
            paragraphRanges: [0..<bytes.count],
            dollarMath: options
        ).scan().spans
        let masked = MathProtector.protect(bytes: bytes, spans: spans)
        if MathProtector.restore(masked: masked, original: bytes, spans: spans) != bytes {
            return Outcome(document: document, failure: "restore(protect(bytes)) != bytes")
        }
        return Outcome(document: document, failure: limitViolation(in: document))
    }

    private static func limitViolation(in document: ParsedDocument) -> String? {
        let depth = FixtureNormalizer.maxQuoteDepth(document.blocks)
        if depth > InputLimits.maxBlockQuoteDepth { return "block quote 깊이 \(depth)" }
        for table in FixtureNormalizer.allTables(document.blocks) {
            let columns = table.rows.reduce(table.header.count) { max($0, $1.count) }
            let cells = table.rows.reduce(table.header.count) { $0 + $1.count }
            if columns > InputLimits.maxTableColumns { return "표 열 \(columns)" }
            if cells > InputLimits.maxTableCells { return "표 셀 \(cells)" }
        }
        // README §6 ④: latex(구분자 제외)가 4096 B를 넘는 span은 보호·유지되지만 diagnostics에
        // oversizedMathSource가 있어야 한다.
        let oversized = document.allMathSegments.contains { $0.latex.utf8.count > InputLimits.maxMathSourceUTF8Bytes }
        if oversized, !document.diagnostics.contains(where: { $0.kind == .oversizedMathSource }) {
            return "latex 4096 B 초과 수식 span이 있는데 diagnostics에 oversizedMathSource 없음"
        }
        return nil
    }

    // MARK: - 최소화

    /// 스칼라를 하나씩 지우며 실패가 유지되는 가장 짧은 입력을 찾는다 (탐욕 1회 통과).
    static func minimize(_ input: [Unicode.Scalar]) -> [Unicode.Scalar] {
        // ponytail: 시간 초과 실패는 한 번 검사에 0.5 s 이상 걸리므로 총 60 s에서 끊고 현재 결과를 쓴다.
        let deadline = ContinuousClock.now + .seconds(60)
        var current = input
        var index = 0
        while index < current.count, ContinuousClock.now < deadline {
            var candidate = current
            candidate.remove(at: index)
            if verify(candidate).failure != nil {
                current = candidate
            } else {
                index += 1
            }
        }
        return current
    }
}

/// `RICHMARKDOWN_FUZZ_DUMP=1`이면 `<out>/ios/fuzz-<seed>.jsonl`에 입력과 정규화 결과를 한 줄씩 기록한다.
struct FuzzDump {
    private let handle: FileHandle

    init?(seed: UInt64) throws {
        guard ProcessInfo.processInfo.environment["RICHMARKDOWN_FUZZ_DUMP"] == "1",
              let directory = FixtureSupport.outputDirectory
        else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("fuzz-\(seed).jsonl")
        try Data().write(to: fileURL)
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func write(iteration: Int, input: String, document: ParsedDocument) throws {
        let line: [String: Any] = ["n": iteration, "input": input, "doc": FixtureNormalizer.json(document)]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]))
        try handle.write(contentsOf: Data("\n".utf8))
    }
}
