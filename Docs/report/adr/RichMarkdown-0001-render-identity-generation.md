# ADR-0001: 같은 입력 판별 기준과 요청 순서 번호를 구분한다

- 기준일: 2026-10-06
- 상태: 소급 기록 — 현재 구현 확인
- 근거: [RichMarkdownRenderModel](../../../Sources/RichMarkdown/RichMarkdownRenderModel.swift), [RichMarkdownView](../../../Sources/RichMarkdown/RichMarkdownView.swift), [ParseCache](../../../Sources/RichMarkdown/ParseCache.swift)

## 문제

같은 셀에서 문서를 바꾸거나 누적 원문을 계속 늘리면 이전 구문 분석(parse)·수식 이미지 생성(raster) 결과가 새 요청 이후에 도착할 수 있습니다. 구문 분석은 Markdown을 문단·표·수식 같은 구조로 읽는 처리이며, 여기서 raster는 수식을 픽셀로 된 비트맵 이미지로 만드는 처리입니다. 늦게 끝난 이전 작업이 최신 화면을 덮어쓰지 않도록 구분해야 합니다.

색 변경과 문서 교체를 똑같이 기존 결과 삭제(invalidation)로 처리하면 유지할 수 있는 문서까지 사라집니다. 원문 뒤에 텍스트를 덧붙일(append) 때마다 서식 있는 화면 대신 원문으로 대체 표시(fallback)하면 표시 방식이 계속 바뀝니다.

## 현재 선택

`ParseIdentity`는 두 입력을 같은 구문 분석 요청으로 볼지 판단하는 기준(identity)입니다. 크기를 제한한 Markdown, 달러 수식 옵션, 잘림 여부(flag)를 담습니다. 전체 `Request`에는 수식 폰트 크기(point size), 표시 환경에 맞게 결정한 색 값(RGBA: 빨강·초록·파랑·투명도), 배율(scale), 독립 블록 수식을 비트맵으로 만들지 여부도 포함합니다.

같은 요청은 무시하고 다른 요청마다 요청 순서 번호(generation)를 증가시킵니다. 예를 들어 원문이 바뀐 뒤 이전 작업이 늦게 끝나도, 순서 번호가 다르면 그 결과를 현재 화면에 반영하지 않습니다.

작업 처리기(worker)가 대기 입력을 최신 값 하나로 합치는 것과 별개로 모델이 현재 요청 순서 번호를 확인합니다. 구문 분석 캐시(cache)는 이미 분석한 결과를 재사용하는 저장소입니다. 여기에 결과를 넣을 때 번호 확인·저장을 UI 상태를 담당하는 MainActor에서 중간 대기 없이 이어서 수행하며, 문서·이미지를 화면에 반영하는 함수도 번호를 검사합니다.

![이전 요청의 완료는 현재 화면 게시에서 제외하고 최신 요청의 문서와 이미지만 반영하는 개념도](../assets/render-latest-wins.svg)

## 문서 유지 규칙

| 변경 | 현재 표시 |
| --- | --- |
| 다른 문서·달러 수식 옵션·잘림 상태 | 이전 문서·이미지 제거, 크기를 제한한 최신 원문을 대신 표시 |
| 같은 구문 분석 요청, 비트맵 설정 변경 | 문서 유지, 기존 이미지 사용 중단 |
| 잘리지 않은 같은 옵션 원문 뒤에 텍스트 덧붙이기(prefix append) | 새 분석 결과가 올 때까지 기존 문서 유지, 비트맵 설정이 같으면 이미지 유지 |
| 같은 요청 재제출 | 추가 작업·화면 반영 없음 |

원문 뒤에 덧붙이기 규칙은 조금씩 도착하는 원문을 보여 주는 스트리밍(streaming) 표시 옵션과 별개입니다. 구문 분석 캐시에는 덧붙인 결과를 새 항목(entry)으로 넣지 않고 첫 제출·문서 교체 때 저장합니다.

## 대안과 비용

| 방식 | 유리한 점 | 제한 |
| --- | --- | --- |
| 현재 요청 판별 기준 + 요청 순서 번호 + 대기 수를 제한한 작업 처리기 | 문서 재사용 조건과 비동기(async) 결과의 요청 소속을 각각 표현 | 비동기 대기 전후와 화면 반영 함수에서 현재 요청의 결과인지 확인해야 함 |
| 요청마다 문서 전체 제거 | 상태에 따른 분기가 적음 | 원문 덧붙이기·테마 변경 때 유지할 수 있는 표시 결과도 제거 |
| 작업(task) 취소만 사용 | 작업 수명 관리가 짧아짐 | 이미 시작한 동기 분석·이미지 생성과 도착한 결과의 소속을 구분하지 못함 |

이 비교는 코드의 의미를 설명하는 것이며 당시 승인 과정의 복원이 아닙니다.

## 캐시 저장과 작업 취소의 범위

과거 요청 순서 번호를 가진 분석 결과는 모델이 구문 분석 캐시에 저장하지 않습니다. 수식 캐시는 원문(source)·폰트·색·배율로 같은 결과를 찾는 키(key)를 구성하므로, 이미 시작한 이전 요청의 비트맵 결과가 저장될 수 있습니다. **현재 화면에 반영하지 않는다는 규칙을 모든 캐시 저장 금지로 확대하지 않습니다.**

동기 구문 분석·비트맵 생성 도중의 즉시 취소는 보장하지 않습니다. 모델의 작업이 끝난 상태(idle)는 최종 요청 처리를 기준으로 하며, UIKit 뷰 재구성(rebuild)이나 높이 변경 콜백이 모두 끝났다는 뜻은 아닙니다.

SwiftUI 코드 색 처리는 별도의 내부 요청에서 코드(code)·언어(language)·코드 색 공급자(highlighter) 객체 참조를 함께 비교합니다. 작업을 다시 실행할지 판단하는 기준과 결과 소속을 같은 값으로 확인하고, `body`는 현재 요청과 맞는 결과만 표시합니다. 공급자 교체·제거·빈 응답은 기본 색의 원문 코드(plain code)로 돌아가며 취소·이전 요청의 지연 결과는 반영하지 않습니다.

공개 프로토콜(protocol)과 화면 표시 모델의 범위를 넓히지 않는 변경입니다. [RENDER-IMP-02](../improvements/RichMarkdown.md#render-imp-02-swiftui-코드-색-결과의-요청-일치-확인)에 근거를 기록했습니다.

## 확인 근거

[RichMarkdownRenderModelTests](../../../Tests/RichMarkdownTests/RichMarkdownRenderModelTests.swift)의 `latestSubmissionWinsPublication`, `streamingAppendKeepsPreviousDocumentUntilNewParseLands`, `renderConfigurationChangeKeepsMatchingDocumentAndClearsImages`, `stalePreparedParseEntryIsNotStoredInCache`, `streamingAppendDoesNotStoreParseCacheEntry`는 위 규칙의 기대값을 확인하도록 작성되어 있습니다. [CodeBlockHighlightIdentityTests](../../../Tests/RichMarkdownTests/CodeBlockHighlightIdentityTests.swift)는 실제 SwiftUI의 코드 색 범위 교체를 검사합니다. 실제 실행 결과는 [검수 기록](../validation.md)에 있습니다.

[아키텍처](../architecture/RichMarkdown.md) · [명세](../spec/RichMarkdown.md) · [개선 기록](../improvements/RichMarkdown.md) · [ADR 목록](README.md#richmarkdown-adr)
