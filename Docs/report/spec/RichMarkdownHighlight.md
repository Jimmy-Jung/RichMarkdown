# RichMarkdownHighlight 동작 명세

기준일: 2026-10-06

이 문서는 코드에 문법별 색을 적용하는 `RichMarkdownHighlight`의 입력·출력 계약과 테스트 근거를 정의합니다. Prism은 코드 원문을 키워드·문자열·주석 같은 조각(토큰)으로 분류하는 라이브러리이며, 이 모듈은 색을 적용할 원문 구간(span)을 반환합니다. 실제 화면과 색 선택은 `RichMarkdown`이 맡습니다.

테스트 링크는 확인 코드의 위치이며 이번 윤문에서 새로 얻은 통과 결과가 아닙니다. 기존 실행 결과는 [검수 기록](../validation.md)을 따릅니다. [아키텍처](../architecture/RichMarkdownHighlight.md) · [ADR](../adr/README.md#richmarkdownhighlight-adr) · [개선안](../improvements/RichMarkdownHighlight.md)을 함께 읽습니다.

## 1. 공개 API

`PrismHighlighter`는 actor로 JavaScript 실행 환경(`JSContext`)을 관리합니다. actor는 공유 상태를 동시에 사용하지 못하게 보호하는 Swift 타입이며 전용 스레드 하나를 뜻하지는 않습니다. 실행 환경은 첫 요청에서 필요할 때 만드는 지연 초기화 방식을 사용합니다.

입력 길이와 색 구간의 위치는 UTF-16 단위입니다. UTF-16은 문자를 16비트 단위로 표현하는 방식으로 UIKit의 `NSRange`가 사용합니다. 이모지 하나가 두 단위를 차지할 수 있으므로 글자 수와 구분해야 합니다.

| 공개 API | 계약 |
| --- | --- |
| `PrismHighlighter()` | 별도의 actor를 생성하며, 실행 환경은 첫 요청에서 초기화합니다. |
| `PrismHighlighter.shared` | 여러 코드 블록이 한 actor와 실행 환경을 공유하는 기본 인스턴스입니다. |
| `maxCodeUTF16Units` | 코드 블록 하나의 상한 `100_000`입니다. 전체 Markdown 상한과 다른 값입니다. |
| `spans(for:language:) async` | 원문에 대응하는 `[RichMarkdownHighlightSpan]`을 반환하며 오류를 던지지 않습니다. |
| `reset()` | 실행 환경을 해제합니다. actor 밖에서는 `await`로 호출하며 다음 요청에서 다시 초기화합니다. |

공개 타입·함수는 [PrismHighlighter.swift](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift), 색 구간과 역할의 타입은 [RichMarkdownCodeBlockOptions.swift](../../../Sources/RichMarkdown/RichMarkdownCodeBlockOptions.swift)에 있습니다. iOS 16 이상 앱에서 선택적으로 추가하는 SwiftPM product이며, `.richMarkdownCodeBlocks(.init(highlighter: ...))` 또는 `RichMarkdownUIView.codeBlocks`에 하이라이터 객체를 전달해 사용합니다.

## 2. 입력과 코드 분석 규칙

아래 수용 기준은 현행 코드가 의도한 동작입니다. 테스트가 없는 항목은 그 사실을 표시합니다.

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| H-01 | 비어 있는 코드는 `[]`입니다. | [spans](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L78) | [emptyCodeReturnsNoSpans](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L138) |
| H-02 | 100,000 UTF-16 단위를 초과한 코드는 토큰화하지 않고 `[]`입니다. | [길이 가드](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L85) | [oversizeCodeReturnsNoSpans](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L143) |
| H-03 | 언어는 소문자로 통일하고 `c++ → cpp`처럼 코드에 등록된 별칭을 적용합니다. 미지원 문법은 `[]`입니다. | [aliases와 spans](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L56) | [aliasesResolveToSameSpansAsCanonicalName](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L95), [unsupportedLanguageReturnsNoSpans](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L133) |
| H-04 | 패키지에 포함된 번들 스크립트를 목록 순서대로 초기화하며 하나라도 실패하면 `[]`입니다. | [loadedContext](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L105) | [bundledGrammarsLoad](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L62); 번들 손상 주입 테스트 없음 |
| H-05 | 사용자 코드는 JavaScript 함수의 문자열 인자로 전달하며 실행할 스크립트에 합치지 않습니다. | [tokenize](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L127) | 전용 삽입 공격 테스트 없음; 코드 경로 대조 |
| H-06 | actor 작업 시작 전에 취소된 요청은 `[]`입니다. | [취소 가드](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L81) | 전용 취소 테스트 없음 |

## 3. 반환 결과 규칙

UTF-16은 문자를 16비트 단위로 표현하는 방식이며, 색 구간의 `NSRange`는 이 단위로 위치와 길이를 나타냅니다. 가상 예시 `A😀B`는 Swift `Character`로 3개지만 UTF-16은 4단위이므로 이모지는 `(location: 1, length: 2)`, `B`는 위치 3입니다. 글자 수나 UTF-8 바이트 위치를 그대로 사용하면 색 범위가 어긋날 수 있습니다.

| ID | 요구와 수용 기준 | 구현 근거 | 테스트 근거 |
| --- | --- | --- | --- |
| H-07 | 색 구간의 위치와 길이는 UTF-16 단위입니다. 한글·이모지를 포함해 유효한 Swift 범위로 바꿀 수 있어야 합니다. | [validatedSpans](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L151) | [koreanAndEmojiRangesStayOnCharacterBoundaries](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L116) |
| H-08 | 토큰 조각을 합친 UTF-16 값이 원문과 다르면 색 구간 전체를 버립니다. | [원문 비교](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L174) | [expectLossless](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L11)를 각 실제 문법 테스트에서 호출; 불일치 조각 직접 주입 없음 |
| H-09 | 토큰은 색을 선택할 때 쓰는 테마 역할 7종으로 통일합니다. 연산자(operator)·구두 기호(punctuation)·일반 텍스트(plain)는 별도 색을 주지 않습니다. | [kind](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L184) | [operatorsAndPunctuationStayUncolored](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L164), [dottedPrismTypeUsesItsCategory](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L170) |
| H-10 | reset 전후 동일 코드의 결과는 동일한 문법에서 같아야 합니다. | [reset](../../../Sources/RichMarkdownHighlight/PrismHighlighter.swift#L99) | [resetRebuildsContextAndKeepsResults](../../../Tests/RichMarkdownHighlightTests/PrismHighlighterTests.swift#L151) |
| H-11 | 색 구간에 포함되지 않은 글자도 결과를 사용하는 렌더러에 원문대로 남습니다. | [RichMarkdownHighlightSegments](../../../Sources/RichMarkdown/RichMarkdownCodeBlockOptions.swift#L147) | [segmentsPreserveSourceExactly·invalidSpansAreDroppedWithoutLosingText](../../../Tests/RichMarkdownTests/CodeBlockExtensionTests.swift) |

## 4. 실패와 취소

빈 배열 `[]`는 색을 적용할 유효한 결과가 없다는 뜻입니다. 빈 입력, 미지원 문법, 길이 초과, 초기화·토큰화 오류, 원문 불일치, 사전 취소를 호출자가 구분하는 오류 API는 없습니다. 실패하더라도 색상 없이 원문을 보여주려는 계약에 맞춘 형태입니다.

토큰화가 시작된 뒤의 동기 JavaScript 실행에는 시간 초과 처리(timeout)와 중간 취소가 없습니다. `async` 선언은 작업을 비동기로 호출하고 actor의 상태 보호 규칙을 따르게 하는 것이며, 입력당 최대 실행 시간을 보장하지 않습니다. [IH-01 개선안](../improvements/RichMarkdownHighlight.md#ih-01-코드-분석-시간과-실행-중-취소)은 이 한계를 다룹니다.

UIKit 소비 뷰는 늦게 도착한 결과를 적용하기 전에 Task 취소와 현재 코드 일치를 확인합니다. 개선 전 SwiftUI에는 빈 결과에서 이전 색을 지우지 않는 경로가 있었으나, 현재는 새 요청 시작 때 이전 색을 지우고 코드·언어·하이라이터 객체 참조를 함께 비교합니다. 이 요청 식별 기준(identity)이 맞지 않는 결과는 표시하지 않으며, `spans == []`인 빈 결과나 하이라이터 제거 시 색 없는 원문을 유지합니다.

근거는 [RichMarkdownUIView.applyHighlight](../../../Sources/RichMarkdown/RichMarkdownUIView.swift#L869), [RichMarkdownView.loadHighlight](../../../Sources/RichMarkdown/RichMarkdownView.swift#L597)와 [렌더러 개선 기록](../improvements/RichMarkdown.md#render-imp-02-swiftui-코드-색-결과의-요청-일치-확인)입니다. 화면의 이전 결과를 막는 일과 엔진의 실행 중 작업을 중단하는 일은 서로 다른 책임입니다.

## 5. 검증 범위

이번 문서 윤문에서는 공개 선언·번들 읽기 순서·호출부·테스트 내용을 대조했으며, 빌드나 JavaScriptCore·시뮬레이터 테스트를 새로 실행하지 않았습니다. 기존 실행 결과는 [검수 기록](../validation.md)을 따르며 성능·메모리 측정과는 구분합니다. 특히 100,000 단위 경계값, 취소 요청, 공격 문자열, 번들 손상·토큰 불일치 주입은 테스트 링크가 있다는 이유만으로 확인이 끝났다고 판단하지 않으며 각각 별도 회귀 확인이 필요합니다.
