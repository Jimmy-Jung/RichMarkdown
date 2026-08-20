# Changelog

이 프로젝트는 [Semantic Versioning](https://semver.org/lang/ko/)을 따른다.
`0.x`는 베타이며 minor 버전에서 공개 API가 바뀔 수 있다.

## [Unreleased]

### 추가

- `LatexMarkdownUIView` — UIKit 네이티브 렌더러. SwiftUI 호스팅 래퍼가 아니라
  `UIView` 하위 클래스로 블록을 `UIStackView`에, 인라인 수식을 text attachment로
  배치한다. 파서·`MathRenderService`·generation 관리는 `LatexMarkdownView`와 공유한다.
  `markdown`, `parsesDollarMath`, `theme`, `onContentSizeChange`를 공개한다.
- 요소 단위 폰트 커스터마이즈. `LatexTheme`에 `bodyFont`, `heading1~4Font`,
  `codeFont`, `codeLabelFont`, `mathFont` 추가. 지정값 타입은 `LatexFont`
  (서체 `standard`/`monospaced`/`custom(name:)`, Dynamic Type 기준 `LatexTextStyle`,
  크기, `LatexFontWeight`)다. `Font`/`UIFont`를 담지 않는 `Sendable` 값이라 두 렌더러가
  같은 값에서 각자 폰트를 만들고 렌더 요청 key에도 들어간다.
- `LatexMathFont` — 수식 서체 12종. 이전에는 Latin Modern 고정이었다.
  `MathRenderKey`에 실려 서체별로 raster를 따로 캐시한다.

- 데모 앱에 **UIKit 네이티브** 화면 추가
  (`Examples/SwiftLatexDemo/Sources/UIKitChatDemo.swift`).
  `LatexMarkdownUIView`를 `UICollectionView` 재사용 셀에 직접 넣고, 테마 프리셋
  4종(기본 / 큰 글자 / Serif / 색 강조)으로 폰트·색·수식 서체 커스터마이즈를 확인한다.
  프리셋별 스크린샷을 남기는 UI 테스트 `testUIKitNativeCellsRender`를 함께 추가했다.

### 수정

- **SwiftUI 렌더러에서 `theme.textColor`가 본문 글자에 적용되지 않던 문제.**
  적용 지점이 수식 raster와 코드 헤더 라벨 2곳뿐이었다. 문단·헤딩·리스트 마커·
  코드 블록 본문·수식 fallback·원문 fallback 전부에 적용한다. 기본값
  `textColor: .primary`가 SwiftUI 환경 전경색과 같아서 결함이 드러나지 않았다.
- **인라인 수식의 baseline 보정이 UIKit 렌더러에서 사라지던 문제.**
  `NSTextAttachment.bounds`에 넣은 값은 `UITextView`에 실린 뒤 `.zero`로 읽힌다.
  `MathTextAttachment`가 `attachmentBounds(for:...)`를 override해 `-descent`를 답한다.
- UIKit 렌더러가 폰트를 앰비언트 trait으로 해석하던 문제. 색·displayScale은 뷰의
  `traitCollection`을 쓰는데 폰트만 앱 전역 설정을 읽어서, 뷰에 건 `traitOverrides`가
  글자 크기에 닿지 않았다. 전부 `compatibleWith: traitCollection`으로 해석한다.
- 복사 버튼 아이콘 색이 두 렌더러에서 갈리던 문제. UIKit은 `UIButton(type: .system)`
  기본 tint(시스템 파랑), SwiftUI는 환경 전경색이었다. 양쪽 모두 `theme.textColor`.
- 수식 서체 cache key 필드가 죽어 있던 문제. `MathRenderKey.fontIdentifier`는 항상
  `"latinModern"`이고 `MathImage.font`에 전달되지 않았다. `mathFont`로 바꿔 실제 반영한다.
- **CPU parse가 MainActor에서 실행되던 문제.** `LatexRenderModel`은 `@MainActor`이고
  global actor 표시는 static 멤버에도 적용되므로, `nonisolated` 없는 static 처리 함수가
  전체를 main thread에서 돌렸다. `swift-markdown` parse가 50 KiB에서 p50 약 119ms 동안
  main을 점유했다. `nonisolated`를 붙여 worker executor로 되돌린다.
  10Hz·5초 스트리밍 fixture의 벽시계가 8.76초 → 5.28초로 줄었다.
- `NSCache`를 `@Sendable` 클로저에서 직접 캡처해 Swift 6 경고가 나던 문제.
  weak 참조를 담은 `Sendable` 박스로 감싼다(수명 규칙은 기존 `[weak cache]`와 동일).
- `MathRenderKey`의 `fontIdentifier: String`이 `mathFont: LatexMathFont`로 바뀐다
  (`package` 심볼이라 공개 API 영향 없음).

## [0.1.1] - 2026-08-19

### 수정

- 수식으로 인식되지 않은 구분자가 backslash를 잃던 문제. `0.1.0`의 Markdown escape
  해제가 `\(`, `\)`, `\[`, `\]`까지 벗겨서 미완성 수식이 `(x + y`로 보였다.
  "잘못되거나 미완성인 LaTeX는 원래 구분자를 포함한 source를 표시한다"는 계약이
  깨졌다. 수식 구분자 문자는 해제 대상에서 제외한다. `\$`, `\*`, `\_`, `\\`는
  그대로 해제한다.

### 문서

- README에 실제 렌더 스크린샷 4장(수식, Markdown 요소, 달러 opt-in·fail-open,
  코드 블록 dark) 추가

## [0.1.0] - 2026-08-19

첫 베타 릴리스.

### 추가

- `LatexMarkdownView(markdown:parsesDollarMath:)` — Markdown + 인라인/블록 LaTeX +
  코드 블록을 렌더하는 SwiftUI 뷰
- `LatexTheme`과 `.latexTheme(_:)` — 텍스트·링크·코드 배경 색 지정
- `Color.accessibleLink` — 대비 기준(4.5:1)을 넘는 기본 링크 색
- 수식 보호 2-pass 파서: 원문 전체에서 수식을 찾고, UTF-8 byte 길이를 보존하는
  mask로 2차 Markdown 파싱을 수행한다. `restore(protect(s)) == s`를 byte 단위로 보장
- 금지 문맥 규칙: 코드·HTML은 hard barrier, 링크·이미지는 soft range
  (`[\(x\)](url)`은 보호, `\([a](b)\)`는 수식)
- 달러 수식 opt-in(`$...$`, `$$...$$`)과 통화 표기 판별 규칙
- 스트리밍 계약: 최신 전체 `String` 입력, coalescing(실행 1 + 대기 1), latest-wins 게시
- 2단계 게시: 파싱 결과 먼저, 수식 이미지 hydration 이후
- 수식 raster cache: source·font·point size·RGBA·mode·display scale 기준,
  pixel byte cost, memory warning 정리
- 입력 보호: 원문 256 KiB / 표시 64 KiB / 수식 source 4 KiB 상한
- fail-open: 잘못된 LaTeX·미지원 노드·HTML은 원문이나 plain text로 표시
- 링크 allowlist(`https`, `http`, `mailto`)와 `OpenURLAction` 위임
- 접근성: 수식 `"수식: <LaTeX>"` 표현, 44×44pt 복사 버튼, Dynamic Type 재렌더
- `Examples/SwiftLatexDemo` — 챗봇 형태 데모와 `UIHostingConfiguration` 예제
- `scripts/ci-test.sh`, `scripts/check-core-coverage.sh` — CI 파이프라인과 커버리지 gate

### 알려진 제약

- 한글은 시스템 폰트에 italic 변형이 없어 `*기울임*`이 시각적으로 적용되지 않는다
- iOS 16은 배포 대상으로 선언했지만 실행 검증된 최소 runtime은 iOS 18.6 simulator다
- 표, 원격 이미지, 신택스 하이라이팅, macOS UI는 이 버전의 비목표다

[0.1.1]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.1.1
[0.1.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.1.0
