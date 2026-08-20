import UIKit
import SwiftLatexCore

/// parse 결과 캐시. 파서는 순수 함수라 (markdown, parsesDollarMath)가 결과를 결정한다.
///
/// 셀 재사용과 SwiftUI `.task(id:)` 재실행은 같은 원문을 반복 제출한다. raster 캐시
/// (`MathRenderService`)만으로는 매번 재파싱 + 2단계 게시(원문 fallback → hydration)가
/// 남아 스크롤 중 뷰 재구성이 2회씩 일어난다. parse까지 캐시하면
/// `LatexRenderModel.submit`이 worker 왕복 없이 완성 상태를 1회에 게시할 수 있다.
///
/// `NSCache`는 문서상 thread-safe라 actor 없이 MainActor와 worker 양쪽에서 접근한다.
final class ParseCache: @unchecked Sendable {
    static let shared = ParseCache()

    /// cache key는 worker에서 미리 만든 뒤 MainActor의 generation-guarded store에 전달한다.
    /// `NSString`는 immutable이므로 그 경계에서만 Sendable 검사를 면제한다.
    struct Key: @unchecked Sendable {
        fileprivate let value: NSString
        fileprivate let sourceByteCount: Int
    }

    /// worker에서 계산한 비용과 document를 MainActor의 generation-guarded store로 넘긴다.
    /// 비용 산정은 AST 순회가 필요하므로 MainActor에서 수행하지 않는다.
    struct PreparedEntry: Sendable {
        fileprivate let key: Key
        fileprivate let document: ParsedDocument
        fileprivate let cost: Int
    }

    private final class Entry {
        let document: ParsedDocument
        init(document: ParsedDocument) { self.document = document }
    }

    private let cache = NSCache<NSString, Entry>()

    /// notification 클로저가 안전하게 캡처하도록 검사 면제 박스로 감싼다.
    /// 참조는 weak다 — `MathRenderService`와 같은 수명 규칙.
    private struct CacheRef: @unchecked Sendable {
        weak var cache: NSCache<NSString, Entry>?
    }

    init() {
        // ponytail: 상한은 잠정값. cost는 원문 3배 + 문서 node 추정치다.
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024
        let cacheRef = CacheRef(cache: cache)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            cacheRef.cache?.removeAllObjects()
        }
    }

    /// 원문을 가진 호출은 worker에서 이 메서드로 key를 만들고 이후 `document(for:)`,
    /// `preparedEntry(_:for:)`, `store(_:)`만 사용한다. 따라서 raw oversized markdown은
    /// MainActor cache path에 없다.
    func key(markdown: String, parsesDollarMath: Bool, wasTruncated: Bool) -> Key {
        let prefix = "\(parsesDollarMath ? "$" : "-")\(wasTruncated ? "T" : "-")\u{1F}"
        return Key(value: (prefix + markdown) as NSString, sourceByteCount: markdown.utf8.count)
    }

    func document(for key: Key) -> ParsedDocument? {
        cache.object(forKey: key.value)?.document
    }

    func preparedEntry(_ document: ParsedDocument, for key: Key) -> PreparedEntry {
        PreparedEntry(
            key: key,
            document: document,
            cost: Self.estimatedCost(for: document, sourceByteCount: key.sourceByteCount)
        )
    }

    func store(_ entry: PreparedEntry) {
        cache.setObject(
            Entry(document: entry.document),
            forKey: entry.key.value,
            cost: entry.cost
        )
    }

    /// 원문 복사·AST·배열/수식 node가 함께 cache에 남는 점을 반영한 보수적 비용이다.
    /// `NSCache`의 cost는 엄격한 메모리 측정값이 아니므로, 작은 cache를 일찍 축출하는
    /// 쪽을 선택한다.
    static func estimatedCost(for document: ParsedDocument, sourceByteCount: Int) -> Int {
        let sourceCost = saturatedProduct(max(sourceByteCount, 1), 3)
        let blockCost = saturatedProduct(document.blocks.count, 512)
        let mathCost = saturatedProduct(document.allMathSegments.count, 1_024)
        return saturatedSum(sourceCost, blockCost, mathCost)
    }

    private static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : product
    }

    private static func saturatedSum(_ values: Int...) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    // `@testable` 테스트용 편의 경로. production model은 `key`를 worker에서 만든다.
    func document(
        markdown: String,
        parsesDollarMath: Bool,
        wasTruncated: Bool = false
    ) -> ParsedDocument? {
        document(for: key(
            markdown: markdown,
            parsesDollarMath: parsesDollarMath,
            wasTruncated: wasTruncated
        ))
    }
}
