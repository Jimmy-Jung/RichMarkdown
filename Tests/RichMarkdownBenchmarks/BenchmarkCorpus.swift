// Author: JunyoungJung
// Date: 2026-10-14

import Foundation

/// P2 성능 하네스 공통 입력 (`p2/design.md` «공통 입력», Android `:benchmark-micro`와 같은 규칙).
///
/// - 파싱 입력: `samples/*.md`를 id(파일명) 사전순으로 `\n\n---\n\n`로 잇는다. 원본 합계가 약 15 KiB라
///   목표 크기에 닿을 때까지 같은 순서로 **처음부터 다시** 잇고(구분자 포함), UTF-8 목표 바이트 이하의
///   마지막 스칼라 경계에서 자른다. 생성 파일은 커밋하지 않는다.
/// - 스트리밍 입력: `samples/long-essay-mixed.md`를 64 스칼라 조각으로 나눈다.
enum BenchmarkCorpus {
    enum LoadError: Error {
        case missingSamples
    }

    static let separator = "\n\n---\n\n"
    static let sizesKiB = [1, 10, 50, 256]
    static let streamingDocumentID = "long-essay-mixed"
    static let streamingChunkScalars = 64

    /// 데모 챗 fixture «복합 수식 · array · underbrace»의 보상 함수 (`Examples/RichMarkdownDemo/Sources/ChatDemo.swift`).
    static let complexLatex = #"""
    r_t=\left\{\begin{array}{ccc}
    \underbrace{\begin{array}{c}
    1+\frac{\bar{R}_Q(t+\Delta t)-R_Q(t)}{2\Delta t/T_{\mathrm{single}}}\\
    0\\
    0
    \end{array}}_{r_t^{(1)}}&
    \underbrace{\begin{array}{c}
    \vphantom{\frac{\bar{R}_Q}{T_{\mathrm{single}}}}+0\\
    -P\\
    +0
    \end{array}}_{r_t^{(2)}}&
    \begin{array}{l}
    \vphantom{\frac{\bar{R}_Q}{T_{\mathrm{single}}}}\mathrm{if}\ \bar{R}_Q(t+\Delta t)>0\\
    \mathrm{if}\ \bar{R}_Q(t)\ne0\ \mathrm{and}\ R_Q(t+\Delta t)=0\\
    \mathrm{if}\ R_Q(t)=0
    \end{array}
    \end{array}\right.
    """#

    static let simpleLatex = "x^2"

    /// 실기기에는 호스트 경로가 없어 `#filePath` 대신 번들 리소스를 읽는다. SwiftPM 빌드는 `Samples`
    /// (심볼릭 링크 복사본) 폴더, 실기기 호스트 프로젝트(scripts/bench/ios-host)는 번들 루트의 `.md`다.
    static func samples() throws -> [(id: String, text: String)] {
        let urls = try resourceBundle.url(forResource: "Samples", withExtension: nil).map {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? resourceBundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        let files = urls
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw LoadError.missingSamples }
        return try files.map { ($0.deletingPathExtension().lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    #if SWIFT_PACKAGE
    private static var resourceBundle: Bundle { .module }
    #else
    private final class BundleToken {}
    private static var resourceBundle: Bundle { Bundle(for: BundleToken.self) }
    #endif

    static func document(_ id: String) throws -> String {
        guard let match = try samples().first(where: { $0.id == id }) else { throw LoadError.missingSamples }
        return match.text
    }

    /// `kib` KiB 파싱 입력.
    static func corpus(kib: Int) throws -> String {
        try corpus(utf8Bytes: kib * 1024, from: samples().map(\.text))
    }

    static func corpus(utf8Bytes limit: Int, from documents: [String]) -> String {
        var text = ""
        var index = 0
        while text.utf8.count < limit {
            if index > 0 { text += separator }
            text += documents[index % documents.count]
            index += 1
        }
        return prefix(text, utf8Bytes: limit)
    }

    /// UTF-8 `limit` 바이트를 넘지 않는 가장 긴 스칼라 경계 prefix.
    static func prefix(_ text: String, utf8Bytes limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            guard used + width <= limit else { break }
            scalars.append(scalar)
            used += width
        }
        return String(scalars)
    }

    /// `size` 스칼라씩 자른 조각. 마지막 조각은 짧을 수 있다.
    static func scalarChunks(of text: String, size: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: size).map { start in
            var chunk = String.UnicodeScalarView()
            chunk.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
            return String(chunk)
        }
    }
}
