# Changelog

이 프로젝트는 [Semantic Versioning](https://semver.org/lang/ko/)을 따른다.
`0.x`는 베타이며 minor 버전에서 공개 API가 바뀔 수 있다.

## [Unreleased]

## [0.7.0] - 2026-09-14

### 추가

- **코드 블록 확장점 `LatexCodeBlockOptions`.** 코드 블록에 색 범위를 주거나, 특정 언어의 코드
  블록을 통째로 다른 뷰로 바꾸는 두 가지 확장을 주입한다. SwiftUI `.latexCodeBlocks(_:)`,
  UIKit `LatexMarkdownUIView.codeBlocks`. 주입하지 않으면 기존 plain monospace 그대로다.
  - 코어(`SwiftLatex`)에 들어간 것은 프로토콜 `LatexSyntaxHighlighting`·`LatexDiagramRendering`,
    값 타입 `LatexHighlightSpan`·`LatexHighlightKind`, 주입 지점 하나뿐이다. **JavaScriptCore도
    WebKit도 링크하지 않는다.**
  - 범용 custom renderer API는 여전히 만들지 않는다. 확장점은 이 두 가지로 한정한다.
- **`SwiftLatexHighlight` product — Prism 1.30.0 + JavaScriptCore.** `PrismHighlighter`가 번들에
  고정한 Prism을 `JSContext`에서 실행해 UTF-16 범위 + 역할을 돌려준다. WebView와 HTML 변환을
  쓰지 않는다.
  - 문법 16종: swift, javascript, typescript, jsx, tsx, python, json, bash, kotlin, java, c,
    cpp, go, rust, sql, yaml, css, markup. Prism이 등록하는 별칭(`js`·`py`·`sh`·`yml` 등)에
    더해 `c++`·`rs`·`golang`·`zsh`·`postgres` 같은 이름을 보완 매핑한다.
  - 사용자 코드는 `evaluateScript`에 이어 붙이지 않고 JS 함수의 **문자열 인자**로만 전달한다.
  - 토큰 조각을 이어 붙인 결과가 원문과 한 글자라도 다르면 범위 **전체**를 버린다. 미지원 언어,
    Prism 예외, UTF-16 100,000 단위 초과는 모두 빈 배열이며 원문이 그대로 표시된다.
  - 색은 늦게 와도 된다. 먼저 plain으로 그리고 도착한 범위의 **색만** 바꾸므로 코드 블록 크기가
    달라지지 않는다. 스트리밍 중 원문이 바뀌면 이전 범위를 버려 위치가 밀린 색을 보여 주지 않는다.
- **`SwiftLatexMermaid` product — 공식 Mermaid 11.17.2 + WKWebView.** `MermaidDiagramRenderer`를
  주입하면 ` ```mermaid ` 코드 블록이 공식 Mermaid가 그린 다이어그램으로 바뀐다. 헤더의 언어
  라벨과 복사 버튼은 남아 원문을 항상 가져갈 수 있다.
  - `MermaidDiagramView`(SwiftUI)·`MermaidDiagramUIView`(UIKit)·`MermaidWebRenderer`를 직접 쓸 수도 있다.
  - 로컬 번들 파일만 로드한다. `securityLevel: 'strict'`, CSP `connect-src 'none'`, 링크 실행·외부
    이동 차단, 런타임 다운로드 없음. 원문은 `callAsyncJavaScript`의 인자다.
  - 원문 UTF-8 20,000바이트·`maxEdges` 200·표시 높이 4,000pt 상한. 문법 오류와 크기 초과는
    오류 한 줄 + 원문 코드로 되돌린다.
  - 모든 다이어그램 WebView가 `WKProcessPool` 하나를 공유해 3 MB가 넘는 번들을 매번 새 콘텐츠
    프로세스에서 다시 컴파일하지 않는다.
  - 번들 재생성은 `Sources/SwiftLatexMermaid/Web`(`npm ci && npm run build`). 서드파티 고지
    64개 패키지를 함께 배포한다.
- **`LatexTheme.syntax` (`LatexSyntaxColors`).** 신택스 색 7역할(keyword·string·comment·number·
  type·function·property). 기본값은 light/dark를 담은 동적 색이며 코드 블록 배경 위에서 본문
  대비 기준(4.5:1)을 넘는다. `LatexSyntaxColors.dynamic(light:dark:)`로 교체한다.
- **데모 화면 「코드 블록 확장 (Mermaid · Prism)」.** SwiftUI/UIKit 렌더러를 바꿔 가며 두 확장을
  켜고 끈다.
- **[Docs/CODE_BLOCK_EXTENSIONS.md](Docs/CODE_BLOCK_EXTENSIONS.md).** 설계, 번들 원본 주소와
  SHA-256, 토큰→역할 매핑, 언어 별칭, 실패 fallback, 표시 한계.

### 변경

- **`DEVELOPMENT.md §1` 비목표에서 「신택스 하이라이팅」·「Mermaid」·「WebView」를 제거**하고 별도
  opt-in product로 옮겼다. `SwiftLatex` product 자체의 의존성 경계는 그대로다.
- **테스트 scheme 이름.** product가 4개로 늘면서 test action을 가진 package scheme이
  `SwiftLatex-Package`가 됐다. 같은 이름의 `SwiftLatex` scheme은 library 빌드 전용이라
  `xcodebuild test -scheme SwiftLatex`는 "not currently configured for the test action"으로 실패한다.
  `scripts/ci-test.sh`와 README의 명령을 갱신했다.

### 수정

- `MermaidDiagramUIView`는 `window != nil`일 때만 렌더를 시작한다. WKWebView는 window에 붙기
  전에는 콘텐츠 프로세스를 띄우지 않아 `didFinish`가 오지 않고 15초 뒤 timeout으로 실패한다(실측).
  `didMoveToWindow`에서 다시 예약하고, WebKit 콘텐츠 프로세스가 종료된 경우에만 한 번 재시도한다.

## [0.6.0] - 2026-09-04

### 추가

- **`LatexDollarMathOptions`.** dollar 수식 범위를 OptionSet으로 조합한다. `.single`은 기존
  `parsesDollarMath: true`(inline `$...$` + paragraph 전체 `$$...$$`)와 같고, **`.inlineDouble`**을
  더하면 **문장 안 `$$...$$`도 inline 수식**으로 해석한다 — LLM 출력과 콘텐츠 서버 데이터가
  `총합($$f(1)$$)`처럼 쓰는 표기다. 공백·숫자·줄바꿈 규칙은 `$...$`와 같아 `$$5 and $$6`은 텍스트로
  남고, paragraph 전체를 감싼 `$$...$$`는 그대로 block 수식이다.
  - SwiftUI `LatexMarkdownView(markdown:dollarMath:)`, UIKit `LatexMarkdownUIView.dollarMath`(및
    `init(markdown:dollarMath:theme:)`), `LatexInlineMathScanner.scan(_:dollarMath:excluding:)`.
  - 기존 `parsesDollarMath: Bool` API는 모두 유지된다(`[.single]`로 대응). `LatexMarkdownUIView.parsesDollarMath`는
    `dollarMath`의 `.single` 비트를 읽고 쓴다.
  - 스트리밍 미닫힌 마크 억제(`.latexStreaming`)는 `.inlineDouble`일 때 tail의 짝 없는 `$$` opener도 숨긴다.
  - parse cache key가 옵션 조합을 구분한다. 회귀 방지: `MathScannerFixtureTests` inline `$$` 6건,
    `StreamingTailTests.doubleDollarOpenerIsHiddenOnlyWithInlineDoubleOption`, `DollarMathOptionsTests`.

## [0.5.0] - 2026-09-04

### 추가

- **스트리밍 표시 옵션 `LatexStreamingOptions`.** SwiftUI `.latexStreaming(_:)` modifier와 UIKit
  `LatexMarkdownUIView.streaming` 프로퍼티로 스트리밍 중인 **메시지 뷰 하나**에만 건다(`nil` = 현행
  렌더). parse 요청·cache key는 바꾸지 않으므로 스트림 종료 시 수식 이미지가 무효화되지 않는다.
  - **꼬리 페이드**: tail 문단(마지막 리프 문단·헤딩)의 마지막 N grapheme(기본 12) alpha를 끝으로
    갈수록 0.2까지 낮춰 도착 위치를 보인다. 마지막 grapheme은 길이와 무관하게 항상 0.2라 tick마다
    흔들리지 않는다. break·수식·코드·링크에서 멈춘다.
  - **미닫힌 인라인 마크 억제**: tail 문단 마지막 text run의 짝 없는 `**`·`*`·`~~`·백틱·`\(`
    (그리고 `parsesDollarMath`일 때 `$`)를 closer가 도착할 때까지 숨긴다. swift-markdown이 literal로
    내보내던 `**제가 선생님처` 같은 원문 노출이 사라진다. 문단 전체가 비는 억제는 건너뛴다.
  - 두 렌더러가 `SwiftLatexCore.StreamingTail`(순수 함수)로 같은 결과를 그린다. 숨긴 마크는 접근성
    라벨·인라인 코드 칩 판정에서도 빠진다.
- **`LatexStreamingTextBuffer`.** 토큰 도착 속도와 화면 갱신을 분리하는 latest-wins 버퍼(기본
  100ms). 간격 안 갱신은 마지막 값만 남기고 **trailing 게시 1회**로 흘려 보낸다 — 데모의 도착
  이벤트 기반 throttle에 없던 마지막 조각 게시가 보장된다. `update`/`append`/`flush`/`reset`.

### 수정

- **스트리밍 append parse를 `ParseCache`에 넣지 않는다.** tick마다 누적 원문 전체가 새 키가 되어
  (10Hz × 30초 ≈ 300건) 다른 셀의 항목을 밀어냈고, 그 키는 다시 조회되지 않았다. 스트림의 첫
  제출(교체)만 저장한다. 회귀 방지: `streamingAppendDoesNotStoreParseCacheEntry`.
- **UIKit 렌더러가 스트리밍 중 텍스트 블록을 in-place로 갱신한다.** 같은 종류(문단↔문단, 같은
  레벨 헤딩)면 `LatexTextView` 인스턴스를 유지하고 attributed string만 바꾼다 — tick마다 TextKit
  스택을 버리지 않고, tail만 바뀌는 일반적인 tick에서는 읽던 문단의 VoiceOver 포커스도 유지된다.
  백틱이 나중에 닫히면 인라인 코드 칩
  장식을 그 자리에서 설치한다. `streaming == nil`이면 기존 재사용 정책 그대로다.

## [0.4.1] - 2026-08-28

### 추가

- **데모에 `SSE 실시간 렌더링` 화면.** `text/event-stream` 프레임을 디코딩해 누적
  문자열을 `LatexMarkdownView`에 계속 넘기는 스트리밍 확인 화면
  (`Examples/SwiftLatexDemo/Sources/SSEDemo.swift`). 패키지 API는 바뀌지 않았다.
  - `SSELineSplitter` — 바이트를 SSE 줄로 나눈다. `URLSession.AsyncBytes.lines`는
    **빈 줄을 건너뛰어** 이벤트 경계가 사라지므로 쓰지 않는다(실측). LF·CRLF·CR과
    선두 BOM을 처리하고 한 줄 상한(64 KiB)으로 무한 버퍼링을 막는다.
  - `SSEDecoder` — W3C EventSource 부분집합(`data` 누적, 주석, `[DONE]`)의 동기 상태 머신.
    OpenAI `choices[0].delta.content`(문자열·content-part 배열)와 `choices[0].text`,
    Anthropic `delta.text`, OpenAI Responses `delta`, 순수 텍스트 payload를 받고,
    서버 오류 payload는 `failure` 이벤트로 올린다. 잘린 JSON 조각은 답변에 섞지 않는다.
  - 엔드포인트가 비면 fixture를 SSE 프레임으로 만들어 5/20/60Hz로 흘리고(네트워크 불필요),
    넣으면 `URLSession.bytes`로 실제 스트림을 읽는다(GET·바디 없음, `Content-Type` 검증,
    누적 256 KiB 상한). 두 경로가 같은 분리기·디코더를 쓴다.
  - **도착 속도와 화면 갱신 속도를 분리**했다. 도착한 델타를 모아 약 10Hz로만 반영한다 —
    매 청크 갱신 + `scrollTo`는 스크롤 레이아웃을 그 빈도로 강제해 메인 스레드를 포화시키고,
    렌더 게시가 매번 stale 판정을 받아 화면이 원문에 고착했다(실측: 20Hz에서 스트림이
    끝날 때까지 렌더 미착지, 접근성 쿼리 응답 4초 이상).
  - UIKit 화면 «SSE 실시간 렌더링 (UIKit)» — 같은 디코더·전송 로직을 UIKit 네이티브
    `LatexMarkdownUIView`로 배선(`UIKitSSEDemo.swift`). 기존 화면은
    «SSE 실시간 렌더링 (SwiftUI)»로 개명.
  - 회귀 방지: `SSEDecoderTests`·`SSELineSplitterTests` 25건(바이트→줄→디코더 왕복,
    빈 줄 보존, BOM, Character 경계 청크), UI 테스트
    `testSSEDemoRendersWhileStreaming`(스트리밍 중 표 셀 렌더 착지),
    `testSSEDemoStreamsAndStops`(중지 후 청크 누적 정지),
    `testUIKitSSEDemoRendersWhileStreaming`(UIKit 렌더러 스트리밍 렌더).

### 수정

- **스트리밍 append가 더 이상 원문 fallback으로 되돌아가지 않는다.** 누적 문자열을
  다시 넘길 때(새 markdown이 표시 중 문서의 prefix 확장) 렌더 모델이 이전 문서와
  수식 이미지를 새 parse 게시까지 유지한다. 이전에는 매 갱신 문서 전체가
  원문 ↔ 렌더를 오가며 출렁였다(SSE 데모 실측). 셀 재사용(다른 문자열로 교체)은
  기존대로 즉시 fallback을 게시해 이전 문서가 한 프레임도 되살아나지 않는다.
  캐시된 수식 raster는 1단계 게시에서 즉시 hydration한다(부분 hydration) — 이미
  raster된 수식이 원문으로 되돌아가는 프레임도 함께 사라졌다.
  두 렌더러(SwiftUI `LatexMarkdownView`, UIKit `LatexMarkdownUIView`) 공통
  (`DEVELOPMENT.md` §4 계약 개정, `Docs/RENDERING_PERFORMANCE_PLAN.md` §9.5).

## [0.4.0] - 2026-08-25

### 추가

- **신규 product `SwiftLatexBlockEditor`.** demo에만 있던 Notion 스타일 블록 편집기를
  package로 이동했다 (`Docs/DEMO_REUSE_CANDIDATES.md`의 발굴 결과 구현).
  - `EditorBlock`/`EditorBlockKind`/`InlineMark`/`BlockEditorModel` — 순수 로직 엔진.
    markdown↔블록 왕복 파싱, 블록↔문서 UTF-16 좌표 변환, undo/redo, 인라인 서식 토글.
  - `InlineMarkdownCodec` — LaTeX 구간을 보호하는 인라인 markdown 파서/직렬화기 (public 승격).
  - `BlockDocumentTextEditor` — TextKit 2 단일 문서 투영 편집기. 한글 IME composition
    reconcile, diff 기반 변경 복원, 수식 attachment 경계 보정 포함.
  - `MarkdownStyler` — demo 전용 preset 결합을 해소하고 `LatexTheme`만 받는다.
    폰트는 `bodyFont`/`headingFont(level:)`/`codeFont`에서 해석한다.
  - `BlockDocumentPasteboardPayload` — 구조 보존 복사/붙여넣기 payload. pasteboard type을
    `com.swiftlatex.block-document`로 개명했다 (demo 접미사 제거).
  - 키보드 툴바는 package에 포함하지 않는다 — `BlockEditorInputAccessory` 주입점만 열고
    구체 UI(`BlockKeyboardToolbar`)와 블록 표시 문자열(`title`/`systemImage`)은 demo에 남긴다.
- **`EquationTextAttachment` 공개.** `UITextView`(TextKit 2) 문서 흐름 안에 수식을
  라이브 뷰로 배치하는 attachment를 `SwiftLatex`로 이동했다. 블록 에디터 없이도
  attributed string 파이프라인에 수식을 끼울 수 있다.
- **`LatexFont.resolvedUIFont(compatibleWith:)` 공개.** `LatexTheme`의 폰트를 UIKit
  attributed string으로 옮기는 외부 렌더러용 (additive).

- **Notion 스타일 인용문.** 블록 에디터 인용문이 보조 색 텍스트 대신 본문 색 +
  왼쪽 세로 바(`LatexTheme.quoteBar`, 3pt 둥근 바)로 렌더된다. 바는 공개 attribute
  `.blockQuoteBar`(`QuoteBarStyle`)를 읽는 `QuoteBarDecorationView`가 TextKit 2
  segment 좌표로 텍스트 뒤에 그린다 — 인라인 코드 칩과 같은 `CAShapeLayer` 패턴이라
  문자 삽입 없이(UTF-16 offset 계약 유지) 연속 인용 블록에 이어진 바 하나를 그린다.

- **Notion 스타일 할 일 체크박스.** 시스템 마커 글리프(`.box` 채워진 사각형,
  `.check` 박스 없는 체크) 대신 미완료는 둥근 테두리 박스, 완료는 액센트(tint) 채움 +
  흰 체크로 그린다. 완료 항목 텍스트는 흐린 색 + 취소선. 할 일 블록은 NSTextList를
  쓰지 않는다 — 마커 글리프가 취소선을 상속해 박스 위로 선이 그려지므로 수동 indent로
  자리만 확보하고, 박스는 공개 attribute `.toDoCheckbox`(`ToDoCheckboxStyle`)를
  읽는 `ToDoCheckboxDecorationView`가 그린다 — 칩·인용 바와 같은 데코레이션 패턴.

- **블록 정렬 주입.** `BlockAlignmentConfiguration`(code 기본 좌측 `.natural`,
  equation 기본 중앙)을 `MarkdownStyler.styledDocument`/`typingAttributes`와
  `BlockDocumentTextEditor(blockAlignment:)`에 주입할 수 있다. 코드 블록 정렬은
  명시적으로 좌측이 기본이 됐고, 수식 블록의 중앙 정렬 하드코딩이 제거됐다.

- **렌더러 블록 수식 정렬.** `LatexTheme.equationAlignment`
  (`LatexEquationAlignment` — leading/center/trailing, 기본 leading으로 기존 동작
  유지) 추가. SwiftUI·UIKit 렌더러의 블록 수식이 뷰포트보다 좁을 때 지정 방향으로
  정렬되고, 넓으면 기존처럼 가로 스크롤한다.

### 수정

- **줄 끝 인라인 수식이 잘리던 문제.** `EquationTextAttachment`가 폭을 남은 공간
  (`proposedLineFragment.width - position.x`)으로 clamp해, 줄 끝에 놓인 수식을 실제보다
  좁게 보고했다. TextKit은 "들어간다"고 판단해 줄을 바꾸지 않고 수식은 그 좁은 폭에
  잘려 그려졌다. 줄 전체 폭을 기준으로 clamp해 안 들어가는 수식은 다음 줄로 내려간다.

### 데모

- **수식 Attachment (읽기 전용) 화면 추가.** `EquationTextAttachment` 직접 배치와
  `MarkdownStyler.styledDocument` 읽기 전용 렌더를 세그먼트로 비교한다. 이동한
  public API의 단독 사용 경로(블록 에디터 없이)를 화면으로 확인할 수 있다.

## [0.3.0] - 2026-08-24

### 추가

- **GFM 표.** `swift-markdown`의 Table AST를 보존해 SwiftUI는 `Grid`, UIKit은
  `UIStackView` 격자로 렌더한다. 헤더, 테두리, 좌·중앙·우 정렬, 셀 안의 강조·링크·
  인라인 코드·수식을 지원하며 좁은 화면에서는 가로 스크롤한다. 32열 또는 512셀을
  넘는 표는 뷰 폭증을 막기 위해 읽을 수 있는 plain text로 낮춘다.

- **Notion 스타일 인라인 코드 칩.** 배경색만 바뀌던 인라인 코드가 둥근 모서리·테두리
  배경 + 강조색 텍스트로 렌더된다.

- **단독 UIKit 수식 뷰.** Markdown chrome 없이 수식 하나만 필요한 attachment·편집기에서
  `LatexEquationUIView`로 벡터 수식과 원문 fallback을 렌더한다.
- **연속 문서형 편집 데모.** 논리 블록 상태를 유지하면서 하나의 TextKit 2
  `UITextView`에서 선택·입력·undo/redo·블록 변환·인라인 서식을 처리한다.

- **테마 확장.** `LatexTheme.inlineCodeForeground`(기본: light `#A93226`,
  dark `#FF7369` — 기본 칩 배경 대비 각각 약 5.5:1, 5.7:1로 WCAG AA 통과)와
  `inlineCodeBorder`(기본 `separator`) 추가. 기존 init 호출은 기본값으로 호환된다.
- **UIKit 렌더러.** `.backgroundColor` 사각 칠 대신 공개 attribute
  `.inlineCodeChip`(`InlineCodeChipStyle`)을 싣고, `InlineCodeDecorationView`가
  TextKit 2 segment 좌표로 칩을 텍스트 뒤에 그린다. `CAShapeLayer` 기반이라
  문서 길이만큼의 비트맵을 만들지 않고, 스크롤 재진입은 no-op이다.
- **SwiftUI 렌더러.** iOS 18+는 `TextRenderer`로 같은 규격의 칩을 그린다.
  한글·모노 폰트 fallback으로 run이 갈라져도 한 줄 안에서는 rect를 병합해
  이음새가 없다. iOS 16·17은 기존 사각 배경 + 강조색 fallback.
  제약: `.textSelection(.enabled)`은 커스텀 `TextRenderer`를 우회하므로(실측)
  인라인 코드가 있는 문단은 선택 대신 칩을 택한다 (DEVELOPMENT.md 기능 표 참고).

### 성능

UIKit 렌더러(`LatexMarkdownUIView`)의 스크롤 버벅임 개선. 공개 API 변화는 없다.
근거와 측정 절차는 `Docs/RENDERING_PERFORMANCE_PLAN.md`에 있다.

- **rebuild 증분화.** 게시마다 블록 뷰를 전부 파괴·재생성하지 않는다. `ParsedBlock`
  값 비교로 앞쪽 블록의 뷰를 재사용하고 달라진 지점 뒤만 교체한다. 한 요청의 게시는
  3회(원문 fallback → parsed → 수식 hydration)인데, 이제 수식이 없는 블록은
  hydration 게시에서 `UITextView`를 다시 만들지 않는다. 폰트·색·displayScale·테마가
  바뀌면(Dynamic Type, Bold Text, 다크 모드 포함) 전 블록을 새로 만든다.
- **블록 수식 벡터 렌더.** 블록 수식을 raster `UIImageView` 대신 SwiftMath의 공개
  벡터 뷰로 그린다. 크기가 rebuild 시점에 동기 확정되므로 원문 → 이미지 교체와
  그에 따른 셀 self-sizing 재측정이 사라진다. latex parse 실패나 입력 상한 초과는
  기존과 같이 원문 fallback이다. **인라인 수식은 raster를 유지한다**
  (`NSTextAttachment`가 이미지를 요구하고 크기가 작아 비용이 낮다).
- **`rebuild` signpost 추가** (`dev.swiftlatex` / `rebuild`). Instruments의
  Time Profiler + Hitches에서 hitch 원인이 뷰 재생성·Auto Layout인지 수식 raster인지
  갈라낼 수 있다.
- **블록 수식 raster 생략.** UIKit 렌더러의 요청은 블록 수식을 raster 대상에서
  제외한다 — 벡터 뷰로 그리므로 아무도 읽지 않던 bitmap을 더 이상 만들지 않는다.
  블록 수식만 있는 문서는 원문 fallback 단계 없이 단일 게시로 렌더된다.
  SwiftUI 렌더러의 raster 범위는 그대로다.
- **원문 fallback 뷰 재사용.** 스트리밍 갱신마다 fallback 프레임이 새 `UITextView`
  (TextKit 스택 통째)를 만들고 버리던 것을, 인스턴스 하나를 유지하고 attributed
  string만 교체하도록 바꿨다.

SwiftUI 렌더러(`LatexMarkdownView`)는 이번 변경에 포함되지 않는다 — 블록 수식 raster를
유지한다.

### 수정 (데모)

- **UIKit 챗 데모의 빈 버블 결함.** 빠른 스크롤 왕복 뒤 일부 셀이 캐시된 높이의
  빈 버블로 남았다. 화면 밖 셀이 reuse pool에서 늦게 `prepareForReuse`를 받을 때,
  이미 다른 셀로 이사한 메시지 뷰를 무조건 `removeFromSuperview`해 화면에 보이는
  셀에서 뜯어내던 문제. 뷰가 아직 자기 버블에 있을 때만 제거한다.
- **UIKit 챗 데모 진입 시 빈 버블이 채워지고 커지는 과정이 보이던 문제.**
  앱 시작 직후 전 답변을 prewarm하고 메시지 뷰 캐시를 화면 수명보다 길게
  유지해, 콜드 스타트 첫 진입도 SwiftUI 화면처럼 완성 상태로 들어간다
  (컨트롤러 init 시점 prewarm은 콜드 스타트에서 push 전환 안에 못 끝났다).

## [0.2.0] - 2026-08-20

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
- `ParseCache` — canonical bounded 입력과 dollar-math 설정을 key로 ParsedDocument를
  보관한다. 같은 메시지의 재렌더에서 Markdown parsing을 줄이고, stale generation은
  cache에 저장하지 않는다.
- 입력 제한 강화 — byte 상한뿐 아니라 과도하게 깊은 block quote를 Markdown parser 전에
  제한해 pathological input이 UI를 점유하지 않게 한다.

- 데모 앱에 **UIKit 네이티브** 화면 추가
  (`Examples/SwiftLatexDemo/Sources/UIKitChatDemo.swift`).
  `LatexMarkdownUIView`를 `UICollectionView` 재사용 셀에 직접 넣고, 테마 프리셋
  4종(기본 / 큰 글자 / Serif / 색 강조)으로 폰트·색·수식 서체 커스터마이즈를 확인한다.
  프리셋별 스크린샷을 남기는 UI 테스트 `testUIKitNativeCellsRender`를 함께 추가했다.
- 데모의 `렌더 옵션` 메뉴에 SwiftUI/UIKit 공통 테마 프리셋을 추가하고, 루트 진입 이름을
  **AI 챗봇 (SwiftUI)** / **AI 챗봇 (UIKit)**으로 맞췄다.

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
- 새 render request가 cache miss일 때 이전 문서·수식 이미지를 보이지 않게 하고 최신
  bounded fallback을 즉시 표시한다. UIKit 셀 재사용 중 다른 메시지의 잔상이 남지 않는다.
- UIKit 네이티브 데모는 완성된 메시지 뷰를 ID별로 보관해 재방문 시 `UIStackView` 블록
  계층을 다시 만들지 않는다. 테마·파싱 옵션 변경 시에는 cache를 비운다.

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

[Unreleased]: https://github.com/Jimmy-Jung/SwiftLatex/compare/0.5.0...HEAD
[0.5.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.5.0
[0.4.1]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.4.1
[0.4.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.4.0
[0.3.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.3.0
[0.2.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.2.0
[0.1.1]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.1.1
[0.1.0]: https://github.com/Jimmy-Jung/SwiftLatex/releases/tag/0.1.0
