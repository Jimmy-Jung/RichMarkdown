# RichMarkdownMermaid 동작 명세

기준일: 2026-10-06

이 동작 명세(spec)는 앱에서 사용할 수 있는 공개 API, 입력 크기 제한, 화면 표시, 실패 처리 규칙을 설명합니다. 요구 사항마다 구현과 테스트 근거를 연결합니다. 테스트 링크는 확인 코드가 있다는 뜻이며 이번 문서 작업에서 실행에 성공했다는 뜻은 아닙니다. [아키텍처](../architecture/RichMarkdownMermaid.md) · [ADR](../adr/README.md#richmarkdownmermaid-adr) · [개선안](../improvements/RichMarkdownMermaid.md)을 함께 읽습니다.

## 1. 공개 API

Mermaid 원문(`source`)은 앱에 포함한 JavaScript로 다이어그램을 만듭니다. 결과는 확대해도 선명한 벡터 그림인 SVG이며, 앱 안에 웹 내용을 보여주는 `WKWebView`에 표시합니다. WebKit은 이 웹 표시와 실행 기능을 제공하는 Apple 구성 요소입니다. 아래에서 앱 측(native)은 Swift 코드, 웹 측은 JavaScript 코드를 뜻합니다.

UIKit의 intrinsic content size는 뷰가 내용에 맞춰 요청하는 크기입니다. SwiftUI에서는 측정한 높이를 상태(state)에 저장하고 `frame(height:)`로 표시 높이를 지정합니다. `MainActor`는 화면 관련 Swift 코드를 메인 실행 영역에서 다루도록 하는 규칙입니다.

| API | 현재 계약 |
| --- | --- |
| `MermaidDiagramRenderer(languages:)`, `.shared` | 기본 `mermaid`와 지정한 소문자 언어 집합을 담당하며 UIKit·SwiftUI 뷰를 생성합니다. |
| `MermaidDiagramUIView(source:theme:)` | 원문 `source`·테마 `theme` 변경을 받고, 내용에 맞춘 높이와 크기 변경 알림인 `onSizeChange`를 제공하는 UIKit 뷰입니다. |
| `MermaidDiagramUIView.placeholderHeight` | 첫 높이의 기준 상수 64입니다. 실패 안내 내용이 더 높으면 그 크기를 사용합니다. |
| `MermaidDiagramView(source:theme:)` | 측정한 높이를 상태에 반영하는 SwiftUI 표시 뷰입니다. |
| `MermaidWebRenderer()` | `WKWebView`를 만들고 첫 `render` 호출에서 페이지를 불러옵니다. `MainActor`에서 사용합니다. |
| `render(source:dark:width:fontSize:) async throws` | SVG를 `WKWebView`에 표시하고 검사한 `CGSize`를 반환합니다. 같은 인스턴스의 새 요청은 이전 요청의 앱 측 대기를 취소합니다. 웹 페이지의 Mermaid 작업은 하나씩 순서대로 실행합니다. |
| `webView` | 표시할 `WKWebView`를 앱에서 직접 다룰 수 있도록 공개합니다. 사용하는 앱이 창(window)에 붙이거나 설정을 직접 바꿀 수 있습니다. |
| `maxSourceUTF8Bytes` | 앱 측에서 허용하는 `source`의 UTF-8 크기 상한은 20,000바이트입니다. |
| `MermaidError` | 빈 입력, 크기 상한 초과, 리소스 누락, 로드·렌더 시간 초과(timeout), 웹 실행 프로세스 종료, 잘못된 결과 크기, 렌더 오류를 나타냅니다. 모든 WebKit·JavaScript 오류가 이 열거형으로 변환되지는 않습니다. |

근거: [MermaidDiagramRenderer.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramRenderer.swift), [MermaidDiagramUIView.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift), [MermaidDiagramView.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramView.swift), [MermaidWebRenderer.swift](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift). 사용하는 앱의 최소 지원 버전은 [Package.swift](../../../Package.swift)의 iOS 16입니다.

## 2. 입력과 번들 요구

번들(bundle)은 앱에 함께 배포하는 JavaScript 묶음 파일입니다. Mermaid 원문에는 렌더 설정을 넣는 directive와 frontmatter 문법이 있습니다. 예를 들어 원문에서 HTML 라벨 사용 설정을 바꾸는 경우가 여기에 해당합니다. `secure`는 원문으로 덮어쓰지 못하게 잠그는 설정 키 목록이며, 여기서는 `htmlLabels`와 위험한 태그·속성을 제거하는 DOMPurify의 설정인 `dompurifyConfig`도 잠급니다. `maxTextSize`는 원문 길이, `maxEdges`는 도형 간 연결 수를 제한하는 설정입니다.

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| M-01 | 렌더러가 담당하는 언어의 코드 블록 본문만 다이어그램으로 바꿉니다. 언어 대소문자는 무시합니다. 헤더와 원문 복사 기능은 상위 코드 블록에 남습니다. | [languages](../../../Sources/RichMarkdownMermaid/MermaidDiagramRenderer.swift), [diagramRenderer](../../../Sources/RichMarkdown/RichMarkdownCodeBlockOptions.swift) | [rendererHandlesOnlyMermaidCodeBlocks](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift); 헤더·복사는 상위 구현을 근거로 합니다. |
| M-02 | 공백만 있는 `source`는 `emptySource`로 처리하고 `WKWebView` 호출 전에 거절합니다. | [render 입력 검사](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | [emptySourceFails](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) |
| M-03 | UTF-8 20,000바이트를 초과하면 `sourceTooLarge`입니다. JavaScript도 `source.length`를 20,000으로 제한합니다. UTF-8 바이트 수와 JavaScript가 UTF-16 단위로 세는 문자열 길이는 서로 다릅니다. | [maxSourceUTF8Bytes](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift), [renderDiagram](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html) | [oversizeSourceFailsBeforeTouchingTheWebView](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) |
| M-04 | index 페이지, JavaScript 번들, 외부 라이브러리의 라이선스 고지를 패키지 리소스로 배포합니다. 앱 실행 중 첫 로드는 앱에 포함한 로컬 파일을 사용합니다. | [Package.swift](../../../Package.swift), [loadIfNeeded](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | [bundleShipsMermaidWebAssets](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) |
| M-05 | `source`는 JavaScript 코드 문자열에 합치지 않고 `callAsyncJavaScript.arguments`로 전달합니다. | [render 호출](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | `sourceCannotExecuteJavaScriptOrRelaxStrictSecurity` |
| M-06 | strict 보안 모드, `maxTextSize` 20,000, `maxEdges` 200, 최상위(root)·flowchart의 `htmlLabels` false로 초기화합니다. 기본 `secure` 목록에 `htmlLabels`·`dompurifyConfig`를 더해 원문에서 설정을 바꾸지 못하게 합니다. | [index.html](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html) | directive·frontmatter의 설정 변경 방지와 이벤트 실행 회귀를 확인합니다. 전체 공격 사례 모음(corpus)은 별도 범위입니다. |

## 3. 크기와 표시 요구

유한값(finite)은 무한대나 NaN(숫자로 표현할 수 없는 값)이 아닌 수입니다. 자연 크기는 SVG가 원래 차지하는 크기입니다. 렌더 키는 같은 그림을 다시 그릴지 판단하기 위해 원문과 표시 조건을 묶어 비교하는 값입니다.

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| M-07 | `width`·`fontSize`는 유한값이어야 하고 `fontSize`는 양수여야 합니다. `width`는 소수점 아래를 버린 뒤 120...2,000으로 제한합니다. | [safeWidth](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | flowchart에서 360을 반환하는 검사와 `nonFiniteDimensionsFailBeforeLoading`이 있습니다. 양끝 경계 검사는 별도입니다. |
| M-08 | SVG가 넓으면 줄이고 좁으면 확대하지 않으며 수평 중앙에 놓습니다. | [targetWidth와 CSS](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html) | [narrowDiagramIsHorizontallyCentered](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) |
| M-09 | 자연 크기는 양수여야 하고 SVG 높이는 4,000 이하여야 합니다. Swift가 받은 높이는 유한값·양수·4,032 이하인지 확인합니다. | [index.html](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html), [result 크기 검사](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | [flowchartRendersWithPositiveHeight](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift); NaN·높이 초과 전용 테스트는 없습니다. |
| M-10 | 렌더 키는 `source`·`dark`·내림한 폭·본문 글자 크기입니다. 화면 배치를 다시 계산해도 키가 같으면 요청을 생략합니다. `source`·`theme`가 바뀌면 키를 비웁니다. | [renderIfNeeded·invalidateRender](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift) | 키와 시스템 글자 크기 설정(Dynamic Type) 변경에 대한 전용 회귀 테스트는 없습니다. |
| M-11 | UIKit 뷰는 `width > 1`이고 창에 붙었을 때 요청합니다. 높이 변경은 내용 크기와 크기 변경 콜백에 반영합니다. | [didMoveToWindow·setContentHeight](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift) | [diagramViewStartsAtPlaceholderHeight](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift); 크기 변경 콜백 전용 테스트는 없습니다. |
| M-12 | SwiftUI 뷰는 측정 높이를 상태와 `frame`에 전달합니다. 뷰를 제거할 때 크기 콜백을 비우고 작업을 취소합니다. | [MermaidDiagramView.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramView.swift) | SwiftUI 뷰 생성·제거와 높이에 대한 전용 테스트는 없습니다. |

## 4. 실패·취소·복구 요구

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| M-13 | 초기 페이지 로드와 렌더링 완료에 각각 15초의 대기 시간 제한(deadline)을 둡니다. 오류는 `loadTimeout`과 `renderTimeout`으로 구분합니다. | [loadIfNeeded·finishLoading](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | `renderDeadlineEndsNativeWaitAndNextRequestReloadsThePage`; 초기 로드 시간 초과 실행은 별도입니다. |
| M-14 | 일반 렌더 실패는 안내와 선택 가능한 원문으로 대신 표시합니다. 너무 큰 입력은 UTF-8 20,000바이트 이내의 앞부분과 생략 표식만 표시하되 `source` 전체는 보존합니다. Swift `Character` 경계에서 잘라 글자나 복합 이모지를 중간에 나누지 않습니다. 같은 실패 키를 자동으로 반복 재시도하지 않습니다. | [renderIfNeeded·showStatus](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift) | [invalidSourceFailsThenRendererRecovers](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift)는 렌더러 재사용 검사입니다. UIView의 대체 표시(fallback) 전용 검사는 아닙니다. |
| M-15 | 웹 실행 프로세스가 끝나면 페이지 로드 완료 상태를 해제합니다. UIKit 뷰는 연속 종료에 한 번 재시도하며 성공하거나 새 `source`·`theme`가 들어오면 재시도 횟수를 다시 사용할 수 있습니다. | [webViewWebContentProcessDidTerminate](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift), [retriedAfterTermination](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift) | `displayedViewRecoversFromIndependentAndPendingTerminations`; 실제 OS가 프로세스를 강제 종료하는 재현은 별도입니다. |
| M-16 | 새 요청은 이전 그림과 접근성 내용을 즉시 가리고 기존 `Task`를 취소합니다. 진행 중 JavaScript를 취소하면 페이지를 다음 요청 전에 다시 불러와야 하는 상태(dirty)로 표시합니다. 결과를 받은 뒤에도 요청을 검사해 이전 높이를 반영하지 않습니다. | [renderIfNeeded](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift) | 동시 로드 취소, 끝나지 않는 작업 취소 후 복구, 완료 시점을 제어한 원문 교체, 최신 웹 화면 반영, 실패 표시 상한 회귀를 추가했습니다. |
| M-17 | 문법 실패 이후 다른 유효 입력은 같은 WebView에서 다시 렌더할 수 있습니다. | [render](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | [invalidSourceFailsThenRendererRecovers·sequenceDiagramRendersOnTheSameWebView](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) |

로드와 렌더링에 각각 15초 제한이 있으므로 최초 요청 전체가 15초 안에 끝난다는 보장은 아닙니다. 초기 로드는 하나의 페이지 로드 작업(navigation)으로 합치고, 완료를 기다리는 각 호출(waiter)을 고유 식별자인 UUID로 구분합니다. 한 호출의 취소는 그 앱 측 대기만 즉시 끝냅니다.

JavaScript에서는 결과가 현재 요청의 것인지 확인하는 번호인 generation을 무효화합니다. 기다리던 작업이 끝나는 각 `await` 뒤에 번호를 비교하고 Mermaid 엔진 작업을 하나씩 순서대로 실행합니다. 따라서 이전 결과가 DOM, 즉 웹 문서의 화면 구조나 높이에 반영되지 않습니다. 화면에 내보내기 전 검사하는 숨긴 임시 영역(staging)에서 측정과 브라우저 화면 갱신(frame) 대기를 끝낸 뒤 최신 결과를 표시합니다.

`source`·`theme`가 바뀌면 이전 그림과 접근성 내용을 즉시 가리고 로딩 상태로 전환합니다. `Task` 취소는 실행 중인 JavaScript를 강제로 멈추는 기능이 아닙니다. JavaScript의 `Promise`는 나중에 완료될 결과를 나타내며, 이 작업들을 연결한 대기열(queue)이 끝나지 않을 수 있습니다. 진행 중 렌더링의 취소나 시간 초과 뒤에는 다음 요청이 페이지를 다시 불러와 이 대기열에서 벗어나도록 합니다. 실패 표시의 20,000바이트 상한은 `source` 전체의 메모리 보관 상한이 아닙니다.

## 5. 안전 경계와 한계

CSP(Content Security Policy)는 허용할 스크립트와 자원의 출처를 제한하는 웹 페이지 규칙입니다. bootstrap은 페이지를 처음 준비하는 초기 실행 코드입니다. 이 코드의 SHA-256 해시가 일치하는 경우만 허용하고, `onerror`처럼 HTML 속성에 적는 이벤트 코드(inline event)는 막습니다. XSS는 입력에 섞인 스크립트가 웹 화면에서 실행되는 공격을 뜻합니다.

| ID | 현행 경계 | 구현 근거 | 테스트·확인 범위 |
| --- | --- | --- | --- |
| M-18 | 렌더러마다 `WKWebView`를 소유하고 `WKProcessPool`은 별도로 지정하지 않습니다. 웹 데이터를 디스크에 영구 저장하지 않는 비영구 website data store를 사용하며 자동 새 창 열기를 막습니다. | [init](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | 뷰 생성·해제와 data store에 대한 전용 테스트는 없습니다. |
| M-19 | 페이지 이동은 file URL이면서 `linkActivated`가 아닌 요청만 허용합니다. `linkActivated`는 사용자가 링크를 눌러 시작한 이동입니다. | [decidePolicyFor](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) | 페이지 이동 동작 전용 회귀 테스트는 없습니다. |
| M-20 | CSP는 `connect`·`object`·외부 기본 자원을 막습니다. 스크립트는 로컬 번들과 정확한 bootstrap SHA-256만 허용해 인라인 이벤트를 차단합니다. 스타일과 `data` 형식 이미지·글꼴은 지정 범위에서 허용합니다. | [CSP](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html) | [bundleShipsMermaidWebAssets](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift)의 리소스 검사와 실제 인라인 이벤트 CSP 실행 검사는 구분합니다. 전체 XSS 보안 인증은 아닙니다. |

반환된 SVG 문자열은 숨긴 임시 영역의 `innerHTML`로 웹 문서 구조로 해석합니다. 마지막 화면 갱신 대기와 요청 번호 검사를 끝낸 뒤 표시 영역으로 옮깁니다. 임시 영역은 보안 격리 공간이 아닙니다. 위험한 태그·속성을 제거하는 별도의 Swift sanitizer는 없습니다.

확인된 임시 HTML 라벨의 이벤트 실행 경로는 설정 잠금과 CSP로 차단했습니다. directive·frontmatter 설정과 인라인 이벤트의 회귀 테스트도 추가했지만, 모든 SVG·링크·이벤트 공격 사례를 확인한 것은 아닙니다. `MermaidError.render(String)` 등의 오류 메시지는 정해진 형식이 없는 문자열입니다. 민감한 원문을 받은 앱이 오류 메시지를 외부 로그로 내보내면 별도 관리가 필요합니다.

## 6. 검증 상태

현재 소스와 추가 회귀 테스트를 대조했습니다. 실제 빌드와 `WKWebView`·JavaScript 실행 상태는 [검수 기록](../validation.md)에 기록합니다. 테스트의 `.serialized`는 테스트를 순서대로 실행한다는 뜻입니다. Mermaid 엔진 작업을 하나씩 처리하는 규칙은 HTML의 대기열이 별도로 제공합니다.

Mermaid 본체 버전 `11.17.2`는 유지했습니다. DOMPurify `3.4.16`과 JavaScript KaTeX `0.18.2`를 고정하고 보안 개선 번들을 다시 생성한 상태입니다. 이번 문서 윤문에서는 검사를 새로 실행하지 않았습니다. 접근성, 장시간 성능, 전체 공격 사례는 별도 검수 범위입니다.
