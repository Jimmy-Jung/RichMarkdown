import os

/// MainActor에서 CPU parse/raster가 실행되지 않는지 Instruments로 검증하기 위한
/// signpost (DEVELOPMENT.md §8 비동기/cache 테스트).
/// os_signpost 구간을 Time Profiler의 Main Thread와 겹쳐 보면 stall 여부가 드러난다.
package enum SwiftLatexSignposts {
    package static let parse = OSSignposter(subsystem: "dev.swiftlatex", category: "parse")
    package static let raster = OSSignposter(subsystem: "dev.swiftlatex", category: "raster")
    /// UIKit 렌더러의 블록 계층 재구성 구간. Hitches 템플릿의 hitch 구간과 겹쳐 보면
    /// 스크롤 버벅임이 뷰 재생성/Auto Layout에서 오는지 raster에서 오는지 갈린다
    /// (Docs/RENDERING_PERFORMANCE_PLAN.md §8.1).
    package static let rebuild = OSSignposter(subsystem: "dev.swiftlatex", category: "rebuild")
}
