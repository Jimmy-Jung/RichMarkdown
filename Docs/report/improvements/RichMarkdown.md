# RichMarkdown 개선안

기준일: 2026-10-06 · 상태: **코드 반영, 패키지·Demo 회귀 확인**

아래 개선은 코드에 반영했습니다. RENDER-IMP-01·02·03의 패키지 회귀 테스트와 기존 Demo UI의 통과 조건(gate)을 확인했습니다. RENDER-IMP-03은 변경 전 실패를 확인한 뒤 수정했습니다.

실행 건수와 제외 항목은 [검수 기록](../validation.md)에 모았습니다. [현재 spec](../spec/RichMarkdown.md)과 [아키텍처](../architecture/RichMarkdown.md)는 반영된 동작 규칙을 설명합니다.

## RENDER-IMP-01: 코드 색 범위 덧셈의 정수 초과 검사

**변경 전 근거:** 코드 색 공급자가 반환하는 범위는 원문의 위치·길이를 담은 `NSRange`입니다. 이 값은 화면 글자 수가 아니라 UTF-16의 16비트 단위로 계산하며, 이모지 한 글자가 두 단위일 수 있습니다. [RichMarkdownHighlightSegments.segments](../../../Sources/RichMarkdown/RichMarkdownCodeBlockOptions.swift)는 공급자의 `NSRange.location + NSRange.length`를 먼저 더한 뒤 범위·길이를 검사했습니다.

공개 `RichMarkdownHighlightSpan` 생성자(initializer)는 해당 정수를 제한하지 않았습니다. 따라서 `Int.max + 1`처럼 정수의 표현 범위를 넘는 덧셈(overflow)이 범위 검사보다 먼저 발생할 수 있었습니다.

**반영:** 시작 위치(start)가 앞서 처리한 끝 위치(cursor) 이상이고 길이(length)가 양수인지 먼저 검사한 뒤, 덧셈 초과 여부도 반환하는 `addingReportingOverflow`로 끝 위치(end)를 계산합니다. 덧셈 초과·원문 밖·겹침·문자 경계 오류가 있는 색 범위(span)만 버리고, 색을 지정하지 않은 사이 부분(gap)과 끝부분(tail)은 그대로 보존합니다. UIKit·SwiftUI는 같은 도우미 함수를 사용합니다.

**회귀 선언:** [CodeBlockExtensionTests](../../../Tests/RichMarkdownTests/CodeBlockExtensionTests.swift)의 `extremeHighlightRangesPreserveSourceInBothRenderers`는 음수·`Int.max` 범위를 유효한 범위와 섞어 전달합니다. 분할된 텍스트 조각(segment)과 두 렌더러의 서식 있는 문자열(attributed text)이 원문과 일치하는지 확인합니다. 기존 `invalidSpansAreDroppedWithoutLosingText`, `segmentsPreserveSourceExactly`도 유지합니다.

**검수 경계:** 원문(source) 보존과 잘못된 색 범위 거절이 대상입니다. 이 검사만으로 모든 언어에서 키워드 등 코드 요소를 올바르게 분류하는지, 색 대비가 충분한지, 글자 모양(glyph)이 올바르게 배치되는지 승인하지 않습니다.

## RENDER-IMP-02: SwiftUI 코드 색 결과의 요청 일치 확인

**변경 전 근거:** 요청 판별 기준(identity)은 두 입력을 같은 요청으로 볼지 결정하는 비교값입니다. [CodeBlockView](../../../Sources/RichMarkdown/RichMarkdownView.swift)는 작업을 다시 실행할지 판단할 때 언어(language)·코드(code)만 비교했고, 화면에 결과를 표시할 때는 코드만 검사했습니다. 같은 코드에서 언어를 바꾸면 이전 색이 남았고 코드 색 공급자(highlighter)만 바꾸면 새 공급자를 호출하지 않았습니다.

SwiftUI 화면을 실제로 띄운 회귀 테스트(hosting)에서 이 두 실패를 확인했습니다.

**반영:** 내부 `HighlightRequest`는 코드·언어·공급자 객체 참조를 함께 비교합니다. 작업 식별자(task id), 저장 결과가 어느 요청의 것인지 확인하는 기준, 화면 표시 조건에 이 값을 함께 사용합니다. 새 요청을 시작하면 이전 상태(state)를 지웁니다.

공급자 nil·언어 nil·빈 코드·빈 색 범위이면 원문 코드를 기본 색으로 표시(plain code)합니다. `await`로 결과를 기다린 뒤에도 취소 상태와 현재 요청의 결과인지 확인합니다.

**회귀 선언:** [CodeBlockHighlightIdentityTests](../../../Tests/RichMarkdownTests/CodeBlockHighlightIdentityTests.swift)는 실제 CodeBlockView의 상태를 유지하며 언어·공급자 교체·공급자 제거·빈 결과·이전 공급자의 지연 완료를 검사합니다. 비동기 작업의 재개 시점을 직접 제어하는 continuation으로 반환 시점을 정하고, 키워드 색 픽셀을 읽어 실제 표시 여부를 확인합니다. 공개 프로토콜(protocol)은 변경하지 않았습니다.

**검수 경계:** 변경 후 회귀 실행 결과는 [검수 기록](../validation.md)에 있습니다. 테스트 코드가 있다는 사실만으로 장문 스트리밍·실제 셀 재사용·모든 테마의 표시를 승인하지 않습니다.

## RENDER-IMP-03: UIKit 표의 실제 셀 높이 측정

**변경 전 근거:** [tableView·layoutTableColumns](../../../Sources/RichMarkdown/RichMarkdownUIView.swift)는 초기 콘텐츠 높이를 1pt로 고정한 `TableScrollBlock`을 만들고 같은 콘텐츠에 `systemLayoutSizeFitting`을 호출했습니다. 이 API는 Auto Layout으로 필요한 크기를 측정하지만, 기존 고정 높이 제약도 함께 적용되어 생성·스트리밍 갱신 모두 1pt에 갇혔습니다. 기존 표 검사는 텍스트·정렬·접근성 도움말(hint)·뷰 재사용을 확인했지만 실제 높이는 확인하지 않았습니다.

**실행 근거:** `tableHeightFitsRowsOnCreationAndStreamingContentGrowth`의 변경 전 실행에서 초기 높이 1pt가 헤더·본문의 최소 높이보다 작았고, 긴 셀 텍스트를 반영한 뒤에도 1pt로 유지됐습니다. 같은 표·셀 객체가 유지되는지 확인하는 검사는 통과했으므로, 뷰 재사용 실패와 높이 측정 실패를 구분했습니다.

**반영:** 셀 내용에 필요한 열 폭을 96…240pt로 정한 뒤 기존 `fittingSize(UITextView)`에 그 폭을 전달합니다. 각 행의 최대 셀 높이를 합해 콘텐츠·스크롤 높이에 적용합니다. 줄바꿈, 먼저 원문으로 보여 준 수식을 완성된 이미지로 채우는 처리(hydration), 스트리밍 내용 증가가 있어도 다시 측정하며 새 인터페이스나 공개 API는 추가하지 않았습니다.

**회귀 선언:** [RichMarkdownUIViewTests](../../../Tests/RichMarkdownTests/RichMarkdownUIViewTests.swift)의 `tableHeightFitsRowsOnCreationAndStreamingContentGrowth`는 실제 표의 초기 높이·내용 증가 후 높이와 같은 표·셀 객체가 유지되는지를 확인합니다. [Demo UI 테스트](../../../Examples/RichMarkdownDemo/UITests/RichMarkdownDemoUITests.swift)의 `testUIKitSSEDemoRendersWhileStreaming`은 원래 40초 조건과 표 셀 확인을 유지합니다.

**검수 경계:** 표 높이 단위 회귀 테스트와 원래 UIKit SSE UI 검사의 통과 조건은 각각 만족했습니다. SSE는 서버가 응답 내용을 조금씩 보내는 스트리밍 방식이며, 해당 데모에서도 표가 표시되는지 확인한 것입니다. 예제 앱의 문서용 스크린샷 검사는 별도 선택 실행 항목이라 이번 실행에서 제외됐고, 실행 건수와 남은 검수 범위는 [검수 기록](../validation.md)에 있습니다.

[현재 ADR](../adr/RichMarkdown-0001-render-identity-generation.md)은 코드 색 결과가 현재 요청에 속하는지 확인하는 검사도 설명합니다. 수식 탐색기의 인용 깊이와 단독 CR 줄바꿈의 범위 계산은 [Core 개선 기록](RichMarkdownCore.md)을 따릅니다.
