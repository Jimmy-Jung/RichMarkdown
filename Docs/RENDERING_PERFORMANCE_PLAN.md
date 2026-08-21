# UIKit 렌더링 성능 개선안 — 벡터 렌더링 검토 포함

- 작성자: JunyoungJung
- 작성일: 2026-08-21 (rev.3 — P2·P3 구현 완료. 실측 정정과 구현 기록을 §9에 추가)
- 상태: **P2·P3 구현 완료** (코드·테스트·`scripts/ci-test.sh` 통과).
  **P1의 실기기 Instruments 측정은 미완** — signpost 계측만 들어갔다. §9.1을 먼저 읽어라
- 참고 소스: `~/Documents/GitHub/SwiftMath` (upstream master), `~/Documents/GitHub/textual` (Textual + swiftui-math)
- 관련 문서: `DEVELOPMENT.md` §4(비동기 계약), §6(raster 캐시), §"엔진 선택 근거"

> **구현자 주의**: 이 문서의 §8이 구현 가이드다. §8의 "하지 말 것" 목록(§8.5)은
> 전부 코드 주석에 남아 있는 **실측 사실**이다. 위반하면 컴파일 에러가 아니라
> 런타임 회귀(스크롤 얼림, baseline 소실)로 나타나므로 반드시 먼저 읽어라.

---

## 1. 문제

UIKit 렌더러(`LatexMarkdownUIView`)를 채팅 리스트에서 사용할 때 스크롤 버벅임이 있다.
"SwiftMath가 이미지를 렌더링하고 Textual은 네이티브 벡터를 렌더링해서"라는 가설이
제기되었으나, 코드 분석 결과 **raster vs vector는 프레임당 비용 차이가 거의 없다**.
Core Animation은 어떤 뷰든 레이어 backing store(bitmap)로 합성하므로, 캐시된
`UIImage` blit은 스크롤 중 최저 비용 경로다. 벡터도 첫 draw 후에는 같은 bitmap 합성이다.

버벅임의 실제 원인 후보는 **이미지가 비동기로 도착하는 파이프라인이 유발하는
전체 뷰 재구성과 셀 리사이즈**다.

## 2. 진단 — 코드 근거 (측정 전 가설)

| # | 병목 후보 | 위치 | 내용 |
|---|---|---|---|
| 1 | 전체 계층 파괴/재생성 | `LatexMarkdownUIView.swift` `rebuild()` | 게시마다 arranged subview 전부 제거 후 재생성. 블록마다 새 `UITextView`(TextKit 스택 통째), 중첩 `UIStackView`, 수식·코드 블록마다 `UIScrollView` + 제약 다발. 전부 main thread |
| 2 | 2단계 게시 → rebuild 2회 | `LatexRenderModel.swift` `run(_:model:)` | raster 캐시 미스 시 (1) 원문 fallback 게시, (2) 이미지 hydration 게시. 각각 rebuild 유발 |
| 3 | hydration 시 셀 높이 변경 | `LatexMarkdownUIView.rebuild()` 끝의 `invalidateIntrinsicContentSize` | 수식 원문 → 이미지 교체로 높이가 바뀌고 collection view self-sizing 재측정 → contentOffset 보정 = 스크롤 중 hitch |
| 4 | 스크롤 중 raster 미스 | `MathRenderService.render(key:)` | raster 자체는 actor(off-main)라 무해하나, 결과 도착이 #2·#3을 다시 일으킨다 |

핵심: **raster 방식이 느린 게 아니라, "이미지를 기다렸다가 갈아끼우는" 비동기
파이프라인이 UIKit self-sizing과 상성이 나쁘다.**

## 3. 참고 구현 분석

### 3.1 SwiftMath (고정 버전 1.7.3과 upstream master 공통)

- `MTMathUILabel`: **네이티브 벡터 뷰가 이미 존재하고 public이다.**
  `draw(_:)`에서 `MTMathListDisplay.draw(context)`로 CoreText 직접 드로잉.
  이미지 중간 단계 없음. `intrinsicContentSize`가 내부에서 동기 typeset해
  정확한 크기를 반환하고, `displayList` getter(public)로 ascent/descent를 읽을 수 있다.
- `MathImage`(현재 우리가 쓰는 API)는 같은 typesetter 출력을
  `UIGraphicsImageRenderer`로 bitmap화하는 **얇은 래퍼**일 뿐이다.
- **접근 수준 함정 (실측)**: `MTTypesetter.createLineForMathList(...)`는 1.7.3과
  master **모두 internal**이다. 우리 패키지에서 display list를 직접 만들 수 없다.
  display list에 접근하는 유일한 public 경로는 `MTMathUILabel.displayList`다.
  `MTMathListBuilder.build(fromString:)`(parse)와 `MTFontManager`(폰트)는 public.
- upstream master에는 `maxWidth` 자동 줄바꿈(멀티라인 수식)이 추가되었다
  (`MULTILINE_IMPLEMENTATION_NOTES.md`). 1.7.3에는 없다.

### 3.2 Textual + swiftui-math

Textual의 수식 처리(`Sources/Textual/Internal/Attachment/MathAttachment.swift`):

1. **동기 측정**: 레이아웃 패스 안에서 `Math.typographicBounds(...)`를 동기 호출해
   정확한 크기(ascent/descent 포함)를 **첫 패스에 확보**한다.
   fallback → 교체 → 리사이즈 사이클 자체가 없다.
2. **벡터 드로잉**: SwiftUI `Canvas`에서 `DisplayNode`를 직접 그린다.
3. **2단 NSCache**(`DisplayProvider`): parse 결과와 typeset 결과(latex+font+style+width 키) 분리 캐시.
4. 동기 typeset이 가능한 이유: 개별 수식 typeset은 µs~ms 수준이고 캐시가 반복 비용을 없앤다.

제약: swiftui-math는 **iOS 17+, SwiftUI 전용**, 그리기 API(`CGContext.draw(DisplayNode)`)와
`DisplayNode`가 **internal**이라 UIKit에서 포크 없이 쓸 수 없다. MIT, SwiftMath 파생.

### 3.3 TextKit 2 관점 (WWDC 21 Meet TextKit 2 · WWDC 22 What's new in TextKit / Apple 공식 문서로 검증)

우리 블록 텍스트는 `UITextView`로 렌더링되고, iOS 16+에서 `UITextView`는 기본
TextKit 2다. TextKit 2는 viewport 기반 **noncontiguous layout이 항상 적용**되어
보이는 영역 + overscroll 영역만 배치한다 — 단, 뷰가 TextKit 1로 fallback하지
않을 때만이다.

- **TextKit 1 fallback 함정 (WWDC 22 실기 경고)**: `UITextView.layoutManager`에
  한 번이라도 접근하면 그 뷰는 즉시 TextKit 1 호환 모드로 전환된다.
  - **편도(one-way)다** — 자동으로 TextKit 2로 돌아오는 방법이 없다.
  - 전환 비용이 크고 선택·스크롤 위치 등 UI 상태를 잃는다.
  - contiguous layout으로 회귀해 성능이 떨어지고, Writing Tools 전체 경험도 잃는다
    (WWDC 24: "full Writing Tools experience는 TextKit 2 필수, TextKit 1은 패널
    표시만 되는 제한 경험").
  - 안전 패턴: 항상 `textView.textLayoutManager`(TextKit 2, nil이면 fallback 상태)를
    먼저 확인하고, `layoutManager`는 절대 건드리지 않는다.
  - 디버깅: `_UITextViewEnablingCompatibilityMode` 심볼릭 브레이크포인트를 걸면
    fallback 발생 지점을 잡을 수 있다.
  - 현재 코드는 `textContainer`·`sizeThatFits`·`attachmentBounds(for:...)`만
    사용해 안전하다. **신규 코드가 측정이나 attachment 처리 목적으로
    `layoutManager`를 만지면 회귀한다** (§8.5-13).
- **attachment bounds의 두 프로토콜**: 현재 `MathTextAttachment`는 TextKit 1 계열
  `NSTextAttachmentContainer`의
  `attachmentBounds(for:proposedLineFragment:glyphPosition:characterIndex:)`를
  override하며, TextKit 2 뷰에서도 호환 경로로 호출된다(코드 주석의 실측).
  TextKit 2 네이티브는 `NSTextAttachmentLayout`의
  `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`다.
  둘 다 동작하므로 **기존 override를 바꾸지 않는다** — 바꿀 이유가 생기면
  네이티브 쪽을 추가 구현한다.
- **`NSTextAttachmentViewProvider`(iOS 15+, Apple 문서 검증)**: TextKit 2의 뷰 기반
  attachment. `loadView()`로 임의 UIView를 싣고,
  `tracksTextAttachmentViewBounds = true`면 provider의
  `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`가
  크기를 결정한다. 인라인 수식을 이미지가 아니라 **뷰(MTMathUILabel)** 로 싣는
  공식 경로다. §8.4의 인라인 벡터화 선택지.
- 블록당 텍스트가 짧아 noncontiguous layout의 뷰 내부 이득은 작다. 가상화는
  collection view 계층이 담당한다. "문서 전체를 단일 `UITextView` + TextKit 2
  viewport(`NSTextViewportLayoutController`)로" 구조는 검토 후 기각 — 코드 블록
  가로 스크롤·복사 버튼 등 뷰 기반 블록이 단일 텍스트 뷰 모델과 맞지 않고,
  raw `NSTextLayoutManager` 직결 커스텀 뷰는 입력·선택·접근성·undo를 전부
  재구현해야 한다 (iOS 27에서야 framework text view 내부 viewport 커스터마이즈가
  열리지만 우리 타깃 밖).

### 3.4 시사점

Textual이 빠른 이유는 "벡터라서"가 아니라 **동기·캐시 기반 measure로 레이아웃이
1-pass로 끝나고, 비동기 hydration이 없어서**다. UIKit에서 같은 효과를 내는
공개 경로는 `MTMathUILabel`이다 — 내부에서 동기 typeset + 벡터 draw를 모두 한다.

## 4. 개선안 — 단계별

### P1. 측정 (게이트, 필수 선행)

`DEVELOPMENT.md` 재검토 조건 ③("raster 방식이 성능 병목으로 *측정*됨")을 따른다.
절차는 §8.1.

### P2. rebuild 증분화 — 엔진 교체 없이 (예상 효과 최대)

`rebuild()`의 전량 파괴/재생성을 블록 단위 재사용으로 교체. hydration 게시가 와도
수식 없는 블록의 `UITextView`는 그대로 두고 attributed string만 필요 시 갱신.
상세 설계는 §8.2.

> rev.2 정정: 초안의 "raster 전에 typeset 크기를 먼저 게시"(P2-2)는 **폐기**한다.
> typesetter가 internal이라 raster 없이 크기를 얻을 공개 API가 없다 (§3.1).
> 크기 선확보는 P3의 `MTMathUILabel` 동기 측정이 대신한다.

### P3. 블록 수식 벡터화 — `MTMathUILabel` 채택

블록 수식(`blockMathView`)을 raster `UIImageView` 대신 `MTMathUILabel`로 교체.
효과: 블록 수식의 hydration 대기·이미지 캐시·scale 변환이 사라지고, 크기가
rebuild 시점에 동기 확정되어 사후 리사이즈가 없어진다. 상세 설계는 §8.3.

**인라인 수식은 raster 유지.** `NSTextAttachment`는 이미지가 필요하고, 인라인은
크기가 작아 raster 비용이 낮다. 기존 `MathRenderService` 경로 유지.

### P4 (선택, 이번 구현 범위 아님). 멀티라인 수식 / 엔진 재검토

- 멀티라인: SwiftMath를 multiline 지원 버전으로 올려야 한다. 1.7.3 고정 사유가
  컴파일 버그였으므로 상위 버전 회귀 검증 선행.
- swiftui-math 교체 재검토 트리거: ① 배포 타깃 iOS 17+ 상향 **그리고** upstream이
  UIKit draw API 공개 ② SwiftMath 유지보수 중단 ③ 조판 버그가 swiftui-math에서만
  수정되는 패턴 반복. 이 조건 전에는 SwiftMath 유지 — 노출이 `MathRenderService`
  한 파일이라 교체 비용은 계속 낮다.

## 5. 옵션 비교

| 옵션 | 스크롤 성능 | iOS 16 | UIKit | 작업량 | 비고 |
|---|---|---|---|---|---|
| A. 현행 유지 + P2만 | 개선 큼 (예상) | ✅ | ✅ | 소 | 이미지 파이프라인 유지 |
| B. P2 + P3 (`MTMathUILabel`) | 개선 큼 + 블록 수식 리사이즈 제거 | ✅ | ✅ | 중 | **권장 경로** |
| C. swiftui-math로 교체 | B와 동급 | ❌ (iOS 17+) | ❌ (API internal) | 대 (포크 필요) | 현시점 배제 |
| D. 자체 typesetter | — | — | — | 최대 | 기각 유지 (`MTTypesetter` 93 KB 재구현) |

**권장: P1 → P2 → P3 순. P2와 P3은 독립 커밋으로 분리한다.**

## 6. 리스크

- **동기 typeset의 main thread 비용**: `MTMathUILabel.intrinsicContentSize`는 main에서
  동기 typeset한다. Textual이 같은 방식의 전례. 병리적 입력은 기존
  `RasterInputLimits.allows` preflight를 벡터 경로에도 적용해 차단한다 (§8.3-4).
- **기존 실측 회귀**: §8.5 목록의 실측 사실은 각 단계에서 보존한다.
- **테스트 계약**: `hasPendingRebuild`/`hasOutstandingWork` 기반 idle 대기에 새
  비동기 단계를 추가하면 기존 테스트가 flaky해진다. 새 비동기 hop 추가 금지.

## 7. DEVELOPMENT.md와의 정합

- "자체 조판 엔진을 구현하지 않는다" — 유지. P3은 SwiftMath의 기존 public 뷰 채택이다.
- "재검토 조건 ③: raster가 병목으로 측정되면 vector 검토가 먼저다" — 이 문서가
  그 검토안. P1 측정이 선행 게이트.
- 채택 시 `DEVELOPMENT.md` §4(2단계 게시 계약)와 §6(cache key)에 블록 수식 벡터화를 반영해 개정한다.

---

## 8. 구현 가이드

### 8.0 공통 규칙

- **검증 게이트**: 모든 단계 완료 시 `scripts/ci-test.sh` 통과가 조건이다.
  (host Core 빌드 → package scheme 단위 테스트 → 데모 UI 테스트 → Core coverage 80%)
  빠른 반복은 `swift build --target SwiftLatexCore` + `xcodebuild test -scheme SwiftLatex
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6'`.
- **커밋 단위**: P1 / P2 / P3 각각 별도 커밋. 한 커밋에 섞지 않는다.
- Swift 6 language mode + complete concurrency로 빌드된다. 컴파일러 isolation
  경고를 `@unchecked Sendable`로 덮지 말고 기존 패턴(actor, `nonisolated`,
  검사 면제 박스 주석)을 따른다.
- 기존 코드 주석은 실측 기록이다. 리팩터링 중 주석을 삭제하지 않는다.
- 이 문서에 없는 공개 API 추가 금지. 새 심볼은 `package` 또는 `private`.

### 8.1 P1 — 측정

1. `Sources/SwiftLatexCore/Signposts.swift`에 카테고리 추가:

   ```swift
   package static let rebuild = OSSignposter(subsystem: "dev.swiftlatex", category: "rebuild")
   ```

2. `LatexMarkdownUIView.rebuild()` 본문 전체를 interval로 감싼다
   (`MathRenderService.render`의 기존 `beginInterval`/`endInterval` 패턴 동일).
3. 데모 앱 UIKit 화면에서 Instruments **Time Profiler + Hitches** 템플릿으로
   스크롤 왕복 3회 프로파일. 시뮬레이터가 아닌 **실기기** 우선.
4. 판정 기준 — hitch 구간의 상위 스택이:
   - `rebuild` signpost / Auto Layout (`NSISEngine`) / `UITextView` 초기화 → P2 우선 (예상)
   - `raster` signpost / `CGContextDrawImage` → P3 우선
5. 측정 결과(hitch 수, 최장 hitch ms, 상위 스택 3개)를 이 문서 부록으로 기록한다.

### 8.2 P2 — rebuild 증분화

**대상 파일**: `Sources/SwiftLatex/LatexMarkdownUIView.swift`만. 모델·서비스 변경 없음.

**설계** — `ParsedBlock`은 `Hashable`이므로 값 비교로 재사용을 판단할 수 있다:

1. 뷰에 상태 추가:

   ```swift
   /// 마지막 rebuild가 만든 블록별 뷰. block 값·수식 이미지 상태가 같으면 재사용한다.
   private struct RenderedBlock {
       let block: ParsedBlock
       let view: UIView
       let usedImages: Bool   // 이 블록이 수식 이미지를 참조했는지
   }
   private var renderedBlocks: [RenderedBlock] = []
   private var renderedAppearance: AppearanceKey?  // theme+trait 폰트/색 식별
   ```

   `AppearanceKey`는 `theme`, `bodyUIFont.pointSize`, resolved 텍스트 색,
   `displayScale`을 담는 `Equatable` private struct로 새로 만든다.

2. `rebuild()` 교체 알고리즘:

   ```
   새 appearance 계산
   if document == nil → 기존 전량 교체 경로 유지(fallback), renderedBlocks = [] 후 종료
   if appearance != renderedAppearance → 전량 재생성 (폰트/색/scale 변경)
   else:
       새 blocks와 renderedBlocks를 index로 순회:
         같은 index에서 block 값이 같고,
           (usedImages == false               → 뷰 재사용
            usedImages == true && images 동일 공급 → 뷰 재사용
            그 외                              → 새로 생성)
         block 값이 다르면 → 그 index부터 나머지 전부 새로 생성 (suffix 교체)
   blockStack 재구성: 재사용 뷰는 removeArrangedSubview 하지 않고 순서만 유지,
       제거 대상만 removeFromSuperview
   renderedBlocks/renderedAppearance 갱신
   ```

   - "images 동일 공급" 판단: 현재 `rebuild()`가 쓰는
     `model.imageRequest == currentRequest ? model.mathImages : [:]` 결과 사전이
     이전 rebuild와 **같은 인스턴스 상태**인지 비교한다. 간단 구현: 블록에 포함된
     `MathSegment`들이 모두 사전에 존재하는지 여부(`Bool`)를 저장·비교.
   - suffix 교체로 단순화하는 이유: 스트리밍 입력은 append 중심이라 앞쪽 블록이
     안정적이다. 중간 삽입 diff(LCS)는 구현하지 않는다 — 복잡도 대비 이득 없음.

3. **수식 블록은 항상 재생성 대상으로 시작해도 된다** (P3에서 벡터 뷰로 바뀌며
   재사용이 단순해진다). 1차 목표는 텍스트/코드/리스트 블록의 `UITextView` 재사용.

4. **함정**:
   - `theme` didSet의 `scheduleRebuild()` + `submit()` 순서 유지. appearance 비교가
     전량 재생성을 이미 보장하므로 didSet에서 `renderedBlocks`를 직접 비우지 않는다.
   - trait 변경(다크 모드, Dynamic Type)은 `submit()`으로 들어온다 — appearance
     비교가 잡는다. `AppearanceKey`에 resolved color를 반드시 포함할 것
     (`UIColor(theme.textColor).resolvedColor(with: traitCollection)` 결과).
   - 재사용 뷰의 `arrangedSubviews` 순서: `blockStack.addArrangedSubview`는 이미
     붙어 있는 뷰를 옮겨도 안전하지만, 제거 대상은 반드시
     `removeArrangedSubview` + `removeFromSuperview` 짝으로 제거한다 (기존 코드 패턴).

5. **테스트** (`Tests/SwiftLatexTests/LatexMarkdownUIViewTests.swift`에 추가):
   - 같은 markdown 재제출 → 게시 없음(기존 계약) → `blockStack.arrangedSubviews`의
     뷰 identity 유지.
   - markdown 뒤에 문단 append → 앞 블록 뷰 identity 유지(`===` 비교), 새 블록만 추가.
   - theme 변경 → 전 블록 새 인스턴스.
   - 수식 hydration 게시 후 → 수식 없는 블록 뷰 identity 유지.
   - 기존 테스트 전부 무수정 통과. 테스트는 기존 파일의 idle 대기 헬퍼
     (`hasPendingRebuild`/`hasOutstandingWork`)를 재사용한다.

### 8.3 P3 — 블록 수식을 `MTMathUILabel`로

**대상 파일**: `Sources/SwiftLatex/LatexMarkdownUIView.swift`,
`Sources/SwiftLatex/MathRenderService.swift`(preflight 재사용 노출),
테스트 2개 파일. `LatexRenderModel`은 변경하지 않는다 — 인라인 수식이 여전히
raster 파이프라인을 쓰므로 게시 계약은 그대로다.

1. `blockMathView(segment:rendered:)`를 다음으로 교체:

   ```swift
   private func blockMathView(segment: MathSegment, rendered: RenderedMath?) -> UIView {
       let content: UIView
       let contentSize: CGSize
       if let label = vectorMathLabel(for: segment) {
           content = label
           contentSize = label.intrinsicContentSize   // 동기 typeset — 최종 크기 즉시 확정
       } else {
           // preflight 초과·폰트 로드 실패 → 기존 원문 fallback 경로 유지
           ...기존 textView(source) 경로...
       }
       ...기존 copy 버튼 + horizontalScroll 조립 유지...
   }

   private func vectorMathLabel(for segment: MathSegment) -> MTMathUILabel? {
       let key = MathRenderKey(...)                    // currentRequest와 동일 재료
       guard MathRenderService.preflightAllows(key) else { return nil }
       let label = MTMathUILabel()
       label.latex = segment.latex
       label.font = MTFontManager.manager.font(
           withName: theme.mathFont.swiftMathFont.rawValue,
           size: bodyUIFont.pointSize
       )
       label.labelMode = .display
       label.textColor = UIColor(theme.textColor).resolvedColor(with: traitCollection)
       label.displayErrorInline = false                // 오류 시 우리 fallback을 쓴다
       guard label.error == nil else { return nil }
       label.isAccessibilityElement = true
       label.accessibilityLabel = "수식: \(segment.latex)"
       return label
   }
   ```

   - `MTFontManager.font(withName:size:)`의 name은 `MathFont`(우리 매핑
     `LatexMathFont.swiftMathFont`)의 `rawValue`다. `MTFont`를 다른 방법으로
     만들지 말 것 — 번들 폰트 로딩은 FontManager가 캐시한다.
   - `label.error`는 latex 대입 시점에 채워진다(parse 실패). nil 확인 필수.
2. `MathRenderService`에 preflight 재사용 통로 추가 (raster와 동일 상한):

   ```swift
   package nonisolated static func preflightAllows(_ key: MathRenderKey) -> Bool {
       RasterInputLimits.allows(key, sourceRendererScale: sourceRendererScale)
   }
   ```

   `RasterInputLimits`와 `sourceRendererScale`은 기존 private — 접근 수준만 조정.
3. **hydration 뷰 재사용과의 결합**: 블록 수식이 이미지 사전을 더 이상 쓰지 않으므로
   §8.2의 `usedImages`는 **인라인 수식을 포함한 문단**에만 해당하게 된다.
   `blockMath` 블록은 block 값이 같으면 무조건 재사용으로 승격한다.
4. **스레드 규칙**: `MTMathUILabel`은 UIView다 — **main thread에서만** 생성·설정.
   worker/actor로 옮기지 말 것. typeset 비용은 P1에서 실측했고 preflight가 상한이다.
5. **SwiftUI 경로(`LatexMarkdownView`)는 이번에 변경하지 않는다.** 블록 수식
   raster 유지. 버벅임 보고는 UIKit 리스트 환경이고, SwiftUI까지 바꾸면 회귀
   면적이 두 배가 된다. UIKit 검증 후 별도 작업으로.
6. **테스트**:
   - `LatexMarkdownUIViewTests`: 블록 수식 markdown 입력 → idle 후 계층에서
     `MTMathUILabel` 존재 확인, `intrinsicContentSize.height > 0`,
     accessibilityLabel == "수식: …".
   - 오류 latex(`\[\frac{\]`류) → `MTMathUILabel`이 아니라 원문 textView가 존재.
   - preflight 초과 입력(초장문 latex) → 원문 fallback.
   - `MathRenderServiceTests`: 기존 raster 테스트 무수정 통과(인라인 경로 보존 확인).
   - 데모 스크린샷 UI 테스트가 있다면 기준 이미지 갱신이 필요할 수 있다 —
     벡터/raster 렌더 결과의 픽셀 차이는 예상된 변화다.

### 8.4 P3 이후 선택 과제 (이번 구현 범위 아님)

- 인라인 수식 벡터화 — `NSTextAttachmentViewProvider`(iOS 15+, Apple 문서 검증):
  1. `NSTextAttachment` 서브클래스에서 `viewProvider(for:location:textContainer:)`를
     override해 커스텀 provider를 반환 (`allowsTextAttachmentView`는 기본 true,
     `registerViewProviderClass(_:forFileType:)`는 파일 타입 기반이라 우리 경우 아님).
  2. provider 서브클래스: `loadView()`에서 `view = MTMathUILabel(...)` 구성,
     `tracksTextAttachmentViewBounds = true` 설정,
     `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`에서
     label 크기와 `-descent` baseline 오프셋 반환 (기존 `MathTextAttachment`
     bounds 계산과 동일 수식).
  3. 주의: 뷰 기반 attachment는 텍스트 선택·복사 시 이미지처럼 복사되지 않는다 —
     현재 접근성 계약(`spokenOverride`)과 복사 동작을 테스트로 재검증해야 한다.
  또는 더 작게: offscreen `MTMathUILabel` 동기 측정으로 placeholder 크기만
  선확보하고 raster는 유지. 인라인 리사이즈가 P1/사후 측정에서 여전히 hitch
  상위면 검토.
- SwiftUI 경로 벡터화(`UIViewRepresentable` 래핑).
- SwiftMath 버전업 + 멀티라인 (§4 P4).

### 8.5 하지 말 것 — 실측 함정 목록

| # | 금지 | 근거 (실측, 코드 주석에 기록됨) |
|---|---|---|
| 1 | `LatexRenderModel.submit`에서 동기 게시 | 셀 attach 레이아웃 패스 안 리사이즈 → contentOffset 보정이 스크롤 제스처를 상쇄해 위로 스크롤이 얼어붙음 |
| 2 | `process`/`run`의 `nonisolated` 제거 | static 멤버도 `@MainActor` 적용 — parse가 main을 점유 (50 KiB p50 ≈ 119 ms) |
| 3 | `NSTextAttachment.bounds`에 크기 지정 | `UITextView`에 실리면 `.zero`로 읽혀 baseline 보정 소실. `attachmentBounds(for:...)` override 유지 |
| 4 | `traitCollection.displayScale`을 그대로 사용 | window 부착 전 0일 수 있음 — 기존 `displayScale` computed property 경유 |
| 5 | `MTTypesetter.createLineForMathList` 호출 | internal — 컴파일 불가. display list는 `MTMathUILabel.displayList`로만 접근 |
| 6 | `MTMathUILabel`을 actor/worker에서 생성 | UIView는 main thread 전용 |
| 7 | `MTFont` 직접 생성 | `MTFontManager` 캐시 우회 — 폰트 plist 재로딩 비용 |
| 8 | 게시 경로에 새 비동기 hop 추가 | `hasPendingRebuild`/`hasOutstandingWork` idle 계약이 깨져 기존 테스트 flaky |
| 9 | `copyButton` 크기 가변화 | 44×44 고정 — 아이콘 교체로 폭이 바뀌면 XCUITest idle 대기가 풀리지 않음 |
| 10 | `UIButton` 기본 tint 방치, 링크 색 attributed 외 지정 | 접근성 대비 기준(4.5:1) audit 실패 이력 |
| 11 | 앰비언트 trait으로 테마 폰트 해석 | `traitOverrides` 뷰에서 글자 크기 미반영 — 항상 뷰의 `traitCollection` 사용 |
| 12 | `parsesDollarMath` 기본값 변경 | opt-in이 계약 (`$` 오탐 방지, DEVELOPMENT.md) |
| 13 | `UITextView.layoutManager` 접근 (신규 코드·테스트 포함) | 접근 즉시 그 뷰가 TextKit 1 호환 모드로 **편도 전환** — 복귀 불가, UI 상태(선택·스크롤) 상실, noncontiguous layout 상실, Writing Tools 상실 (WWDC 22 실기 경고). 확인은 `textLayoutManager`(nil 검사), 측정은 `sizeThatFits`, attachment는 `attachmentBounds(for:...)` 또는 `NSTextAttachmentViewProvider`만. fallback 의심 시 `_UITextViewEnablingCompatibilityMode` 심볼릭 브레이크포인트로 추적 |

### 8.6 완료 체크리스트

- [ ] **P1 측정 결과가 문서 부록에 기록됨** — 미완. signpost 계측(§8.1-1·2)만 반영.
      §8.1-3~5는 실기기 Instruments 세션이 필요하다 (§9.1)
- [x] `scripts/ci-test.sh` 전 단계 통과 (Core coverage ≥ 80% 포함) — 2026-08-21
- [x] 기존 테스트 무수정 통과 (61개 → 총 68개, 수정 0건)
- [x] §8.2·§8.3의 신규 테스트 추가·통과 (§8.2 4개, §8.3 3개)
- [ ] **데모 앱 UIKit 화면 실기기 스크롤에서 hitch 감소를 P1과 같은 방법으로 재측정·기록**
      — 미완. P1과 같은 이유다 (§9.1)
- [x] `DEVELOPMENT.md` §4·§6·"UIKit 네이티브 렌더러"에 변경 반영, `CHANGELOG.md` 갱신

---

## 9. 구현 기록 (2026-08-21)

커밋 3개. 각 단계 끝에서 `xcodebuild test -scheme SwiftLatex`를, 마지막에
`scripts/ci-test.sh` 전 단계를 통과했다.

| 커밋 | 단계 | 범위 |
|---|---|---|
| `04b1504` | P1 | `Signposts.swift`에 `rebuild` 카테고리, `rebuild()`를 interval로 감쌈 |
| `74cb6f3` | P2 | `LatexMarkdownUIView` rebuild 증분화 + 테스트 4개 |
| `a1b8a63` | P3 | 블록 수식 벡터화 + `preflightAllows` + 테스트 3개 |

### 9.1 P1은 절반만 끝났다 — 게이트가 열리지 않았다

§8.1-1·2(코드 계측)는 반영했다. §8.1-3~5(실기기 Instruments Time Profiler + Hitches
프로파일, hitch 수·최장 hitch ms·상위 스택 3개 기록)는 **하지 않았다.** 실기기 연결과
Instruments GUI 세션이 필요한 작업이고 이 환경에서 실행할 수 없다.

따라서 §4가 "P1 = 게이트, 필수 선행"으로 세운 조건은 **충족되지 않은 상태로 P2·P3가
들어갔다.** 이 문서의 병목 진단(§2)은 여전히 코드 근거에 기반한 가설이다. 남은 작업:

1. 데모 앱 `AI 챗봇 (UIKit)` 화면을 실기기에서 Instruments로 스크롤 왕복 3회 프로파일.
2. `dev.swiftlatex`의 `rebuild`·`raster` signpost를 hitch 구간과 겹쳐 본다.
3. 결과가 §2의 가설(rebuild/Auto Layout 우세)과 다르면 이 문서를 개정한다.
   특히 상위 스택이 `raster`/`CGContextDrawImage`로 나오면 §8.4의 인라인 수식
   벡터화가 다음 후보다.
4. 같은 방법으로 변경 전/후를 비교해 hitch 감소를 정량 기록한다 (§8.6의 남은 항목).

### 9.2 §8 가이드에서 벗어난 지점 3개

**① §8.2 의사코드의 `renderedBlocks = []`를 따르지 않았다.**

§8.2 의사코드는 `document == nil` 경로에서 `renderedBlocks = []` 후 종료하라고 했다.
그렇게 하면 §8.2-5가 요구하는 "markdown 뒤에 문단 append → 앞 블록 뷰 identity 유지"가
성립하지 않는다. `LatexRenderModel.submit`은 `parseIdentity`가 바뀌면 항상
`document = nil`을 먼저 게시하므로(코드 확인), markdown이 바뀌는 모든 경로가 fallback
단계를 거친다. 거기서 비우면 스트리밍 append의 재사용률이 0이 된다.

채택: 뷰 인스턴스는 `renderedBlocks`에 남기고 계층에서만 뗀다. 다음 게시에서
`setBlockViews(_:reusedCount:)`가 prefix가 계층에 붙어 있는지 확인해 필요하면 재배치한다.
회귀 방지는 `keepsLeadingBlockViewsWhenAppendingParagraph`가 담당한다.

**② §8.3-1/§8.5-7의 `MTFontManager` 지시를 따르지 않았다.**

§8.5-7은 "`MTFont` 직접 생성 금지 — `MTFontManager` 캐시 우회, 폰트 plist 재로딩 비용"이라고
했으나 SwiftMath 1.7.3 소스 실측 결과 **반대**다.

| 경로 | 실제 동작 |
|---|---|
| `MTFontManager.font(withName:size:)` | legacy `MTFont(fontWithName:size:)` — `.otf`를 `CGDataProvider(filename:)`로 읽고 math table `.plist`를 `NSDictionary(contentsOf:)`로 파싱. 이름당 1회 캐시하지만 size가 캐시된 값과 다르면 `copy(withSize:)`가 `MTFontMathTable`을 매번 재구성 |
| `MathFont.mtfont(size:)` → `MTFontV2` | `BundleManager`가 캐시한 `CGFont`/`CTFont`를 재사용, math table은 인스턴스별 lazy |

결정적 근거는 비용이 아니라 **일관성**이다. raster 경로(`MathImage.asImage()`)가
`font.mtfont(size: fontSize)`를 쓴다. 두 경로가 다른 폰트 구현을 쓰면 인라인(raster)과
블록(vector)의 글리프 메트릭이 갈릴 수 있다. 그래서 벡터 경로도 `mtfont(size:)`를 쓴다.

덧붙여 `MTMathUILabel.fontSize`는 `font`와 **별도 저장 값**이고
`_layoutSubviews`의 세로 정렬(`height < fontSize/2` 클램프)에 쓰인다. 기본값 20이 남으면
raster(`MathImage`, 실제 요청 size 사용)와 정렬 기준이 갈리므로 함께 맞춘다.

**③ `vectorMathLabel`을 뷰가 아니라 `MathRenderService.swift`에 뒀다.**

§8.3-1은 `LatexMarkdownUIView`에 `vectorMathLabel(for:)`을 두라고 했다. 그러면 뷰
파일에 `import SwiftMath`가 필요해 `DEVELOPMENT.md` §5의 "SwiftMath 호출은
`MathRenderService`에 가둬 두므로 교체 시 그 파일만 바뀐다"가 깨진다.

채택: `MathRenderService.swift`에 `@MainActor package enum BlockMathVectorView`를 두고
`make(key:textColor:) -> UIView?`로 반환한다. 뷰는 `UIView`만 다루므로 SwiftMath 타입이
새지 않고, 크기는 `UIView.intrinsicContentSize`로 읽는다. 접근성 label만 뷰 쪽에서 건다.

### 9.3 §8.5 "하지 말 것" 목록 추가 항목

| # | 금지 | 근거 (실측) |
|---|---|---|
| 14 | `document == nil` 경로에서 `renderedBlocks` 비우기 | markdown 변경은 항상 이 경로를 거친다 — 비우면 스트리밍 append 재사용률 0 (§9.2-①) |
| 15 | 이미 arranged인 뷰에 `addArrangedSubview` 재호출 | 순서가 바뀔 수 있다. 계층에서 떼어낸 뷰에만 호출한다 |
| 16 | `MTMathUILabel.font`만 설정하고 `fontSize` 방치 | `fontSize`는 별도 저장 값이고 내부 세로 정렬에 쓰인다. 기본값 20이 남아 raster와 정렬이 갈린다 (§9.2-②) |
| 17 | `displayErrorInline = false`를 `latex` 대입 **뒤에** 설정 | 대입 시점에 내부 errorLabel 표시 여부가 정해진다 — 뒤에 걸면 오류 텍스트가 한 번 보인다 |
| 18 | 뷰 파일에 `import SwiftMath` 추가 | §5 통제권 계약(SwiftMath 호출을 한 파일에 가둔다)이 깨진다. `BlockMathVectorView.make`가 `UIView?`를 반환한다 (§9.2-③) |

### 9.4 남은 낭비 — 아무도 읽지 않는 블록 수식 raster

§8.3-"`LatexRenderModel`은 변경하지 않는다"를 지켰으므로, model은 여전히
`ParsedDocument.allMathSegments` 전체(블록 수식 포함)를 raster한다. UIKit 렌더러만
쓰는 앱에서 블록 수식 raster 결과는 **아무도 읽지 않는다.**

방치한 이유: worker에서 실행되고 main을 잡지 않으며, 게시 계약·generation 규칙·idle
계약을 건드리지 않는다. 없애려면 model이 렌더러별로 필요한 segment 집합을 구분해야
하고 그건 두 렌더러가 공유하는 게시 계약을 바꾸는 일이다. P1 측정에서 `raster`
signpost가 hitch 상위로 나오면 그때 다루는 게 맞다.

### 9.5 재사용률이 낮은 경로 — 원문 fallback 프레임

P2로 블록 뷰는 재사용되지만 **fallback 프레임 자체는 남는다.** markdown이 바뀌면
`document = nil` 게시 → rebuild가 원문 전체를 담은 `UITextView` 하나를 만든다. 즉
스트리밍 갱신마다 큰 `UITextView` 하나를 만들고 버린다.

없애려면 model이 "이전 문서를 유지한 채 새 parse를 기다리는" 상태를 갖거나 뷰가
fallback 표시를 한 프레임 미뤄야 한다. 둘 다 §4의 "최신 원문 fallback 즉시 표시"
계약과 §8.5-8(새 비동기 hop 금지)에 걸리므로 P1 측정 없이 손대지 않는다.
