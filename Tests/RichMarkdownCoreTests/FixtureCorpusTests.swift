import Foundation
import Testing
@testable import RichMarkdownCore

/// Tests/Fixtures 코퍼스 러너 (README.md §4). fixture마다 시간 상한·정규화 출력·
/// `expected.json` 비교·`meta.expect` 검사를 수행한다.
@Suite struct FixtureCorpusTests {

    @Test func manifestAndCorpusAreLoaded() {
        #expect(!FixtureSupport.manifestPaths.isEmpty, "manifest.json을 읽지 못함: \(FixtureSupport.rootURL.path)")
        #expect(FixtureSupport.corpusIDs.count >= 100)
        #expect(FixtureSupport.pathologicalIDs.count >= 10)
    }

    @Test(arguments: FixtureSupport.corpusIDs)
    func fixture(id: String) throws {
        let input = try FixtureSupport.markdown(id: id)
        let meta = try FixtureSupport.meta(id: id)
        try Self.check(id: id, input: input, meta: meta)
    }

    @Test(arguments: FixtureSupport.pathologicalIDs)
    func pathological(id: String) throws {
        let rule = try FixtureSupport.rule(id: id)
        let input = try rule.generate()
        var meta = rule.meta
        // README §5: 생성 결과가 256 KiB를 넘으면 별도 expect 없이도 truncated를 기대한다.
        if input.utf8.count > InputLimits.maxInputUTF8Bytes {
            var expect = meta.expect ?? FixtureExpect()
            expect.truncated = true
            meta.expect = expect
        }
        try Self.check(id: id, input: input, meta: meta)
    }

    /// CommonMark 0.31.2 예제 652개: 기대값 없음, 무크래시·시간만 (README §4).
    @Test func commonMarkSpecExamples() throws {
        let examples = try FixtureSupport.commonMarkExamples()
        #expect(examples.count == 652)
        for example in examples {
            var document = ParsedDocument(blocks: [])
            let elapsed = ContinuousClock().measure {
                document = RichMarkdownParser.parse(markdown: example.markdown, dollarMath: [])
            }
            #expect(elapsed < .seconds(1), "commonmark/\(example.example): \(elapsed)")
            try FixtureSupport.writeOutput(
                FixtureNormalizer.data(document),
                relativePath: "commonmark/\(example.example).json"
            )
        }
    }

    // MARK: - 공통 검사

    static func check(id: String, input: String, meta: FixtureMeta) throws {
        let options = try meta.options()
        FixtureSupport.warmUp()
        var document = ParsedDocument(blocks: [])
        let elapsed = ContinuousClock().measure {
            document = RichMarkdownParser.parse(markdown: input, dollarMath: options)
        }
        #expect(elapsed < meta.budget, "\(id): \(elapsed) ≥ budget \(meta.budget)")

        let normalized = try FixtureNormalizer.data(document)
        try FixtureSupport.writeOutput(normalized, relativePath: id + ".json")

        if let expected = try FixtureSupport.expected(id: id) {
            let ignored = try FixtureSupport.ignoredFields(id: id)
            let actual = FixtureSupport.masking(try JSONSerialization.jsonObject(with: normalized), fields: ignored)
            let difference = FixtureNormalizer.firstDifference(expected: FixtureSupport.masking(expected, fields: ignored), actual: actual)
            #expect(difference == nil, "\(id): expected.json 불일치 — \(difference ?? "")")
        }
        if let expect = meta.expect {
            checkExpectations(expect, id: id, document: document)
        }
    }

    /// `meta.expect`의 각 키는 있을 때만 검사한다 (README §2).
    private static func checkExpectations(_ expect: FixtureExpect, id: String, document: ParsedDocument) {
        if let truncated = expect.truncated {
            #expect(document.wasTruncated == truncated, "\(id): truncated")
        }
        if let latex = expect.mathLatex {
            #expect(document.allMathSegments.map(\.latex) == latex, "\(id): mathLatex")
        }
        if let kinds = expect.mathKinds {
            #expect(document.allMathSegments.map { FixtureNormalizer.name($0.kind) } == kinds, "\(id): mathKinds")
        }
        if let types = expect.blockTypes {
            #expect(document.blocks.map(FixtureNormalizer.typeName) == types, "\(id): blockTypes")
        }
        if let diagnostics = expect.diagnostics {
            #expect(FixtureNormalizer.diagnosticKinds(document).map(FixtureNormalizer.name) == diagnostics, "\(id): diagnostics")
        }
        if let linkCount = expect.linkCount {
            #expect(FixtureNormalizer.linkCount(document) == linkCount, "\(id): linkCount")
        }
        if let needles = expect.plainTextContains {
            let text = FixtureNormalizer.plainText(document.blocks)
            for needle in needles {
                #expect(text.contains(needle), "\(id): plainText에 \(needle) 없음")
            }
        }
    }
}
