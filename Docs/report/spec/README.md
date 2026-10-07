# RichMarkdown 통합 명세

기준일: 2026-10-06 · 구현 기준: `0.9.0` 릴리스 대상 소스

이 문서는 앱이 선택할 공개 라이브러리와 공통 사용 조건을 설명합니다. 명세는 입력 조건·반환값·실패 처리처럼 라이브러리를 사용할 때 지켜야 할 규칙을 뜻합니다.

API별 규칙과 예외는 [모듈별 명세](../README.md#모듈별-문서)에, 현재 구현에서 발견한 문제는 [개선 기록](../improvements/README.md)에 있습니다. 위치 단위와 요청 순서 번호의 뜻은 [용어 안내](../glossary.md)도 함께 참고합니다.

## 패키지 계약

| ID | 현재 선언·동작 | 근거 |
| --- | --- | --- |
| PKG-01 | 패키지의 Swift 도구 버전 선언은 6.0, 최소 화면 지원 대상은 iOS 16입니다. macOS 12 선언은 Core를 빌드·실행하기 위한 조건이며 macOS 화면 라이브러리를 보장하지 않습니다. | [Package.swift](../../../Package.swift) |
| PKG-02 | 공개 라이브러리는 Renderer·BlockEditor·Highlight·Mermaid의 네 개입니다. Core는 내부 타깃입니다. | [Package.swift](../../../Package.swift) |
| PKG-03 | swift-markdown `0.4.0`, RaTeX `0.1.14`로 버전을 고정합니다. 이는 의존성 설정이며 모든 도구 환경에서 빌드 성공을 확인했다는 뜻은 아닙니다. | [Package.swift](../../../Package.swift) |
| PKG-04 | 코드 색칠과 다이어그램 구현체는 `RichMarkdownCodeBlockOptions`로 전달합니다. 기본값은 확장 없는 `.none`입니다. | [옵션과 인터페이스](../../../Sources/RichMarkdown/RichMarkdownCodeBlockOptions.swift) |
| PKG-05 | 스트리밍에서는 새 글자만 보내지 않고 최신 전체 문자열을 표시 모듈에 전달합니다. 블록 편집기는 사용자 입력을 문서로 편집하는 별도 라이브러리입니다. | [표시 명세](RichMarkdown.md), [편집 명세](RichMarkdownBlockEditor.md) |

## 수신 입력과 표시 제한

| ID | 현재 기준 | 해석·예외 |
| --- | --- | --- |
| PKG-06 | 기본 수식 구분자는 `\(...\)`, `\[...\]`입니다. 달러 기호 구분자는 앱이 별도로 켜야 사용하는 선택 기능입니다. | [Core 명세](RichMarkdownCore.md), [표시 명세](RichMarkdown.md) |
| PKG-07 | 전체 문서 분석의 입력 제한은 UTF-8 262,144바이트입니다. 초과하면 앞부분 65,536바이트와 생략 표시를 화면에 사용합니다. | 공개 설정이 아닌 내부 보호값입니다. 수식 구간만 찾는 경로의 반환값·인용 깊이 정책과 구분합니다. [Core 명세](RichMarkdownCore.md) |
| PKG-08 | 수식 원문 4,096 UTF-8 바이트, 인용 깊이 64, 표 열 32·셀 512 제한을 구현합니다. | 제한을 적용하는 입력·변환 시점은 [Core 명세](RichMarkdownCore.md)에 있습니다. |
| PKG-09 | Prism은 코드 블록 100,000 UTF-16 단위를 상한으로 둡니다. 미지원 언어나 실패에는 색칠할 구간이 없는 빈 목록을 반환합니다. | 화면의 색 상태를 처리하는 변경은 [표시 모듈 개선 기록](../improvements/RichMarkdown.md)에 구분합니다. [코드 색칠 명세](RichMarkdownHighlight.md) |
| PKG-10 | Mermaid는 원문 20,000 UTF-8 바이트를 검사하고 앱에 포함한 파일을 사용합니다. | 페이지를 읽는 대기와 그림을 만드는 완료 대기는 각각 별도 시간 제한입니다. [Mermaid 명세](RichMarkdownMermaid.md) |

Core가 원문에서 위치를 찾을 때는 UTF-8 바이트를 사용하고, TextKit 편집과 코드 색칠 범위는 UTF-16 단위를 사용합니다. Swift의 `Character` 개수와도 다릅니다. 한 이모지가 차지하는 길이가 단위마다 다르므로 위치를 그대로 섞어 쓰지 않습니다.

## 화면과 수명

| ID | 현재 계약 | 확인 위치 |
| --- | --- | --- |
| PKG-11 | 표시 모듈은 현재 요청 순서 번호(`generation`)와 일치하는 결과만 화면에 반영합니다. 실행 중인 계산의 즉시 취소나 이전 요청 결과의 모든 캐시 저장 차단을 보장하지는 않습니다. | [표시 명세](RichMarkdown.md) |
| PKG-12 | SwiftUI·UIKit은 Markdown 분석기와 표시 모델을 공유하지만 텍스트 선택·인라인 코드·블록 수식 표시 경로는 다릅니다. | [표시 명세](RichMarkdown.md) |
| PKG-13 | 테마와 글자 크기는 표시 요소별로 적용합니다. iOS 17·18 이상에서 사용하는 경로는 iOS 16 경로와 구분합니다. | [표시 명세](RichMarkdown.md), [Mermaid 명세](RichMarkdownMermaid.md) |
| PKG-14 | Mermaid는 앱 요청 번호와 JavaScript 임시 영역의 현재 요청 번호를 확인한 뒤 웹 화면과 높이를 반영합니다. 새 요청이 오면 이전 그림을 숨깁니다. 취소 후 남은 JavaScript 실행 상태는 다음 요청 전에 페이지를 다시 읽어 분리합니다. | [Mermaid 개선 기록](../improvements/RichMarkdownMermaid.md) |

## 검증을 읽는 기준

각 요구 표의 링크는 규칙을 구현한 코드와 관련 테스트를 찾는 데 사용합니다. 링크가 있다는 사실만으로 테스트 통과·코드 실행 비율·실제 화면 동작을 확인했다고 해석하지 않습니다. 실제 검사 결과와 아직 확인하지 않은 범위는 [검수 기록](../validation.md)에 구분합니다.
