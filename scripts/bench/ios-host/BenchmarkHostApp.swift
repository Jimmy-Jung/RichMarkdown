// Author: JunyoungJung
// Date: 2026-10-14

import SwiftUI

/// 실기기 마이크로 벤치마크용 빈 호스트 앱. SwiftPM 테스트 타깃은 기기에서 도구 호스팅으로 돌 수 없어
/// ("Tool-hosted testing is unavailable on device destinations", 실측) 이 앱이 테스트 번들을 띄운다.
/// 라이브러리는 링크하지 않는다 — 테스트 번들이 RichMarkdown을 직접 링크해 사본이 하나만 생긴다.
@main
struct BenchmarkHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "RichMarkdown Benchmarks")
        }
    }
}
