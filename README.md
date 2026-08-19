# SwiftLatex

SwiftUI 기반 메시지 렌더러. Markdown, 인라인/블록 LaTeX, 코드 블록을 네이티브 UI로
표시하는 Swift Package다. UIKit 앱은 Apple의 SwiftUI 호스팅 API로 사용한다.

설계 문서: [DEVELOPMENT.md](DEVELOPMENT.md)

## 사용

```swift
import SwiftLatex

LatexMarkdownView(
    markdown: message,
    parsesDollarMath: false   // 기본값 false. $...$ / $$...$$는 opt-in.
)
.latexTheme(.default)
```

`LatexTheme`은 텍스트·링크·코드 배경 색을 노출한다. 기본 `linkColor`는
시스템 블루가 아니라 대비 기준(4.5:1)을 넘는 `Color.accessibleLink`다
(시스템 블루는 흰 배경에서 약 3.6:1로 접근성 audit에 걸린다).

### 데모 앱

`Examples/SwiftLatexDemo`에서 `xcodegen generate` 후 실행한다. LLM 챗봇 화면을
스크롤하며 렌더 케이스를 한 번에 확인할 수 있다 — 인라인/블록 수식, 코드 블록,
리스트·인용, 링크 allowlist, 금지 문맥 보호, 실패 시 원문 표시, 다국어·RTL,
미지원 노드 강등, 긴 답변. 우측 상단 메뉴에서 `$` 수식 opt-in을 토글해 비교한다.

UIKit 셀:

```swift
cell.contentConfiguration = UIHostingConfiguration {
    LatexMarkdownView(markdown: message)
}
```

일반 화면은 `UIHostingController`를 사용한다. 예제는
`Examples/SwiftLatexDemo`에 있다 (`xcodegen generate`로 프로젝트 생성).

## 수식 문법

- 기본: `\( ... \)` 인라인, `\[ ... \]` block (공백 제외 paragraph 전체일 때만)
- opt-in (`parsesDollarMath: true`): `$...$`, `$$...$$`
- 잘못되거나 미완성인 LaTeX는 구분자를 포함한 원문을 그대로 표시한다.
- code/HTML 내부의 구분자는 수식이 아니다. 링크/이미지 문법 내부의 구분자도
  수식이 아니다. 단, `\([a](b)\)`처럼 수식이 link-like source를 완전히 감싸면 수식이다.

## 알려진 제약

- 한글은 시스템 폰트에 italic 변형이 없어 `*기울임*`이 시각적으로 적용되지 않는다
  (iOS 제약). 영문·숫자에는 적용된다.
- 표, 원격 이미지, 신택스 하이라이팅은 v1 비목표다. 미지원 노드는 삭제하지 않고
  읽을 수 있는 plain text로 낮춘다.

## 지원 matrix

| 항목 | 값 |
|---|---|
| 배포 대상 | iOS/iPadOS 16+ (선언). 실행 검증된 최소 runtime은 iOS 18.6 simulator |
| 검증 toolchain | Xcode 26.6 (17F113), Swift 6.3.3 |
| Swift tools | 6.0 (Swift Testing 사용을 위해 필요) |
| 의존성 | swift-markdown `exact: 0.4.0`, SwiftMath `exact: 1.7.3` |

주의: SwiftMath `1.7.2`는 `MTMathListBuilder`의 scope 버그로 Xcode 26.6에서
컴파일되지 않는다. `1.7.3`이 수정 버전이며 `MathImage.asImage()` API는 동일하다.

iOS 16 실행 검증은 호환 Xcode/runtime 또는 실기기 환경에서 별도 수행한다.

## 테스트와 CI

P0에서 실제 실행으로 고정한 이름/명령 (CI simulator: iPhone 16 Pro, iOS 18.6):

```bash
# Foundation-only Core를 host에서 우선 검증
swift build --target SwiftLatexCore

# 전체 unit test (package scheme 이름은 `SwiftLatex`)
xcodebuild test \
  -scheme SwiftLatex \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -enableCodeCoverage YES

# UIKit lifecycle/UI test
xcodebuild test \
  -project Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj \
  -scheme SwiftLatexDemo \
  -testPlan SwiftLatexDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'
```

전체 파이프라인 + Core line coverage 80% gate:

```bash
scripts/ci-test.sh
```

스트리밍 30초 전체 측정 (기본은 CI용 5초):

```bash
TEST_RUNNER_SWIFTLATEX_STREAM_SECONDS=30 xcodebuild test \
  -scheme SwiftLatex \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -only-testing:SwiftLatexTests/StreamingBaselineTests
```

측정 기록(2026-08-19, Debug/simulator): 50 KiB parse p95 191–230ms,
10Hz×30초 스트리밍 종료 후 idle 25–26ms. 세부는 DEVELOPMENT.md 참고.

Swift 6 language mode와 complete concurrency는 tools 6.0 manifest가 우리 target에
적용한다. 전역 `SWIFT_VERSION=6` override는 의존성까지 재컴파일하므로 쓰지 않는다.

macOS host의 일반 `swift test`는 UIKit target 검증 근거로 사용하지 않는다.

## Dependency licenses

- [swift-markdown](https://github.com/swiftlang/swift-markdown) — Apache License 2.0
- [swift-cmark](https://github.com/apple/swift-cmark) — 2-Clause BSD (cmark 파생)
- [SwiftMath](https://github.com/mgriebling/SwiftMath) — MIT License
