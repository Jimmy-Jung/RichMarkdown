# RichMarkdownMermaid 개선 적용과 남은 검수

기준일: 2026-10-06 · 상태: **구현 반영 · 실행 검수는 validation 참조**

사용자 요청에 따라 아래 개선을 소스와 회귀 테스트에 반영했습니다. 회귀 테스트는 고친 문제가 다시 생기는지 확인하는 검사입니다. [현재 spec](../spec/RichMarkdownMermaid.md)·[아키텍처](../architecture/RichMarkdownMermaid.md)는 적용한 동작을 설명하며 실제 실행 상태는 [검수 기록](../validation.md)에 기록합니다.

이 문서에서 앱 측(native)은 Swift 코드, 웹 측은 앱 내 웹 화면인 `WKWebView`에서 실행되는 JavaScript 코드를 뜻합니다. DOM은 웹 문서의 화면 구조이고, SVG는 확대해도 선명한 벡터 그림 형식입니다.

## IM-01. 초기 로드 대기의 중복과 취소

페이지를 처음 불러올 때 두 요청이 겹치면 이전 요청이 계속 기다리는 문제가 생길 수 있었습니다. 기존 구현은 continuation 하나만 저장했기 때문입니다. continuation은 완료 콜백을 받은 뒤 기다리던 `async` 코드를 다시 진행시키는 연결 수단입니다. 새 요청이 이를 덮어쓰면 앞선 요청을 끝낼 수 없었습니다.

현재는 페이지 로드 작업(navigation) 하나에 현재 로드 구분 번호인 generation과 15초 타이머를 연결합니다. 완료를 기다리는 개별 호출(waiter)은 고유 식별자인 UUID로 구분해 따로 저장합니다. 성공이나 실패 시 모든 대기를 각각 한 번씩 끝내고, 취소 시에는 해당 대기만 제거합니다. 마지막 대기가 취소되면 페이지 로드도 중단합니다. 콜백이 속한 로드 작업과 타이머의 요청 번호를 확인하므로 이전 작업이 새 로드를 끝내지 않습니다.

`concurrentLoadWaitersCancelIndependentlyAndShareOneNavigation`은 WebKit의 완료 알림을 받는 delegate에서 실제 페이지 완료 전달을 늦춥니다. 두 대기 중 하나만 취소해도 페이지 로드는 한 번만 수행하고 나머지 요청은 정상 완료하는지 확인합니다. 이전 로드 타이머와 웹 실행 프로세스 종료가 모든 순서로 겹치는 경우까지 확인한 것은 아닙니다.

## IM-02. JavaScript 그림 생성의 완료 대기 제한

기존에는 페이지 로드 시간 초과(timeout)만 처리했습니다. 여기에 렌더 완료를 기다리는 별도 15초 제한(deadline)과 `MermaidError.renderTimeout`을 추가했습니다. 로드와 렌더링의 제한은 각각 적용하므로 최초 요청 전체가 15초 안에 끝난다는 뜻은 아닙니다. 완료 콜백, 취소, 시간 초과는 현재 앱 측 요청 ID에 연결된 continuation을 한 번만 끝냅니다.

진행 중 렌더링을 취소하거나 시간을 초과하면 페이지를 dirty 상태로 표시합니다. 이는 다음 요청 전에 페이지를 다시 불러와야 한다는 뜻입니다. JavaScript의 `Promise`는 나중에 완료될 결과이며, 이 작업들을 순서대로 연결한 대기열(queue)이 끝나지 않는 경우도 있습니다. 다음 요청에서 페이지를 다시 불러오면 그 대기열에서 벗어날 수 있습니다. 원문 `source`·폭·`fontSize` 입력 검사와 완료 뒤 취소 확인은 유지합니다.

`renderDeadlineEndsNativeWaitAndNextRequestReloadsThePage`는 끝나지 않는 JavaScript `Promise`를 주입하고, 테스트 내부의 짧은 시간 제한 뒤 오류와 다음 정상 요청의 복구를 확인합니다. `cancelledJavaScriptWaitEndsWithoutWaitingForTheDeadline`은 이미 시작한 JavaScript 대기를 앱 측에서 바로 취소하는지, 취소 직후의 새 유효 요청이 이전 대기열 뒤에 막히지 않는지 확인합니다. 사용하는 앱이 시간 제한을 바꾸는 공개 API는 추가하지 않았습니다.

## IM-03. 늦은 JavaScript 결과의 DOM 반영

이전 구현은 Swift가 받은 높이를 반영하기 전에만 취소를 확인했습니다. 따라서 늦게 끝난 JavaScript가 웹 화면을 이전 그림으로 바꾸는 동작은 막지 못했습니다. 현재는 앱 측 요청 ID와 별도로 페이지의 현재 요청 번호(generation)를 사용합니다. 글꼴 준비, Mermaid 엔진, 브라우저 화면 갱신(frame)을 `await`로 기다린 뒤마다 번호를 확인합니다.

Mermaid의 `initialize`·`render`는 `Promise` 대기열에서 하나씩 순서대로 실행합니다. 그림을 화면에 내보내기 전에 검사하는 숨긴 임시 영역(staging)에서 크기 측정과 마지막 화면 갱신 대기를 끝낸 뒤, 최신 요청만 DOM과 크기에 반영합니다. 취소 시 `cancelDiagram(id)`로 현재 표시 요청 번호를 무효화합니다. SVG의 고유 ID는 도형 정의를 구분하는 용도이며, 결과가 최신인지 확인하는 generation과 다릅니다. 이 취소 처리는 실행 중인 JavaScript를 강제로 멈추는 기능이 아닙니다.

`concurrentJavaScriptOnlyCommitsLatestDiagram`과 [공유 JS 회귀 테스트](../../../Sources/RichMarkdownMermaid/Web/regression-test.mjs)는 엔진의 완료 순서를 제어합니다. 최종 표시 원문이 최신 요청과 일치하는지, 엔진이 동시에 처리하는 작업이 최대 1개인지 확인합니다. JavaScript만 실행하는 VM 테스트는 엔진 완료 전과 임시 영역의 화면 갱신 대기 중에 취소하는 경우, 늦은 결과 반영을 거부하는 경우, 다음 요청 복구를 확인합니다.

공유 테스트는 iOS 저장소만 준비한 상태에서 `npm test` 또는 빌드 전 검사 스크립트인 `prebuild`로 실행합니다. 추가 HTML 경로 인자를 넘기면 Android도 함께 검사할 수 있습니다. JavaScript 실행 환경에서의 결과를 실제 WebKit 화면 표시의 대체 증거로 보지는 않습니다.

## IM-04. 임시 HTML label 이벤트 실행과 안전 설정 잠금

후속 실행 검수에서 실제 결함을 확인했습니다. directive는 Mermaid 원문 안에 렌더 설정을 넣는 문법입니다. 이 설정으로 `flowchart.htmlLabels = true`를 켜면 strict 보안 모드인 `securityLevel = strict`에서도 임시 HTML 라벨의 `onerror` 이벤트가 실행됐습니다. SVG에서 위험한 태그·속성을 제거하는 sanitizer가 처리하기 전에 일어난 문제입니다.

이벤트 실행 여부는 테스트용 `window` 변수(flag)가 바뀌는지 확인했습니다. 실제 비밀정보나 사용자 문서는 사용하지 않았습니다. 숨긴 임시 영역은 그림을 표시하기 전 검사하는 곳일 뿐 보안 격리 공간은 아닙니다.

초기화할 때 최상위(root)·flowchart에 `htmlLabels = false`를 함께 지정하고 기본 `secure` 목록에 `htmlLabels`·`dompurifyConfig`를 더했습니다. `secure`는 원문으로 바꾸지 못하게 잠그는 설정 키 목록입니다. 중첩 객체에도 적용하므로 directive와 원문 앞부분의 설정 문법인 frontmatter가 HTML 라벨이나 sanitizer 설정을 다시 켜지 못합니다.

CSP(Content Security Policy)는 페이지에서 실행하거나 불러올 수 있는 스크립트와 자원 출처를 제한하는 규칙입니다. 스크립트 CSP에서 `unsafe-inline`을 제거하고 로컬 JavaScript 묶음 파일(bundle)과 정확히 일치하는 초기 실행 코드(bootstrap)만 허용했습니다. 코드 일치는 SHA-256 해시로 확인합니다. 따라서 임시 DOM에 `onerror`처럼 HTML 속성으로 적은 이벤트 코드(inline event)도 별도로 차단합니다. SVG에 필요한 인라인 스타일과 `data` 형식의 이미지·글꼴 허용은 유지합니다.

`sourceCannotExecuteJavaScriptOrRelaxStrictSecurity`는 directive와 frontmatter를 각각 검사합니다. 정상 SVG가 만들어지는지와 별도로, 삽입된 코드의 테스트 변수가 바뀌는지, strict와 최상위·중첩 HTML 라벨 설정이 유지되는지, sanitizer 설정 덮어쓰기가 차단되는지 확인합니다. `contentSecurityPolicyBlocksInlineEventHandlers`는 sanitizer와 별개로 CSP가 `onerror` 실행을 막는지 확인하는 검사(probe)입니다. Android에도 같은 공격·CSP 회귀를 추가했습니다.

[JS 회귀 테스트](../../../Sources/RichMarkdownMermaid/Web/regression-test.mjs)는 초기 실행 코드의 실제 바이트와 CSP 해시의 일치, `unsafe-inline` 금지, 초기화 설정 잠금을 확인합니다. 스크립트를 바꿀 때 해시를 함께 갱신하지 않으면 `npm test`·`prebuild`가 실패합니다.

별도 sanitizer나 새 의존성은 추가하지 않았습니다. 확인한 공격과 실제 실행 결과는 validation에 기록합니다. 이 결과가 모든 SVG, 외부 자원, 페이지 이동 공격 사례 모음(corpus)에 대한 보안 인증을 뜻하지는 않습니다. VoiceOver에 전달하는 의미와 장시간 성능도 별도 검수 범위입니다.

## IM-05. 실패 원문 표시의 측정 상한

Android 조사와 비교하면서 iOS에서도 너무 큰 원문 전체를 실패 텍스트 뷰에 넣고, 문자열 키를 만들며 다시 복제하는 문제를 확인했습니다. 실패 표시는 UTF-8 20,000바이트 이내의 앞부분(prefix)과 생략 표식으로 제한했습니다. Swift의 `Character` 경계에서 잘라 글자나 복합 이모지를 중간에 나누지 않습니다.

같은 그림을 다시 그릴지 비교하는 렌더 키에는 `source` 문자열 전체를 필드로 저장합니다. 원문 전체와 상위 코드 블록의 원문 복사 기능은 유지합니다.

`oversizedViewFallbackIsBoundedAndPreservesTheSource`는 한글·복합 이모지 입력에서 실패 표시가 상한 안에 들어오는지, 원문은 보존되는지 확인합니다. 이 개선은 원문 전체를 메모리에 보관하는 비용까지 제한하지 않습니다. 뷰가 창에서 떨어지는 단계(detach)와 SwiftUI가 뷰를 제거하는 단계(dismantle)에서는 진행 작업을 취소해 창 밖의 JavaScript 대기가 남지 않도록 합니다.

## IM-06. 성공 후 프로세스 종료와 요청 교체 표시

기존 구현은 렌더링이 성공해 작업이 없는 상태(idle)에서 웹 실행 프로세스가 끝나면 빈 `WKWebView`를 복구하지 못했습니다. 같은 렌더 키가 남아 새 요청을 생략했기 때문입니다. 렌더러의 종료 알림을 UIView 콜백에 연결하고, 로드 성공 직후의 종료와 `WKError`가 알리는 종료도 같은 복구 오류로 처리하도록 했습니다.

연속 종료에는 한 번만 재시도합니다. 성공하거나 새 `source`·`theme`가 들어오면 재시도 횟수를 다시 사용할 수 있습니다. `source`·`theme`를 바꾸면 이전 그림과 접근성 내용을 즉시 가리고 로딩 상태로 전환합니다. 브라우저 화면 갱신을 기다릴 수 있도록 `WKWebView` 자체는 투명하게 활성화하고 정상 결과만 다시 표시합니다.

`displayedViewRecoversFromIndependentAndPendingTerminations`, `terminationAfterLoadSuccessIsReportedBeforeJavaScriptDispatch`, `sourceReplacementHidesTheCommittedDiagramUntilTheNewResult`는 테스트에서 전달 시점을 제어한 delegate 알림, 아직 완료되지 않은 작업, 새 원문으로 교체하는 동안의 대기를 확인합니다. 실제 OS가 웹 프로세스를 강제로 종료하는 상황을 재현한 검사나 장시간 메모리 측정과는 구분합니다.
