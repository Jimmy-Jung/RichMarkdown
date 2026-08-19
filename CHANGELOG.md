# Changelog

이 프로젝트는 [Semantic Versioning](https://semver.org/lang/ko/)을 따른다.
`0.x`는 베타이며 minor 버전에서 공개 API가 바뀔 수 있다.

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

[0.1.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.1.0
