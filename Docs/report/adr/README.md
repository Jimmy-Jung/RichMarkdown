# RichMarkdown 아키텍처 결정 지도

기준일: 2026-10-06

ADR(Architecture Decision Record)은 구조를 선택한 이유와 다른 방법을 택했을 때의 비용을 기록하는 문서입니다. 아래의 **현재 구현을 보고 작성한 기록(소급 기록)**은 코드를 읽어 기존 선택을 정리했다는 뜻입니다. 과거 회의·결정 날짜·팀 승인을 추정한 기록은 아닙니다.

수정 전 동작과 이번 릴리스에 반영한 내용은 관련 개선 기록에서 구분합니다. 요청 번호·구간·벡터 표시 등 낯선 용어는 [용어 안내](../glossary.md)에서 뜻과 예시를 볼 수 있습니다.

| 모듈 | 다루는 결정 | ADR 목록 |
| --- | --- | --- |
| Core | 화면과 Markdown 분석 분리, 원문 위치 보존, 최신 대기 요청만 유지 | [Core ADR](README.md#richmarkdowncore-adr) |
| Renderer | 공통 표시 모델, 화면 반영 전 요청 번호·입력 비교 | [표시 모듈 ADR](README.md#richmarkdown-adr) |
| BlockEditor | 연속 편집과 블록 모델, Markdown 내보내기 경계 | [Editor ADR](README.md#richmarkdownblockeditor-adr) |
| Highlight | 별도 색칠 엔진, 원문 보존, UTF-16 구간별 색 역할 | [코드 색칠 ADR](README.md#richmarkdownhighlight-adr) |
| Mermaid | 앱에 포함한 웹 파일, 앱 요청·웹 문서 구조의 생성·취소·해제 | [Mermaid ADR](README.md#richmarkdownmermaid-adr) |

각 ADR은 배경, 확인된 결정, 대안, 영향, 재검토 조건, 소스 근거를 포함합니다. 측정하지 않은
성능이나 대안별 점수를 만들지 않았습니다. 기존 결정의 문제와 변경 제안은
[개선안 지도](../improvements/README.md)로 이동합니다.

## RichMarkdownCore ADR

기준일: 2026-10-06

이 기록은 현재 소스에서 확인한 구조와 그 의미를 설명합니다. 원 결정일·회의 승인·검토자의 의사는 추정하지 않습니다. **소급 기록 — 현재 구현 확인**은 코드를 읽어 정리했다는 상태이며 새 설계 변경의 승인을 뜻하지 않습니다.

| ADR | 현재 선택 | 판단할 때 보는 계약 |
| --- | --- | --- |
| [0001](RichMarkdownCore-0001-two-pass-math-protection.md) | 수식 구간을 같은 바이트 길이의 임시 문자로 보호하고 두 번째 구문 트리를 문서로 변환 | Markdown 문맥과 수식 원문·위치 보존 |
| [0002](RichMarkdownCore-0002-latest-pending-worker.md) | 실행 중 1건과 최신 대기 1건을 유지하고, 최대 수신 요청 번호로 이전 요청을 거절 | 쌓이는 중간 요청과 순서가 뒤바뀐 제출 처리 |

[아키텍처](../architecture/RichMarkdownCore.md) · [명세](../spec/RichMarkdownCore.md) · [개선 기록](../improvements/RichMarkdownCore.md)

## RichMarkdown ADR

기준일: 2026-10-06

현재 구현을 읽고 선택의 의미를 소급 기록합니다. 원 결정일·승인자·회의 기록을 추정하지 않습니다. 상태 **소급 기록 — 현재 구현 확인**은 신규 변경안의 승인이 아닙니다.

| ADR | 현재 선택 | 판단할 때 보는 계약 |
| --- | --- | --- |
| [0001](RichMarkdown-0001-render-identity-generation.md) | 문서 분석 기준·수식 이미지 설정·요청 번호를 따로 비교하고 최신 결과만 표시 | 문서 교체·뒤에 이어 붙는 입력·늦은 계산 완료 |
| [0002](RichMarkdown-0002-math-surfaces-source-fallback.md) | 글자 사이 수식은 비트맵으로, UIKit 블록 수식은 벡터로 표시하며 실패하면 원문 유지 | 글자 기준선·즉시 계산할 크기·수식 배치 상한 |

[아키텍처](../architecture/RichMarkdown.md) · [명세](../spec/RichMarkdown.md) · [개선 기록](../improvements/RichMarkdown.md)

## RichMarkdownBlockEditor ADR

기준일: 2026-10-06

상태는 **소급 기록 — 현재 구현 확인**입니다. 실제 소스에서 확인되는 선택을 기록하며 원 결정 날짜·결정자·팀 승인을 추정하지 않습니다. 대안 표는 선택 비용 설명이며 새로운 설계 승인이 아닙니다.

구현 검수 상태는 **구현·패키지 회귀 확인**입니다. 공개 숫자·범위 검사와 문법처럼 보이는 일반 문단의 저장 보완을 포함한 전체 패키지 테스트가 성공했습니다. 이후 최종 패키지·예제 앱 재검수와 배포 판정은 [릴리스 검수 기록](../validation.md)에서 구분합니다.

| ADR | 현재 선택 | 읽을 질문 |
| --- | --- | --- |
| [0001 연속 UTF-16 편집 문서](RichMarkdownBlockEditor-0001-continuous-document-block-identity.md) | 블록 모델과 화면의 TextKit 문서를 나누고 문서 전체의 선택 범위를 유지합니다. | 블록 ID와 화면의 UTF-16 범위는 왜 다릅니까? |
| [0002 Markdown과 블록 복사 데이터](RichMarkdownBlockEditor-0002-canonical-markdown-block-pasteboard.md) | 저장 문자열은 모델에서 만들고, 앱 내부의 전체 문서 복사는 블록 구조를 담은 데이터로 처리합니다. | 편집 뷰에 표시된 문자열을 그대로 보내면 왜 안 됩니까? |

관련 문서: [아키텍처](../architecture/RichMarkdownBlockEditor.md) · [명세](../spec/RichMarkdownBlockEditor.md) · [개선안](../improvements/RichMarkdownBlockEditor.md)

패키지 회귀 성공이 일반 CommonMark 원문 편집 지원이나 물리 기기 화면 검수를 뜻하지는 않습니다. 조사한 결함과 적용 범위는 개선안에 분리하고 ADR에는 현재 구현에 반영된 선택을 기록합니다.

## RichMarkdownHighlight ADR

기준일: 2026-10-06

상태는 **소급 기록 — 현재 구현 확인**입니다. 현재 소스에서 확인되는 선택과 비용을 기록하며 원 결정 날짜·결정자·팀 승인을 추정하지 않습니다. 비교안은 구조를 이해하기 위한 선택 비용 설명이며 새 도입 승인이나 실행 결과가 아닙니다.

| ADR | 결정 | 확인 근거 |
| --- | --- | --- |
| [0001 색칠 계산과 원문 보존](RichMarkdownHighlight-0001-actor-tokenization-source-fidelity.md) | 동시 접근을 보호하는 actor가 `JSContext`를 소유하고, HTML 대신 검증한 UTF-16 색칠 구간을 반환합니다. | `PrismHighlighter`, `nativeTokenize`, 공통 색 구간 계산 |

관련 문서: [아키텍처](../architecture/RichMarkdownHighlight.md) · [명세](../spec/RichMarkdownHighlight.md) · [개선안](../improvements/RichMarkdownHighlight.md)

다음 기록은 현재 계약을 바꾸는 실제 변경이 있을 때 추가합니다. 독립적인 성능 보장·새 문법·취소 경계 제안은 기존 ADR에 채택된 선택처럼 합치지 않습니다.

## RichMarkdownMermaid ADR

기준일: 2026-10-06

ADR-0001은 기존 구조의 소급 기록이며 ADR-0002는 사용자 요청에 따라 개선한 결정입니다. 현재 소스에서 확인되는 선택과 한계를 기록하며 원 결정 시점·결정자·팀 승인을 추정하지 않습니다. 대안은 선택 비용의 설명이며 새 설계 승인이나 성능 실측이 아닙니다.

| ADR | 현재 선택 | 핵심 한계 |
| --- | --- | --- |
| [0001 앱에 포함한 Mermaid와 웹 표시](RichMarkdownMermaid-0001-offline-webkit-render-boundary.md) | 앱에 포함한 JS·HTML을 읽고 원문은 함수 인자로 전달합니다. | Mermaid의 안전 설정·CSP에 의존하며 별도 앱 측 SVG 필터 없음 |
| [0002 취소와 높이 반영 경계](RichMarkdownMermaid-0002-request-cancellation-size-propagation.md) | 하나의 페이지 준비를 호출별로 기다리고, 양쪽 요청 번호·순차 실행·15초 대기 제한으로 그림과 높이를 반영합니다. | JavaScript 강제 중단이나 전체 처리 시간 15초를 보장하지 않음 |

관련 문서: [아키텍처](../architecture/RichMarkdownMermaid.md) · [명세](../spec/RichMarkdownMermaid.md) · [개선안](../improvements/RichMarkdownMermaid.md)

적용한 변경과 남은 검수는 개선안에 분리합니다. 현재 결함을 해결된 설계 이점으로 바꾸거나 요청 취소를 JavaScript 강제 중단으로 설명하지 않습니다.
