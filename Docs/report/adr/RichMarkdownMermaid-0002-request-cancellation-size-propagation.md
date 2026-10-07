# ADR-0002: 페이지 준비를 공유하고 최신 그림과 높이만 반영한다

- 기준일: 2026-10-06
- 상태: **사용자 요청에 따라 개선 반영**
- 범위: 초기 로드 작업 관리, Swift·JavaScript 취소 처리, 완료 대기 시간 제한, 높이의 SwiftUI 전달

## 배경과 결정

원문을 빠르게 바꾸면 초기 페이지 로드를 기다리던 이전 요청이 끝나지 않거나, 늦게 완성된 이전 그림이 웹 화면에 나타날 수 있었습니다. 이전 구현은 `Task` 취소와 완료 뒤 높이 검사만으로 이 문제를 막지 못했습니다. DOM은 웹 문서의 화면 구조이며, 늦은 JavaScript가 이를 바꾸면 Swift의 높이 검사만으로는 이전 그림 표시를 막을 수 없습니다.

현재는 초기 페이지 로드 작업(navigation)을 하나로 합칩니다. 완료를 기다리는 개별 호출(waiter)은 고유 식별자인 UUID로 구분합니다. 각 호출의 대기와 완료 콜백을 연결하는 continuation은 정확히 한 번만 끝냅니다. continuation은 완료 콜백을 받은 뒤 기다리던 `async` 코드를 다시 진행시키는 수단입니다. 한 호출을 취소하면 해당 대기는 즉시 끝내지만 다른 호출이 기다리는 페이지 로드는 유지합니다.

앱 측(native)인 Swift에서 새 요청을 받으면 이전 요청의 대기를 취소합니다. 웹 측 JavaScript는 현재 결과를 구분하는 별도 요청 번호인 generation을 사용합니다. 기다리던 작업이 끝나는 각 `await` 뒤에 번호를 확인하고, 화면에 내보내기 전 검사하는 숨긴 임시 영역(staging)에서 크기를 측정합니다. 브라우저의 화면 갱신 단위인 frame을 마지막으로 기다린 뒤 최신 결과만 표시 DOM으로 옮깁니다.

JavaScript의 `Promise`는 나중에 완료될 결과입니다. 페이지마다 이 작업들을 대기열(queue)에 연결해 Mermaid 엔진 작업을 하나씩 실행합니다. 따라서 전역 `initialize` 설정이 서로 덮어쓰이지 않습니다. 결과 형식인 SVG는 확대해도 선명한 벡터 그림입니다. SVG ID는 도형 정의를 고유하게 구분하는 용도이며, 결과가 최신인지 확인하는 번호(token)를 대신하지 않습니다.

로드와 렌더링 완료에 각각 15초의 대기 시간 제한(deadline)을 둡니다. 최초 요청 전체가 15초 안에 끝난다는 뜻은 아닙니다. 진행 중 렌더링을 취소하거나 시간 초과(timeout)가 나면 다음 요청에서 페이지를 다시 불러옵니다. 끝나지 않는 `Promise`가 대기열을 막더라도 새 페이지에서 다음 요청을 처리할 수 있도록 하기 위한 조치입니다. `Task` 취소와 generation 무효화는 실행 중인 JavaScript를 강제로 멈추는 기능이 아닙니다.

정상 결과 높이는 UIKit의 내용 크기(intrinsic size)와 콜백을 거쳐 SwiftUI의 상태(state)와 `frame(height:)`에 전달합니다. 여기서 intrinsic size는 뷰가 내용에 맞춰 요청하는 크기이고, SwiftUI의 `frame`은 브라우저 화면 갱신 단위와 다른 의미입니다.

## 비교와 비용

| 방식 | 이점 | 비용과 결정 |
| --- | --- | --- |
| 앱 측 `Task` 취소만 사용 | 높이 반영을 간단히 막습니다. | 초기 로드를 기다리는 호출과 웹 화면의 최신 결과를 관리하기에는 부족해 보완했습니다. |
| 개별 로드 대기 + 요청 번호 + 엔진 대기열 | 겹치는 대기와 최신 앱·웹 결과를 함께 관리합니다. | 현재 채택했습니다. 완료 콜백·취소·시간 초과가 어느 요청에 속하는지 검사해야 합니다. |
| 요청마다 `WKWebView` 재생성 | 요청별로 뷰 생성·해제를 분리합니다. | 매번 초기화하는 비용을 피하려고 시간 초과·취소 복구에서는 페이지를 다시 불러옵니다. |
| 고정 높이 | UIKit·SwiftUI 간 높이 전달이 단순해집니다. | 내용이 잘리거나 여백이 불필요하게 생기므로 실제 측정 크기를 유지합니다. |

## 수명과 남은 제한

뷰의 폭이 정해지고 앱의 창(window)에 붙은 뒤 렌더링을 시작합니다. 같은 그림을 다시 그릴지 비교하는 키에는 높이(height)를 넣지 않습니다. 원문 `source`·테마 `theme`가 바뀌면 이전 그림과 접근성 내용을 즉시 가리고 로딩 상태로 전환합니다. 입력 변경과 뷰가 창에서 떨어지는 단계(detach)에서는 기존 작업을 취소합니다.

높이 차이가 0.5 이하면 콜백을 생략합니다. SwiftUI의 뷰 갱신(update)에서는 최신 콜백을 연결하고, 뷰 제거(dismantle)에서는 콜백과 작업을 정리합니다. 렌더링을 끝내 작업이 없는 상태(idle)에서 웹 실행 프로세스가 종료돼도 알림을 받아 복구합니다. 연속 종료에는 한 번만 재시도하며 성공하거나 새 `source`·`theme`가 들어오면 재시도 횟수를 다시 사용할 수 있습니다.

원문 `source` 전체와 상위 코드 블록의 복사 기능은 보존합니다. 실패 시 텍스트 뷰에 보여주는 앞부분(prefix)만 UTF-8 20,000바이트 이내로 제한합니다. Swift `Character` 경계에서 잘라 글자나 복합 이모지를 중간에 나누지 않습니다. 표시 상한은 원문 전체의 메모리 보관 상한이 아닙니다.

이 결정만으로 모든 웹 프로세스 종료 순서, VoiceOver에 전달하는 의미, 전체 공격 입력, 장시간 성능을 검증한 것은 아닙니다. 테스트가 제어한 종료 알림도 실제 OS의 프로세스 강제 종료 재현과 구분합니다.

## 근거와 실행 상태

[MermaidWebRenderer.swift](../../../Sources/RichMarkdownMermaid/MermaidWebRenderer.swift), [MermaidDiagramUIView.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramUIView.swift), [MermaidDiagramView.swift](../../../Sources/RichMarkdownMermaid/MermaidDiagramView.swift), [index.html](../../../Sources/RichMarkdownMermaid/Resources/WebAssets/index.html), [회귀 테스트](../../../Tests/RichMarkdownMermaidTests/MermaidRendererTests.swift)를 함께 대조합니다. 실행 결과는 [검수 기록](../validation.md)에 분리하며 적용 내역·남은 검수는 [개선안](../improvements/RichMarkdownMermaid.md)에 기록합니다.
