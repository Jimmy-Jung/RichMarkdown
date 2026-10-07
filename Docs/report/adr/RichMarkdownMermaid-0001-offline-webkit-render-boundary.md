# ADR-0001: 공식 Mermaid 번들을 로컬 WebKit 페이지에서 표시한다

- 기준일: 2026-10-06
- 상태: **소급 기록 — 현재 구현 확인**
- 범위: 선택형 모듈, JavaScript 묶음 파일, SVG 표시, 입력 안전 제한

## 배경

Mermaid 문법을 Swift 도형 코드로 다시 구현하면 다이어그램의 문법과 배치 규칙을 별도로 유지해야 합니다. 공식 Mermaid JavaScript를 활용하면 이 부담을 줄일 수 있습니다. 다만 기본 Markdown 모듈에 웹 실행 환경(runtime)을 포함하면 다이어그램이 필요 없는 앱도 WebKit과 JavaScript 리소스를 함께 관리해야 합니다.

WebKit은 앱 안에서 웹 내용을 표시하고 JavaScript를 실행하는 Apple 구성 요소입니다. 실제 화면은 `WKWebView`가 담당합니다. 이 문서에서 앱 측(native)은 Swift 코드, 웹 측은 `WKWebView` 안의 JavaScript 코드를 뜻합니다.

## 현재 선택

Swift Package에서 선택해 추가할 수 있는 `RichMarkdownMermaid` product에 Mermaid JavaScript 묶음 파일(bundle)과 index 페이지를 넣습니다. Mermaid 버전은 고정합니다. `RichMarkdownDiagramRendering`을 구현한 렌더러는 자신이 담당하는 코드 블록 언어의 본문만 다이어그램으로 바꿉니다.

결과는 확대해도 선명한 벡터 그림인 SVG이며, `WKWebView` 안에서 그대로 표시합니다. 원문 `source`는 고정된 JavaScript 호출 코드의 문자열 인자로 전달하고, Swift에는 결과 크기만 돌려줍니다.

초기 로드에서는 앱에 포함한 로컬 리소스만 사용합니다. 웹 데이터를 디스크에 영구 저장하지 않는 비영구 data store, Mermaid의 strict 보안 설정, CSP, 페이지 이동을 판단하는 navigation delegate를 함께 사용합니다. CSP(Content Security Policy)는 허용할 스크립트와 자원 출처를 제한하는 규칙입니다. 앱 실행 중 외부 배포 서버(CDN)에서 스크립트를 받아 조립하는 경로는 없습니다.

## 비교안과 비용

| 방식 | 얻는 것 | 비용·제약 | 현재 선택과의 관계 |
| --- | --- | --- | --- |
| 앱에 포함한 Mermaid + WebKit | 공식 문법과 배치 규칙을 사용합니다. SVG를 확대할 수 있고 초기 리소스를 오프라인에서 불러옵니다. | 웹 실행 프로세스, 초기 로드, 웹·Swift 간 크기 전달, 보안 제한을 관리해야 합니다. | 현재 구현입니다. |
| Swift로 Mermaid 재구현 | 앱 뷰와 접근성 의미를 직접 구성할 수 있습니다. | 문법·배치·버전 호환을 직접 유지해야 합니다. | 현재 범위 밖입니다. |
| 서버에서 이미지로 변환 | 앱 내 실행 부담을 줄일 수 있습니다. | 원문을 외부로 보내야 합니다. 네트워크·서버와 이미지 확대·갱신 정책이 필요합니다. | 현재의 원문 로컬 처리 방식과 다릅니다. |
| CDN에서 실행 중 로드 | 앱에 포함한 JavaScript를 교체하는 횟수를 줄일 수 있습니다. | 네트워크, 서버 가용성, 버전, 외부 코드 공급 경로의 변화를 관리해야 합니다. | 현재의 버전 고정 로컬 번들과 다릅니다. |

이 표는 현재 구조를 이해하기 위한 비교입니다. 서버를 새로 도입하거나 외부 렌더 서비스를 사용하도록 승인한 기록이 아닙니다.

## 효과와 제약

기본 코드 블록은 원문 복사와 헤더를 유지하고 본문만 다이어그램으로 바뀝니다. 다이어그램을 쓰지 않는 앱은 렌더러를 전달하지 않고 원래 코드 표시를 사용할 수 있습니다. `WebAssets`는 `.copy`로 복사해 파일 이름과 디렉터리 구조를 유지합니다.

`securityLevel: 'strict'`, 최상위(root)·flowchart의 `htmlLabels: false`를 사용합니다. 추가 `secure` 키 잠금으로 원문에서 안전 설정을 덮어쓰지 못하게 합니다. 반환된 SVG는 화면에 내보내기 전 검사하는 숨긴 임시 영역(staging)에 넣습니다. 현재 요청을 구분하는 번호인 generation을 마지막으로 확인한 뒤 최신 결과만 표시합니다. Swift에서 위험한 태그·속성을 제거하는 별도의 sanitizer는 추가하지 않았습니다.

임시 HTML 라벨의 이벤트 코드가 실행되는 경로를 확인해 스크립트 CSP도 강화했습니다. 로컬 번들과 내용이 정확히 일치하는 초기 실행 코드(bootstrap)만 허용하며, 코드 일치는 SHA-256 해시로 확인합니다. 스타일과 `data` 자원은 지정한 범위에서 허용합니다.

XSS는 입력에 섞인 스크립트가 웹 화면에서 실행되는 공격입니다. 원문을 인자로 전달하고 CSP 문자열을 확인했다는 이유만으로 모든 XSS 입력을 차단했다고 보고하지 않습니다. [IM-04](../improvements/RichMarkdownMermaid.md#im-04-임시-html-label-이벤트-실행과-안전-설정-잠금)는 추가한 공격 회귀와 남은 검수 범위를 구분합니다. 숨긴 임시 영역도 보안 격리 공간은 아닙니다.

번들을 업데이트할 때는 원본 의존성을 선언한 manifest, 실제 설치 버전을 고정한 lock 파일, 리소스, 라이선스 고지를 함께 검토해야 합니다. `Web/build.mjs`는 `OUTPUT_DIR`로 출력 위치를 지정할 수 있습니다. Mermaid 본체는 `11.17.2`를 유지했고 DOMPurify `3.4.16`과 JavaScript KaTeX `0.18.2`를 고정해 보안 개선 번들을 다시 생성했습니다. 기존 검수 기록은 [검수 기록](../validation.md)에 연결합니다.

## 근거와 검증 상태

- [Package.swift](../../../Package.swift) — 별도 product, WebKit 연결, 리소스 복사, Swift 대상에서 Web 폴더 제외
- [MermaidWebRenderer.swift](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift) — 로컬 로드, 인자 전달, 웹 데이터 저장·페이지 이동 설정
- [index.html](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html) — CSP, strict 설정, SVG 표시, 크기 계산
- [Web/package.json](../../../Sources/RichMarkdownMermaid/Web/package.json), [Web/build.mjs](../../../Sources/RichMarkdownMermaid/Web/build.mjs) — 버전 고정과 번들·라이선스 고지 생성
- [MermaidRendererTests.swift](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift) — 리소스·실제 SVG·확장 연결 확인 코드

이번 문서 윤문에서는 번들을 새로 생성하거나 테스트를 다시 실행하지 않았습니다. 보안 개선 번들과 추가한 Swift·JavaScript 회귀 테스트의 기존 실행 상태는 [검수 기록](../validation.md)에 기록합니다.
