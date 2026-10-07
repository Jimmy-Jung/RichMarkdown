# RichMarkdown 패키지 보고서

기준일: 2026-10-06 · 구현 기준: `0.9.0` 릴리스 대상 소스

이 보고서는 RichMarkdown을 앱에 연결하거나 수정할 개발자를 위한 문서입니다. 각 모듈이 맡는 일, 입력·반환값·실패 처리 규칙, 현재 구조를 선택한 이유를 설명합니다.

설명은 릴리스 대상 구현을 기준으로 [패키지 설정](../../Package.swift), [소스](../../Sources), [테스트](../../Tests)를 대조했습니다. 테스트 코드가 있다는 사실과 실제로 실행해 통과했다는 사실은 구분합니다.

문서 구성은 플레이어 모듈 보고서의 흐름을 참고했습니다. 아키텍처 문서는 전체 구조를, ADR(Architecture Decision Record)은 구조를 선택한 이유를, 명세는 앱에서 지켜야 할 사용 규칙을 설명합니다. 낯선 표현은 [용어 안내](glossary.md)에서 뜻과 예시를 확인할 수 있습니다.

조사에서 발견한 문제, 이번 릴리스에 반영한 수정, 추가 측정이나 요구가 필요해 보류한 항목은 [개선 기록](improvements/README.md)에 나눠 적었습니다.

## 문서 지도

| 읽으려는 내용 | 문서 |
| --- | --- |
| 용어의 뜻과 실제 사용 예 | [용어 안내](glossary.md) |
| 패키지 전체의 모듈 경계와 데이터 흐름 | [architecture/README.md](architecture/README.md) |
| 통합 시 지켜야 할 계약과 플랫폼 조건 | [spec/README.md](spec/README.md) |
| 모듈별 구조 결정의 목록 | [adr/README.md](adr/README.md) |
| 코드와 문서 사이에서 발견한 개선점 | [improvements/README.md](improvements/README.md) |
| 이번 작성에서 실제로 수행한 검사와 한계 | [validation.md](validation.md) |
| 편집 가능한 개념도와 재생성 방법 | [assets/README.md](assets/README.md) |

문서는 모듈별 폴더 대신 `architecture/`, `spec/`, `adr/`, `improvements/`에 종류별로 모읍니다.
각 폴더의 `README.md`가 전체 개요·목차이며, 모듈 이름을 파일명에 붙여 대상을 구분합니다.
ADR 번호는 모듈별 번호를 유지하고 파일명 앞의 모듈 이름으로 구분합니다.

## 모듈별 문서

Swift Package Manager(SPM)가 관리하는 패키지는 하나이고, 함께 컴파일하는 소스 묶음인 라이브러리 타깃은 다섯 개입니다. 앱이 선택할 수 있는 공개 라이브러리(product)는 네 개입니다. `RichMarkdownCore`는 다른 모듈이 사용하는 내부 타깃이므로 앱이 별도 공개 라이브러리로 선택하지 않습니다.

| 타깃 | 역할 | 아키텍처 | 명세 | ADR |
| --- | --- | --- | --- | --- |
| `RichMarkdownCore` | Markdown 분석·수식 구간·입력 제한·대기 요청 관리 | [구조](architecture/RichMarkdownCore.md) | [계약](spec/RichMarkdownCore.md) | [결정](adr/README.md#richmarkdowncore-adr) |
| `RichMarkdown` | SwiftUI·UIKit의 문서·수식 표시 | [구조](architecture/RichMarkdown.md) | [계약](spec/RichMarkdown.md) | [결정](adr/README.md#richmarkdown-adr) |
| `RichMarkdownBlockEditor` | 블록 편집과 Markdown 변환 | [구조](architecture/RichMarkdownBlockEditor.md) | [계약](spec/RichMarkdownBlockEditor.md) | [결정](adr/README.md#richmarkdownblockeditor-adr) |
| `RichMarkdownHighlight` | Prism을 이용한 코드 색칠 구간 계산 | [구조](architecture/RichMarkdownHighlight.md) | [계약](spec/RichMarkdownHighlight.md) | [결정](adr/README.md#richmarkdownhighlight-adr) |
| `RichMarkdownMermaid` | 로컬 WebKit 기반 다이어그램 | [구조](architecture/RichMarkdownMermaid.md) | [계약](spec/RichMarkdownMermaid.md) | [결정](adr/README.md#richmarkdownmermaid-adr) |

예제 앱은 이 패키지를 사용하는 방법을 보여 줍니다. 패키지의 API가 보장하는 동작과 예제 앱 자체의 서비스·화면 기능은 각 명세에서 구분합니다.

Android와 같은 이름의 옵션이 있어도 객체 해제 시점, 계산 결과 재사용, 텍스트 선택 동작까지 같다고 가정하지 않습니다. 두 플랫폼의 차이는 각각의 명세를 함께 확인합니다.

## 읽는 방법

처음에는 전체 아키텍처를 읽고 사용하는 라이브러리의 명세로 이동합니다. 변경을 검토할 때는 해당 모듈의 ADR과 개선 기록을 함께 읽습니다. 요구 ID는 동작을 추적하기 위한 번호이며, 소스·테스트 링크에서 해당 구현을 확인할 수 있습니다.

Mermaid 도식은 문서 안의 코드 블록으로 제공합니다. 로컬에서 그림을 만들 수 있는지 검사하는 것과 GitHub·VSCode에서 실제 표시를 확인하는 것은 별개입니다. Excalidraw 개념도는 표시용 SVG와 편집 원본을 함께 제공합니다.
