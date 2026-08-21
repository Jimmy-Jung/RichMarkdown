# SwiftLatex 개발 문서

메시지 렌더러다. Markdown, 인라인/블록 LaTeX, 코드 블록을 네이티브 UI로
표시하는 재사용 가능한 Swift Package를 목표로 한다. SwiftUI는 `LatexMarkdownView`,
UIKit은 네이티브 `LatexMarkdownUIView`가 담당하고 파서·수식 raster·generation
관리는 두 뷰가 공유한다.

- 작성자: JunyoungJung
- 최초 작성: 2026-08-19
- 최종 개정: 2026-08-19 (rev.5 — P0 검증 결과 반영)
- 상태: P0 완료, P1 골격 구현 및 테스트 통과 (Core coverage 92.5%)
- 배포 대상 후보: iOS/iPadOS 16 이상

---

## 0. 문서의 결정 수준

### 확인된 사실

- SwiftMath `1.7.3`의 `MathImage.asImage()`는 이미지와
  `LayoutInfo(ascent:descent:)`를 반환한다. 기존 fork 계획은 필요 없다.
- P0 검증 결과(2026-08-19): SwiftMath `1.7.2`는 `MTMathListBuilder.swift`의
  scope 버그(typo)로 Xcode `26.6 (17F113)`에서 컴파일되지 않는다. `1.7.3`이
  수정 버전이며 `asImage()`의 `(NSError?, MTImage?, LayoutInfo?)` API는 동일하다.
  고정 버전을 `exact: "1.7.3"`으로 확정했다.
- `swift-markdown`은 수식 AST 노드를 제공하지 않는다. 수식 구간을 별도로 찾아
  원문 범위를 보존해야 한다.
- 검토한 `swift-markdown 0.4.0`의 source column은 UTF-8 byte 기준이다.
- iOS 16에서 `Text(Image:)`, `Text.baselineOffset(_:)`,
  `.textSelection(.enabled)`, `UIHostingConfiguration`, `UIHostingController`를 사용할 수 있다.
- 현재 검증 도구는 Xcode `26.6 (17F113)`이다.
- 현재 설치된 simulator runtime은 iOS `18.6`, `26.3`, `26.5`이며 iOS 16 runtime은 없다.

최소 toolchain, parser range, baseline/raster preflight, concurrency, iOS 16 runtime,
스트리밍 기준은 P0에서 결정한다. 그전에는 “설계 확정”, “Xcode 16+ 지원”,
“임의의 untrusted 입력에 안전”이라고 선언하지 않는다.

---

## 1. v1 목표와 범위

### 목표

LLM 채팅 UI에서 어시스턴트 메시지 하나를 다음처럼 표시한다.

```text
원의 넓이는 \( A = \pi r^2 \)입니다.
            ↓
문장 흐름 안에 baseline 정렬된 수식이 포함된 네이티브 텍스트
```

### 포함 범위

| 영역 | v1 계약 |
|---|---|
| Markdown 블록 | 문단, 헤딩, 순서/비순서 리스트, 인용, 구분선 |
| 인라인 | 굵게, 기울임, 취소선, 코드, 절대 URL 링크, 줄바꿈 |
| 수식 | 기본 `\(...\)`, `\[...\]`; opt-in `$...$`, `$$...$$` |
| 코드 블록 | 언어 라벨, 가로 스크롤, 복사 버튼, plain monospace |
| 스트리밍 | 최신 전체 `String` 입력, coalescing과 latest-wins 게시 |
| 선택 | SwiftUI `.textSelection(.enabled)`의 시스템 동작 |
| UIKit | 네이티브 `LatexMarkdownUIView` + `UIHostingConfiguration`·`UIHostingController` 사용 예제 |
| 접근성 | Dynamic Type, VoiceOver, 키보드, 명암/굵은 텍스트 검증 |

### 명시적 비목표

- 공개 parser/AST product
- 신택스 하이라이팅과 Highlightr 의존성
- 여러 블록을 가로지르는 연속 범위 선택
- 범위(문자 구간) 단위 색·폰트 지정. 테마는 요소 단위다
- callback 기반 링크/복사 API
- 공개 입력 제한 설정
- 표, 원격 이미지, Mermaid, HTML 실행, WebView, 편집, macOS UI
- 링크와 이미지 Markdown 문법 내부의 LaTeX 해석

두 번째 실제 소비자나 측정된 요구가 생기기 전에는 위 기능을 추가하지 않는다.

### 실패 시 표시 원칙

- 잘못되거나 미완성인 LaTeX는 원래 구분자를 포함한 source를 표시한다.
- 미지원 Markdown 노드는 읽을 수 있는 plain text로 낮추며 조용히 삭제하지 않는다.
- 이미지 문법은 alt text만 표시한다.
- HTML은 실행하지 않고 문자 그대로 표시한다.
- 제한을 넘은 입력은 `Character` 경계의 bounded prefix와 명시적 생략 marker로 표시한다.

---

## 2. 최소 공개 표면

v1의 공개 product는 `SwiftLatex` 하나다.

```swift
import SwiftLatex

LatexMarkdownView(
    markdown: message,
    parsesDollarMath: false
)
.latexTheme(.default)
```

- `parsesDollarMath` 기본값은 `false`다.
- 테마는 색 6종 + 폰트 7종 + 수식 서체를 **요소 단위**로 갖는다. `LatexFont`는
  `Font`/`UIFont`가 아니라 `Sendable` 값이라 렌더 요청 key에 넣을 수 있다.
- 텍스트 색·폰트는 두 렌더러 모두 **명시 지정**한다. SwiftUI에서 환경 값에 맡기면
  `theme`가 본문에 닿지 않고 소비 앱의 바깥 `.font(_:)`가 우연히 새어 들어온다.
- 링크 실행은 allowlist를 통과한 뒤 SwiftUI `OpenURLAction`을 사용한다.
- 코드 복사는 패키지의 native `Button` 동작으로 제공한다.
- UIKit은 `LatexMarkdownUIView`(네이티브 `UIView`)가 담당한다. SwiftUI 뷰를 감싼
  래퍼가 아니며 파서·`MathRenderService`·`LatexRenderModel`을 SwiftUI 경로와 공유한다.
- 범용 custom renderer API는 만들지 않는다.
- 내부 parser target은 테스트와 UI target 분리를 위해 두되 외부 product로 노출하지 않는다.
  UI target이 쓰는 교차 target 심볼은 Swift 5.9의 `package` 접근 수준으로 한정한다.

### 초기 Package.swift 방향

- Swift tools `6.0`, platform `.iOS(.v16)`을 사용한다 (P0 확정).
  Swift Testing 채택으로 tools 6.0이 필요하며, 우리 target은 Swift 6 language
  mode + complete concurrency로 빌드된다. host Core 검증을 위해 `.macOS(.v12)`
  최소 선언을 추가한다(SwiftMath 요구, macOS UI 비목표 유지).
- 공개 product는 `SwiftLatex` 하나다.
- 비공개 `SwiftLatexCore` target은 `Markdown` product에 의존한다.
- UI target은 Core와 SwiftMath에 의존한다.
- P0 재현성은 SwiftMath `exact: "1.7.3"`, swift-markdown `exact: "0.4.0"`으로 고정한다.
- 지원 toolchain을 확정한 뒤에만 CI에서 검증한 버전 범위로 넓힌다.

`swift-markdown`을 `from: "0.4.0"`으로 선언하면 SwiftPM이 Swift tools 6.2가 필요한 이후
0.x 버전을 선택할 수 있으므로 낮은 Xcode 지원 계약과 함께 사용하지 않는다.

---

## 3. 파싱 계약

### 후보 흐름

```text
원문 UTF-8
  │
  ├─ 사전 byte 상한 검사
  ├─ 1차 swift-markdown 파싱
  │    ├─ Paragraph 범위 수집
  │    └─ CodeBlock, InlineCode, HTML, Link/Image 전체 범위를 금지 범위로 수집
  ├─ 원문 수식 스캔
  │    └─ 금지 범위를 제외하고 delimiter 후보와 원문 span 저장
  ├─ 원문과 UTF-8 byte 길이가 같은 수식 보호 버퍼 생성
  ├─ 2차 swift-markdown 파싱
  └─ 내부 ParsedDocument 생성
```

1차 AST는 수식을 찾는 결과가 아니라 코드와 링크 같은 금지 문맥을 찾는 데만 사용한다.
수식은 원문 전체에서 탐색한다. 그래야 `\(a * b\)`, `\(x_[i]\)`처럼 Markdown 기호가
포함된 LaTeX를 1차 Markdown 노드 분할과 관계없이 보호할 수 있다.

block 수식은 1차 AST의 paragraph source 전체를 기준으로 판정하고, 나머지 허용 범위에서
inline 수식을 찾는다. `swift-markdown` 공개 API만으로 link destination의 정확한 내부 범위를
안정적으로 얻는다는
가정을 두지 않는다. v1은 단순하고 안전하게 `Link`와 `Image` 전체 source range에서 수식을
해석하지 않는다.

### 보호 버퍼

각 수식은 다음 정보로 보존한다.

```swift
struct ProtectedMathSpan {
    let originalUTF8Range: Range<Int>
    let kind: MathKind
    let source: String
}
```

- 수식 span의 각 non-newline UTF-8 byte를 ASCII `x` 한 byte로 바꾸는 방식을 P0에서 검증한다.
- LF/CRLF와 span 밖의 indentation은 그대로 둔다.
- 보호 버퍼와 원문의 UTF-8 byte 길이를 항상 같게 유지하므로 2차 AST range를 별도
  offset 변환 없이 원문 range로 사용할 수 있다.
- placeholder 안의 diagnostic은 해당 원문 수식 span 전체에 연결한다.
- `restore(protect(source)) == source`를 byte 단위로 보장한다.

다국어 수식 앞뒤의 source range가 그대로 유지되는 property test가 필수다.

### delimiter 규칙

우선순위는 다음과 같다.

```text
code / HTML / Link / Image 금지 범위
  > escaped delimiter
  > \[...\] / \(...\)
  > opt-in $$...$$ / $...$
  > plain text
```

- `\(...\)`는 한 logical line의 inline 수식이다.
- `\[...\]`와 opt-in `$$...$$`는 공백을 제외한 한 paragraph source 전체가 해당
  구분자로 감싸진 경우에만 block 수식이다.
- 미완성·빈 구분자와 중첩 delimiter는 plain text와 내부 diagnostic으로 처리한다.
- 연속 backslash의 홀짝에 따른 escape 결과를 fixture로 고정한다.
- Dollar math는 기본 비활성화하고 다음 v1 자체 규칙만 약속한다.
  - `\$`는 delimiter가 아니다.
  - 여는 `$` 바로 뒤와 닫는 `$` 바로 앞에 공백이 올 수 없다.
  - 닫는 `$` 바로 뒤에 숫자가 올 수 없다.
  - inline `$...$`는 줄바꿈을 넘지 않는다.
  - `$$`를 `$`보다 먼저 판정한다.

“Pandoc과 완전히 동일”하다고 표현하지 않는다. 구현한 규칙과 fixture가 실제 계약이다.

### 내부 모델

- parser와 AST는 `SwiftLatexCore` target의 package-private 구현 세부사항이다.
- source span은 원문 UTF-8 offset/length를 저장한다.
- view identity는 렌더 시점의 위치와 content digest로 만들며 편집 사이의 영속성을
  약속하지 않는다.

---

## 4. 비동기 렌더 계약

SwiftUI `body`와 `.task`의 MainActor 구간에서 CPU 파싱이나 수식 raster 생성을 직접
실행하지 않는다.
`.task`가 `async`라는 사실만으로 background 실행을 보장한다고 가정하지 않는다.

```text
새 markdown + 환경값
  │
  ├─ MainActor: generation 증가, 최신 원문 fallback 즉시 표시
  ├─ 단일 worker: 실행 중 1개 + 최신 대기 1개만 유지
  ├─ non-MainActor RenderService: parse
  ├─ MainActor: generation 일치 시 수식을 원문으로 둔 ParsedDocument 게시
  ├─ MathRenderService actor: 수식 이미지 준비
  └─ MainActor: generation 일치 시 hydrated RenderedDocument 게시
```

- **`@MainActor` 타입의 처리 함수에는 `nonisolated`를 붙인다.** global actor 표시는
  static 멤버에도 적용되므로, `nonisolated` 없는 `LatexRenderModel`의 static 처리 함수는
  전체가 MainActor에서 실행되고 `swift-markdown` parse가 main thread를 점유한다
  (50 KiB에서 p50 약 119ms). 컴파일러의
  `no 'async' operations occur within 'await' expression` 경고가 이 표시가 빠졌다는 신호다.
  경고를 지우려고 `await`를 떼면 결함이 남고 신호만 사라진다.
  회귀 방지: `StreamingBaselineTests.parseDoesNotBlockMainActor`가 250 KiB 처리 중
  MainActor 최대 공백을 잰다(정상 약 7ms, 단독 실행 기준).
- request key에는 source, dollar 옵션, theme, scaled point size, resolved color,
  수식 서체를 포함한다.
- 새 요청은 현재 generation을 stale로 표시하고 대기 요청을 최신 값으로 교체한다.
- 장수명 worker 하나만 요청을 소비한다. 현재 동기 구간이 반환되기 전에는 다음 요청을
  시작하지 않으며, `.bufferingNewest(1)` 같은 경계로 대기는 하나만 유지한다.
- 첫 parse 전, service 진입 직후, parse 직후, 각 수식 block 사이에 generation을 확인한다.
- `swift-markdown` parse와 SwiftMath raster 하나는 동기·비취소 구간일 수 있으므로 입력/수식
  상한으로 작업량을 제한하고 측정된 최대 실행 시간을 gate로 둔다. 완료 직후에는 오래된
  generation을 버린다.
- parse 게시와 최종 게시 직전에 각각 generation을 확인한다.
- stale이 된 하위 연산이 늦게 끝나도 결과를 UI나 cache에 넣지 않는다.
- `RenderedDocument`는 게시 후 변경하지 않는 값이다.
- 수식 렌더 실패 시 해당 노드만 원문 source를 유지한다.
- **UIKit 렌더러의 블록 수식은 이 2단계 게시에 참여하지 않는다** (2026-08-21).
  `LatexMarkdownUIView`는 블록 수식을 SwiftMath의 벡터 뷰로 그리며 크기가 rebuild
  시점에 동기 확정된다. 위 파이프라인은 model 계약이라 그대로다 — 인라인 수식이
  여전히 raster를 쓰고 게시 횟수·generation 규칙·idle 계약이 바뀌지 않는다.
  SwiftUI 렌더러는 블록 수식도 raster를 유지한다.
  raster 대상에서도 빠진다: UIKit 요청은 `rastersDisplayMath: false`라 model이
  display segment를 raster하지 않는다 (§6). 블록 수식만 있는 문서는 기다릴 raster가
  없어 원문 fallback 단계 없이 단일 게시로 끝난다.
- 게시 경로에 **새 비동기 hop을 넣지 않는다.** 테스트의 idle 판정은
  `hasPendingRebuild`/`hasOutstandingWork` 두 값에만 의존하므로 중간 단계를 늘리면
  기존 테스트가 flaky해진다.

`RenderService`와 `MathRenderService`의 isolation은 P0 spike로 컴파일·실행 검증한다.
특히 SwiftMath가 반환하는 이미지 타입을 actor 밖으로 보낼 때 비검증
`@unchecked Sendable`로 경고만 숨기지 않는다. 안전한 immutable bitmap 전달 경로를 확인하지
못하면 bounded MainActor 렌더나 데이터 변환 경로를 선택한다.

API는 현재 메시지 전체 `String`을 받으며 증분 parser를 제공하지 않는다. 호출자는 token
이벤트를 최대 약 10Hz로 합쳐 전달한다. P0에서는 50 KiB fixture를 10Hz로 30초 갱신해
기준 기기/OS/configuration의 baseline, idle 시간, 실행/대기 상한을 정한다. 증분 파싱은
확정된 성능 기준을 넘은 측정 근거가 있을 때만 검토한다.

---

## 5. 렌더링과 플랫폼 계약

### 수식 엔진 선정 근거 (2026-08-20 기록)

이 절은 사후 기록이다. SwiftMath는 문서 초안부터 전제로 잡혀 있었고 선정 근거가
남아 있지 않아, 대안을 실측 조사한 뒤 정리했다.

요구조건으로 후보를 거르면 SwiftMath 하나가 남는다.

| 요구 | 탈락 후보 | 근거 |
|---|---|---|
| iOS 16 | `swiftui-math` | Package.swift `platforms: .iOS(.v17)` |
| UIKit 렌더러에서 사용 | `swiftui-math` | SwiftUI `Math` 뷰만 노출. `UIImage` 경로 없음 |
| JS 런타임 없음 | `LaTeXSwiftUI`/`MathJaxSwift` | JavaScriptCore + MathJax |
| WebView 없음 | KaTeX/MathJax | — |
| Swift 6 동시성 | `iosMath` | Objective-C, 유지보수 중단 |

설계가 의존하는 SwiftMath의 성질은 둘이다.

1. **`asImage()`가 `MTImage`(=`UIImage`)를 반환한다.** 이것이 두 렌더러가 같은
   raster를 공유하는 전제다. SwiftUI는 `Text(Image(uiImage:))`, UIKit은
   `NSTextAttachment`로 같은 결과물을 쓴다. 수식 엔진이 SwiftUI 뷰였다면 아래
   "UIKit 네이티브 렌더러" 절은 성립하지 않는다.
2. **`LayoutInfo(ascent:descent:)`를 함께 반환한다.** `-layout.descent` baseline
   보정의 유일한 근거다. 이미지만 주는 엔진으로는 인라인 정렬을 맞출 수 없다.

`swiftui-math`(Textual이 사용)는 SwiftMath 파생이다 — LICENSE에 SwiftMath와
iosMath 저작권이 함께 표기돼 있다. 조판 엔진은 같고 출력이 vector/raster로 갈렸을
뿐이며, 그 선택이 UIKit 지원 가능 여부를 결정한다.

**자체 구현하지 않는다.** SwiftMath 소스는 60파일 약 469 KB이고 `MTTypesetter.swift`
하나가 93 KB다. TeX atom 간격표, 스타일 4단계, OpenType MATH 테이블, extensible
delimiter 글리프 조립을 다시 구현하는 것은 이 패키지의 목표가 아니다.

**통제권** — SwiftMath는 MIT다. §6의 raster preflight API 부재처럼 아쉬운 지점은
상류 기여 또는 fork로 해결한다. 엔진 교체 사유가 아니다. SwiftMath 호출은
`MathRenderService`에 가둬 두므로 교체 시 그 파일만 바뀐다.

**재검토 조건** — ① upstream 유지보수 중단 ② 신규 iOS/Swift에서 구조적 사용 불가
③ raster 방식이 성능 병목으로 *측정*됨. ③에서도 자체 구현이 아니라 vector 방식
검토가 먼저다.

### 인라인 수식

SwiftMath `1.7.3`의 공개 API만 사용한다.

```swift
import SwiftMath
import SwiftUI

var mathImage = MathImage(
    latex: latex,
    fontSize: scaledFontSize,
    textColor: resolvedColor,
    labelMode: .text,
    textAlignment: .left
)

let (error, image, layout) = mathImage.asImage()

if error == nil, let image, let layout {
    Text(Image(uiImage: image))
        .baselineOffset(-layout.descent)
} else {
    Text(source)
}
```

`-layout.descent`는 검증할 가설이지 Apple이나 SwiftMath가 보장한 SwiftUI 공식이 아니다.
분수, 근호, 첨자, 합/적분, 행렬을 한글·영문·이모지 옆에 놓고 모든 Dynamic Type 크기에서
baseline 오차와 clipping을 측정한다.

### 블록 렌더

| 노드 | 기본 렌더 |
|---|---|
| 문단/헤딩 | inline 노드를 합친 `Text` |
| 리스트/인용 | 재귀 SwiftUI block renderer |
| block math | 가로 `ScrollView` 안의 수식과 원문 복사 버튼 |
| code block | 언어/복사 헤더와 가로 `ScrollView`의 monospace `Text` |
| thematic break | `Divider` |

메시지 전체의 세로 스크롤과 목록 virtualization은 소비 앱 책임이다.

### 접근성

- visual 수식 이미지는 동일한 원문 수식이 accessibility representation에 있을 때 decorative로 둔다.
- 링크가 있는 문단 전체에 하나의 `.accessibilityLabel`을 덮어써서 개별 link semantics를
  없애지 않는다.
- 접근성 표현은 텍스트, 링크, “수식: 원본 LaTeX”를 읽기 순서대로 제공한다.
- 코드/수식 복사는 native `Button`, 명확한 label/hint, 최소 44×44pt hit target을 사용한다.
- VoiceOver, Full Keyboard Access, 모든 Dynamic Type 단계, Bold Text,
  Increase Contrast, light/dark mode를 UI 테스트한다.

### 링크

- 자동 링크로 만드는 scheme은 `https`, `http`, `mailto`만 허용한다.
- 상대 URL과 다른 scheme은 v1에서 plain text로 표시한다.
- HTML을 실행하거나 URL로 변환하지 않는다.
- 허용된 링크는 native `OpenURLAction`을 거치므로 소비 앱의 환경 override를 존중한다.

### UIKit 호스팅

```swift
cell.contentConfiguration = UIHostingConfiguration {
    LatexMarkdownView(markdown: message)
}
```

`UIHostingConfiguration` 셀은 자체 크기 조정을 지원한다. UICollectionView layout이 고정
`itemSize`이면 잘릴 수 있으므로 estimated dimension을 사용하고, 비동기 콘텐츠·재사용·회전·
Dynamic Type 뒤 높이를 UI 테스트한다.

일반 화면은 `UIHostingController`를 사용한다. child containment는 `addChild`, Auto Layout,
`didMove(toParent:)` 순서를 지킨다.

### UIKit 네이티브 렌더러

`LatexMarkdownUIView`는 뷰 계층만 UIKit으로 구성하고 나머지는 SwiftUI 경로와 공유한다.

| 관심사 | SwiftUI | UIKit |
|---|---|---|
| 블록 배치 | `VStack` + `ForEach` | `UIStackView`(`alignment = .fill`) |
| 인라인 수식 | `Text(Image)` + `baselineOffset(-descent)` | `MathTextAttachment.attachmentBounds(...)`가 `-descent` 반환 |
| 블록 수식 | raster `Image` | **SwiftMath 벡터 뷰** (`BlockMathVectorView.make`) |
| 텍스트 | `Text` + `AttributedString` | `UITextView`(`isScrollEnabled = false`) + `NSAttributedString` |
| 폰트·색 출처 | `LatexTheme`의 `LatexFont` → `resolvedFont` | 같은 값 → `resolvedUIFont(compatibleWith:)` |
| Dynamic Type | `@ScaledMetric` 배율 × `LatexFont.unscaledSize` | `UIFontMetrics(compatibleWith: traitCollection)` |
| 색·scale | `@Environment(colorScheme/displayScale)` | `traitCollection` |
| 재렌더 트리거 | `.task(id:)` | `registerForTraitChanges`(iOS 17+) / `traitCollectionDidChange`(iOS 16) |
| 게시 구독 | `@StateObject` | `objectWillChange` + MainActor hop 1회 coalescing |

- 한 요청의 게시는 3회(document, mathImages 초기화, hydration)다. `objectWillChange`를
  다음 MainActor hop으로 미뤄 rebuild를 1회로 합친다.
- **rebuild는 증분이다** (2026-08-21, `Docs/RENDERING_PERFORMANCE_PLAN.md` §8.2).
  게시가 와도 블록 뷰를 전부 파괴하지 않는다.
  - 재사용 조건은 셋이다: ① 같은 index의 `ParsedBlock` 값이 같다 ② 그 블록이 이미지
    사전에서 찾아 쓴 수식 개수가 같다 ③ `AppearanceKey`(theme, 해석된 body/code
    `UIFont`, resolved 텍스트 RGBA, `displayScale`)가 같다. ③이 다르면 전량 재생성이다.
  - `AppearanceKey`에 `theme` 자체를 담는다. 인용 바 색처럼 Request에 실리지 않는
    필드는 파생 폰트·색만으로 구별되지 않는다.
  - **suffix 교체다.** 값이 처음 달라지는 index부터 뒤쪽 전부를 새로 만든다. 스트리밍은
    append 중심이라 앞쪽이 안정적이므로 중간 삽입 diff(LCS)는 구현하지 않는다.
  - **`document == nil` 게시(원문 fallback)에서 `renderedBlocks`를 비우지 않는다.**
    markdown이 바뀌면 model이 항상 `document = nil`을 먼저 게시하므로 스트리밍 append는
    매 갱신이 이 단계를 거친다. 여기서 비우면 재사용이 0이 된다. 뷰 인스턴스를 살려 두고
    계층에서만 떼어 다음 게시에서 앞쪽 블록을 그대로 되돌린다.
  - `addArrangedSubview`는 **계층에서 떼어낸 뷰에만** 호출한다. 이미 arranged인 뷰에
    다시 호출하면 순서가 바뀔 수 있다. 제거는 `removeArrangedSubview` +
    `removeFromSuperview` 짝으로 한다.
  - **원문 fallback 뷰도 인스턴스 하나를 재사용한다** (2026-08-21, 같은 문서 §9.5).
    스트리밍은 markdown 갱신마다 fallback 게시를 거치므로, 매 tick `UITextView`
    (TextKit 스택 통째)를 만들지 않고 `fallbackTextView` 하나에 attributed string만
    바꾼다. 텍스트 레이아웃 비용은 남는다 — 내용이 실제로 바뀌므로 피할 수 없다.
- **블록 수식은 벡터 뷰다** (2026-08-21, 같은 문서 §8.3). `BlockMathVectorView.make`가
  SwiftMath `MTMathUILabel`을 만들어 `UIView?`로 반환한다.
  - 반환 타입을 `UIView`로 둬서 SwiftMath 타입이 뷰 계층으로 새지 않는다 (§5 통제권:
    SwiftMath 호출은 `MathRenderService.swift` 한 파일에 가둔다).
  - 크기는 `intrinsicContentSize`로 **동기 확정**된다. 내부에서 typeset하므로 원문 →
    이미지 교체와 그에 따른 셀 self-sizing 재측정이 없다.
  - UIView다 — actor/worker에서 만들지 말 것. 생성·설정·측정 전부 main thread 전용이다.
  - 폰트는 `MathFont.mtfont(size:)`(`MTFontV2`)로 만든다. `MTFontManager`의
    `font(withName:size:)`는 legacy `MTFont(fontWithName:)` 경로로 `.otf`와 math table
    `.plist`를 직접 읽고 size가 캐시된 값과 다르면 매번 math table을 재구성한다(실측).
    raster 경로(`MathImage`)도 `mtfont(size:)`를 쓰므로, 같은 구현을 써야 인라인과
    블록의 글리프 메트릭이 어긋나지 않는다.
  - `label.fontSize`도 함께 맞춘다. 내부 세로 정렬(`_layoutSubviews`)이 쓰는 별도 저장
    값이고 기본값 20이 남으면 raster와 정렬 기준이 갈린다.
  - `displayErrorInline = false`는 `latex` 대입 **전에** 건다. 대입 시점에 내부
    errorLabel 표시 여부가 이 값으로 정해진다.
  - 실패(latex parse 오류·preflight 초과)는 기존과 같은 원문 fallback이다.
- 수식 attachment는 본문 텍스트로 읽히지 않는다. 수식이 있고 링크가 없는 문단은
  `LatexTextView.spokenOverride`로 합성 label을 주고, 이중 낭독을 막기 위해
  `accessibilityValue`를 비운다.
- 셀 재사용 환경에서는 hydration이 최초 레이아웃 뒤에 오므로 `onContentSizeChange`로
  self-sizing 재측정을 요청한다.
  - **`invalidateLayout()`만으로는 부족하다**(실측). compositional list layout은 이미 측정한
    셀에게 `preferredLayoutAttributesFitting`을 다시 묻지 않는다. 셀이 옛 높이에 묶여
    내용이 눌리고 텍스트가 겹치거나(긴 답변) 버블이 빈 채로 보인다(짧은 답변).
    `collectionView.performBatchUpdates(nil)`이 재측정을 강제하는 경로다.
  - **스크롤 중에는 batch update를 미룬다.** 드래그·감속 중에 호출하면 제스처를 방해해
    스크롤이 진행되지 않는다(UI 테스트가 왕복 스크롤에서 실패하며 드러났다).
    `isDragging`/`isDecelerating`을 확인하고 `scrollViewDidEndDragging`·
    `scrollViewDidEndDecelerating`에서 flush한다.
  - 새 markdown의 parse가 끝나기 전에는 **이전 문서가 그대로 보인다**. 스트리밍에서는
    의도된 동작(최신 원문 fallback)이지만 셀 재사용에서는 남의 메시지가 보이는 셈이다.
    데모는 첫 `onContentSizeChange`까지 뷰를 감춘다.
  - 기준 구현: `Examples/SwiftLatexDemo/Sources/UIKitChatDemo.swift`.
- 리스트 마커는 `alignment = .top`으로 고정한다. 중첩 `UIStackView`의 first baseline은
  안정적으로 노출되지 않는다.
- **`NSTextAttachment.bounds`에 넣은 값은 `UITextView`에 실린 뒤 `.zero`로 읽힌다**(실측).
  프로퍼티를 믿으면 baseline 보정이 조용히 사라진다. `MathTextAttachment`가
  `attachmentBounds(for:proposedLineFragment:glyphPosition:characterIndex:)`를 override해
  TextKit이 실제로 묻는 값을 답한다. 테스트도 프로퍼티가 아니라 이 메서드를 확인한다.
- **폰트는 반드시 뷰의 `traitCollection`으로 해석한다**(`compatibleWith:`). 앰비언트
  trait을 쓰면 `traitOverrides`를 건 뷰에서 색·displayScale만 따라오고 글자 크기는
  안 따라온다. `traitOverrides`는 window 계층에 붙은 뒤에만 반영된다(실측).
- 복사 버튼 아이콘은 `tintColor = theme.textColor`로 고정한다. `UIButton(type: .system)`
  기본 tint는 시스템 파랑이라 SwiftUI 렌더러(`.buttonStyle(.plain)`)와 색이 갈린다.

---

## 6. 입력 보호와 cache

### 입력 보호

- 원문 UTF-8 byte 상한은 첫 `Document(parsing:)` 전에 검사한다.
- 초과 시 내부 표시 상한까지 `Character` 경계로 자르고
  `… [입력 제한 초과]` marker를 붙인다.
- AST depth/node count는 parse 후 출력 비용을 제한할 뿐 parser DoS의 사전 방어라고
  주장하지 않는다.
- 수식 source byte/구문 복잡도는 `MathImage.asImage()` 호출 전에 제한한다.
- 내부 상한은 P0 adversarial fixture와 측정으로 정하며 v1 공개 API로 고정하지 않는다.

SwiftMath `1.7.3`의 `MathImage.asImage()`는 내부에서 raster 크기를 계산한 뒤 바로
`UIGraphicsImageRenderer`를 생성한다. 반환 이미지의 dimension을 사후 검사하는 것만으로는
OOM을 예방할 수 없다. 다음 중 하나를 P0에서 검증하기 전에는 raster dimension 제한을
보안 경계로 문서화하지 않는다.

1. allocation 전 크기를 얻는 public measure 경로
2. 실제 최악 입력에서 상한을 증명한 보수적 source/구조/font 제한
3. SwiftMath upstream의 public preflight API

### 수식 cache

cache key에는 다음 값을 포함한다.

- LaTeX source
- math font 식별자와 실제 point size
- resolved RGBA
- inline/display mode
- display scale

이미지 pixel byte를 cost로 사용해 `totalCostLimit`과 항목 수를 제한하고 memory warning에서
비운다. cache의 reference box는 actor 내부 전용 `final` class와 `let` 필드만 사용한다.
actor 밖에는 P0에서 Sendable 안전성을 확인한 immutable 결과만 반환한다.

**cache 소비자 (2026-08-21)** — key 구성은 그대로지만 조회하는 쪽이 갈렸다.

| 렌더러 | 인라인 수식 | 블록 수식 |
|---|---|---|
| SwiftUI (`LatexMarkdownView`) | raster cache | raster cache |
| UIKit (`LatexMarkdownUIView`) | raster cache | **벡터 뷰 — cache 미사용** |

`MathRenderKey`는 벡터 경로에서도 그대로 쓴다. 이미지를 찾기 위해서가 아니라
**같은 preflight 상한과 같은 폰트·색·mode 해석을 공유**하기 위해서다
(`MathRenderService.preflightAllows(_:)`). 동기 typeset도 병리적 입력에서는 main을
오래 잡으므로 raster와 상한을 나누지 않는다.

렌더러별 raster 범위는 `Request.rastersDisplayMath`(기본 true)가 정한다 (2026-08-21).
UIKit 뷰는 false를 보내 display segment를 raster 대상에서 제외한다 — 블록 수식
raster를 아무도 읽지 않는 낭비가 없다. SwiftUI 렌더러는 기본값이라 무변경.
블록 수식만 있는 문서는 기다릴 raster가 없어 단일 게시(publishComplete)로 끝난다.

---

## 7. 구현 순서와 Definition of Done

### P0 — 기술 spike

- Xcode `26.6 (17F113)`에서 exact SwiftMath `1.7.3`, swift-markdown `0.4.0` 조합 컴파일 (완료 — 1.7.2는 컴파일 불가)
- 지원하려는 최소 Xcode로 같은 consumer build를 실행해 실제 최소 toolchain 확정
- code/HTML/link 금지 범위와 수식 보호/복원 parser prototype
- 동일 UTF-8 byte 길이 mask와 다국어 source range property test
- Markdown 기호를 포함한 LaTeX와 다국어 UTF-8 source range fixture
- `Text(Image:)` baseline, Dynamic Type, accessibility representation spike
- SwiftMath raster preflight와 이미지 Sendable/isolation 경로 확정
- deployment target 16 consumer compile과 현재 최소 runtime(iOS 18.6) 선택/복사 동작 기록
- iOS 16 실행 지원을 선언하려면 호환 Xcode/runtime 또는 실기기 검증 환경 별도 확보
- 최소 `Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj`, UI-test target,
  shared scheme/test plan 생성
- 스트리밍 baseline 측정 환경과 P1 합격 수치 확정 (완료 — 아래 측정 기록)

### P0 측정 기록 (2026-08-19)

환경: Apple Silicon macOS 호스트, iPhone 16 Pro simulator, iOS 18.6, Debug, Xcode 26.6.

- 50 KiB fixture parse (30회): p50 128–136ms, p95 191–230ms, max ~456ms
- 10Hz × 30초 스트리밍 (300 ticks, 전체 String prefix 갱신):
  - 실제 경과 36.5초 (유효 ~8.2Hz, MainActor 부하에 의한 sleep 지연 — coalescing이 흡수)
  - 입력 종료 후 idle: 25–26ms (outstanding 0 도달)
  - 최종 게시 = 최신 제출, 고유 수식 4개 전부 hydration
- P1 gate (측정값 대비 여유 반영, `StreamingBaselineTests`):
  - 50 KiB parse p95 < 300ms
  - 입력 종료 후 idle < 3초
- MainActor 검증: worker off-main 실행 테스트(`OffMainExecutionTests`) +
  signpost `dev.swiftlatex`/`parse`·`raster` (Instruments 확인용)
- 30초 전체 측정 재실행: `TEST_RUNNER_SWIFTLATEX_STREAM_SECONDS=30 xcodebuild test
  -scheme SwiftLatex -only-testing:SwiftLatexTests/StreamingBaselineTests ...`

### 데모 앱 (2026-08-19)

`Examples/SwiftLatexDemo`는 LLM 챗봇 형태의 화면을 제공한다. 한 화면을 스크롤하며
v1 렌더 계약 케이스를 눈으로 확인하는 것이 목적이다.

- 질문/답변 쌍 13개, 답변마다 확인 대상 케이스를 라벨로 표시
- 커버 케이스: 인라인 수식 baseline, 블록 수식(가로 스크롤·복사), 큰 구조(행렬),
  코드 블록(언어 라벨·긴 줄), 헤딩/리스트/인용/구분선, 링크 allowlist,
  금지 문맥(코드·링크·HTML) 보호, Markdown 기호 포함 수식, dollar math opt-in과
  통화 표기, 실패 시 원문 표시, 다국어·결합 문자·RTL, 미지원 노드(표) 강등, 긴 답변
- 우측 상단 메뉴에서 `$` 수식 파싱 opt-in을 켜고/끄고 비교할 수 있다
- UIKit `UIHostingConfiguration` 화면은 같은 답변 fixture를 셀로 렌더한다

### P2 검증 기록 (2026-08-19)

`SwiftLatexDemoP2UITests`로 자동화 (iPhone 16 Pro, iOS 18.6 simulator):

- Dynamic Type: L / AccessibilityXXXL 양 극단 렌더 확인
- dark mode(launch arg `-swiftlatexDark`), 회전(landscape 왕복)
- `UIHostingConfiguration` 셀 재사용: 왕복 스크롤 후 콘텐츠 유지
- 수식 접근성 label("수식: <LaTeX>") 노출 확인
- 복사 버튼: 존재·hittable·44×44pt 확인 (UI 테스트) +
  pasteboard 내용 일치 확인 (`CopyActionTests`, 앱 프로세스)
- `performAccessibilityAudit(for: .all.subtracting(.dynamicType))` (iOS 17+)

### 데모 화면 캡처 검증에서 잡아낸 결함 (2026-08-19)

챗봇 화면 전체(22장)를 스크롤 캡처해 눈으로 확인한 결과:

1. **기울임·취소선이 적용되지 않음** — `Text`를 `+`로 합치면 `Text.italic()`과
   `Text.strikethrough()`가 사라진다(`.bold()`만 남는다). 문단은 수식·코드·링크
   런 때문에 항상 합성 `Text`라 두 스타일이 항상 유실됐다.
   → 기울임·취소선은 `AttributedString.inlinePresentationIntent`로 준다.
   굵게는 `Text.bold()`를 유지한다. bold를 intent로 함께 주면 italic과 겹칠 때
   한글처럼 italic 변형이 없는 폰트에서 굵기까지 잃는다(`**굵게 안의 *기울임***`
   에서 실측).
2. **Markdown escape가 해제되지 않음** — 2차 파싱 Text 노드를 원문 slice로
   되돌려 쓰기 때문에 파서의 escape 해제가 사라졌다. `\$100`이 백슬래시째
   표시됐다.
   → span 밖 텍스트에 `unescapingMarkdownPunctuation()`을 적용한다. 수식 span
   source와 코드 span은 backslash를 그대로 보존한다.
3. **audit `Text clipped`는 오탐** — 지적된 요소(문단 텍스트, HTML 리터럴)의
   스크린샷을 확인한 결과 전체가 표시되고 잘림이 없었다. 합성 `Text` 문단의
   접근성 프레임 측정이 어긋나는 것으로 보인다. audit에서 제외하고 근거를 남겼다.

알려진 플랫폼 제약: **한글은 시스템 폰트에 italic 변형이 없어 기울임이 시각적으로
적용되지 않는다.** 영문·숫자에는 적용된다. 파서는 두 경우 모두 italic 플래그를
정상적으로 싣는다(`emphasisFlagsAreCarriedOnRuns`).

P2에서 UI 테스트가 잡아낸 실제 결함과 수정:

1. **링크 대비 미달** — 시스템 블루(#007AFF)는 흰 배경에서 약 3.6:1로 본문
   기준(4.5:1) 미달. audit `Contrast nearly passed`로 검출됨.
   → `LatexTheme.linkColor` 추가(기본 `Color.accessibleLink`, light 약 7.5:1 /
   dark 약 8.9:1)와 밑줄(색 외 구분 수단) 적용.
2. **복사 버튼이 앱 idle을 붙잡음** — 아이콘 교체로 버튼 폭이 변해 가로
   `ScrollView`가 재측정되고 XCUITest "wait for app to idle"이 풀리지 않았다.
   → 버튼을 고정 44×44pt 프레임으로 변경. 타이머 기반 자동 복귀도 제거했다.
3. **audit dynamicType 오탐** — 수식 raster 이미지는 크기가 고정이지만
   `@ScaledMetric` point size로 매번 다시 렌더된다(실제 확대는
   `testDynamicTypeExtremes`가 검증). audit에서 `dynamicType`만 제외했다.
4. **러너 프로세스 pasteboard 읽기 금지** — 시스템 권한 프롬프트가 뜬다.
   → pasteboard 검증은 앱 프로세스 unit test(`CopyActionTests`)로 이동.
5. **중첩 delimiter 안쪽이 수식으로 승격됨** — 챗봇 데모 화면에서 발견.
   `\(a \(b\) c\)`에서 바깥 구간을 plain text + diagnostic으로 처리한 뒤
   스캔 위치를 여는 delimiter 뒤로만 옮겨, 안쪽 `\(b\)`가 별도 수식으로 렌더됐다.
   문서 계약("중첩 delimiter는 plain text와 내부 diagnostic")과 충돌.
   → 중첩·빈 구분자는 닫는 delimiter 뒤로 건너뛴다. 미완성 구분자는 같은 줄의
   다른 후보를 놓치지 않도록 여는 delimiter 뒤부터 계속 탐색한다.
   닫는 delimiter 앞에 opener가 또 있으면 미완성이 아니라 중첩으로 판정한다.

UI 테스트는 app launch가 회당 7~8초라 검증 항목을 launch 단위로 묶는다
(기본 구성 / dark / Dynamic Type / collection = 3 테스트, 5 launch).

남은 수동/별도 환경 항목:

- iOS 16 실행 검증 — 호환 Xcode/runtime 또는 실기기 필요 (이 환경에 없음)
- Bold Text / Increase Contrast / Full Keyboard Access — launch argument로
  제어 불가, simctl 설정 또는 수동 검증 필요 (contrast는 audit이 일부 대체)
- VoiceOver 실제 읽기 순서 청취 검증

완료 조건: 위 결과와 충돌하는 설계 문구를 수정한 뒤에만 P1 API를 고정한다.

### P1 — 최소 v1 구현

- package-scoped parser/model/diagnostic과 fail-open 정책
- Markdown 기본 블록/인라인, 수식, plain 코드 블록
- 2단계 게시와 latest-wins coordinator
- 수식 cache와 P0에서 확정한 입력/raster 제한
- system text selection, link allowlist, 접근성 표현
- SwiftUI 예제와 Foundation Core 테스트

완료 조건:

- Core line coverage 80% 이상
- parser property/fixture, stale-generation/out-of-order, cache limit 테스트 통과
- strict concurrency build와 MainActor stall signpost 기준 통과
- P0에서 확정한 스트리밍 회귀 기준 통과
- invalid/malformed/제한 초과 fixture가 정의한 fallback으로 표시됨

### P2 — 플랫폼 검증과 출시

- `UIHostingConfiguration` collection/table sample
- `UIHostingController` 일반 화면 sample
- 셀 재사용, async 높이 갱신, 회전, Dynamic Type UI 테스트
- VoiceOver/Keyboard/Contrast 접근성 audit
- P0 demo harness에 collection/table, lifecycle, 접근성 UI test 추가
- README 사용 예제, 지원 matrix, dependency license notice

완료 조건: 아래 테스트와 CI 조건을 모두 충족한다.

---

## 8. 테스트와 CI

### parser/보안 fixture

- `\(...\)`, `\[...\]`, opt-in `$`, `$$`, escape, 빈/미완성 delimiter
- `$5`, `$5 and $10`, 닫는 `$` 뒤 숫자, 인접 `$$`
- Markdown 기호가 든 수식: `\(a * b\)`, `\(x_[i]\)`, link-like source
- backtick 길이, tilde fence, indented code, HTML, link/image 내부 delimiter
- byte-length-preserving mask와 다국어 수식 앞뒤 source range
- 한글, 이모지, 결합 문자, RTL의 UTF-8 offset
- protect/restore byte round-trip property/fuzz test
- 과대 입력, 깊은 Markdown, 많은 노드, 복잡한 수식의 fallback

### 비동기/cache 테스트

- parse 전/후와 수식 block 사이의 stale generation 중단
- out-of-order 완료가 최신 generation을 덮지 않음
- stale generation 결과가 cache에 들어가지 않음
- 10Hz 입력에서 최대 동시 실행이 `1`, 최신 대기가 `1`보다 늘지 않음
- 입력 종료 후 정한 idle 시간 안에 outstanding task가 `0`이 됨
- font, size, color, mode, scale별 cache key
- cost/count limit과 memory warning 정리
- MainActor에서 CPU parse/raster가 실행되지 않는지 signpost 검증

### 렌더/UI 테스트

- 대표 수식군 baseline과 clipping 허용 오차
- light/dark, 모든 Dynamic Type, Bold Text, Increase Contrast
- 한글/영문/이모지/RTL
- VoiceOver 읽기 순서, link semantics, 복사 버튼, Full Keyboard Access
- 시스템 선택/복사 결과
- collection/table reuse, 비동기 높이 변경, 회전

### CI 원칙

- Foundation-only Core는 host에서 `swift build --target SwiftLatexCore`로 우선 검증한다.
- host에서는 Core target만 build한다. Core를 포함한 전체 unit test는 iOS Simulator의
  Swift Package scheme에서 실행한다.
- UIKit lifecycle/UI test는 `Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj`의
  shared scheme/test plan으로 실행한다.
- macOS host의 일반 `swift test`를 UIKit target 검증 근거로 사용하지 않는다.
- P0에서 CI simulator 기기/OS와 실제 package/demo scheme 이름을 고정하고 해당
  `xcodebuild test -destination ...` 명령을 README에 기록한다.
- 최소 지원 toolchain/고정 의존성 조합과 현재 검증 toolchain/승인 의존성 조합을 분리한다.
- 현재 toolchain job은 Swift 6 language mode와 complete concurrency를 함께 켠다.
- Swift 6 mode가 없는 최소 toolchain job은 complete concurrency + warnings-as-errors로 분리한다.
- Core line coverage 80%와 license/notice 검사를 gate로 둔다.

P0가 scheme을 만든 뒤 현재 로컬 최소 runtime에서는 다음 형태를 실제 실행해 이름과 옵션을
고정한다. 빌드 출력은 파일로 보내고 exit code로 판정한다.

```bash
swiftlatex_results_dir=$(mktemp -d /tmp/swiftlatex-results.XXXXXX)

swiftlatex_package_status=0
# P0 확정: package scheme의 실제 이름은 `SwiftLatex`다.
# Swift 6 mode/strict concurrency는 tools 6.0 manifest가 적용한다. 전역
# SWIFT_VERSION=6 / WARNINGS_AS_ERRORS override는 의존성까지 재컴파일하므로 쓰지 않는다.
xcodebuild test \
  -scheme SwiftLatex \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -resultBundlePath "$swiftlatex_results_dir/package.xcresult" \
  -enableCodeCoverage YES \
  > /tmp/swiftlatex-package-tests.log 2>&1 || swiftlatex_package_status=$?

swiftlatex_demo_status=0
xcodebuild test \
  -project Examples/SwiftLatexDemo/SwiftLatexDemo.xcodeproj \
  -scheme SwiftLatexDemo \
  -testPlan SwiftLatexDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -resultBundlePath "$swiftlatex_results_dir/demo.xcresult" \
  -enableCodeCoverage YES \
  > /tmp/swiftlatex-demo-tests.log 2>&1 || swiftlatex_demo_status=$?

swiftlatex_coverage_status=0
xcrun xccov view --report --json \
  "$swiftlatex_results_dir/package.xcresult" \
  > "$swiftlatex_results_dir/package-coverage.json" || swiftlatex_coverage_status=$?
xcrun simctl shutdown all
test "$swiftlatex_package_status" -eq 0 \
  && test "$swiftlatex_demo_status" -eq 0 \
  && test "$swiftlatex_coverage_status" -eq 0
```

iOS 16 실행 검증은 호환 Xcode/runtime 또는 실기기 환경에서 같은 test plan으로 별도 수행한다.
P1에서 coverage JSON의 `SwiftLatexCore` line coverage가 `0.80` 미만이면 nonzero로 종료하는
검사 script를 함께 추가한다. `-enableCodeCoverage YES`만으로 합격 처리하지 않는다.
