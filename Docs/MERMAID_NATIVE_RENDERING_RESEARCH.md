# Mermaid 네이티브 렌더링 조사 기록

- 작성자: JunyoungJung
- 작성일: 2026-09-09 (KST)
- 상태: **조사 완료, 논의 보류** — 구현 승인이나 의존성 선택은 아직 없다.

## 1. 이 문서의 범위

이 문서는 AI 답변의 Mermaid 코드 블록을 **WebView 없이 실제 네이티브 다이어그램으로 표시할 수 있는지** 검토한 기록이다. 현재 확정된 요구는 이것 하나다.

- WebView를 사용하지 않는다.
- 실제 네이티브 화면 렌더링을 목표로 한다.

아래는 아직 정해지지 않았다.

- 외부 라이브러리를 채택할지, 금지할지
- 지원할 다이어그램 종류와 Mermaid 문법 범위
- 미지원·오류·스트리밍 중 미완성 입력의 fallback 방식
- 전체 Mermaid 호환성을 목표로 할지
- JavaScript 런타임 자체도 금지할지. WebView 배제와 같은 결정으로 해석하지 않는다.

따라서 이 문서의 라이브러리 비교, 자체 구현 경로, 기간은 **결정 제안과 조사 근거**이며 구현 계획이나 승인된 범위가 아니다.

## 2. 현재 SwiftLatex와 기존 비목표

현재 SwiftLatex에는 Mermaid를 파싱하거나 네이티브 다이어그램으로 그리는 구현이 없다. [`DEVELOPMENT.md`](../DEVELOPMENT.md)의 명시적 비목표에도 `Mermaid`, `HTML 실행`, `WebView`가 포함되어 있다.

이 비목표는 새 요구가 생기면 재검토할 수 있는 기존 경계다. 이 조사 문서는 해당 경계를 이미 변경하거나 Mermaid 지원을 확정하지 않는다.

## 3. 조사 요약

Mermaid 원문은 다이어그램 DSL이며, 코드 색칠을 위한 syntax highlight와는 별개다. 공식 JavaScript 렌더러를 WebView에서 실행해 SVG를 만드는 방식은 이번 네이티브 요구와는 비교 대상일 뿐 채택 방향이 아니다. 이때 실행되는 것은 렌더러의 JavaScript이며, Mermaid 원문 자체를 JavaScript 코드로 실행한다는 뜻은 아니다. [공식 렌더링 API](https://mermaid.js.org/config/usage.html)

네이티브 경로는 다음 세 층이 모두 필요하다.

```text
Mermaid source
  → parser / 진단 / diagram model
  → CoreText 라벨 측정
  → layout (노드 위치·간선 경로·그룹 크기)
  → CoreGraphics draw + SwiftUI/UIKit host
```

도형을 그리는 일보다 layout이 어렵다. 순환 그래프, 긴 라벨, 간선 교차와 우회, 중첩 subgraph, 서로 다른 diagram별 시간축·행렬·트리 모델은 각각 별도의 배치 규칙을 요구한다.

## 4. 검토한 오픈소스 후보

### 4.1 BeautifulMermaidSwift

- 저장소: [lukilabs/beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift)
- 라이선스: [MIT](https://github.com/lukilabs/beautiful-mermaid-swift/blob/main/LICENSE)
- SPM manifest: Swift tools 5.9, iOS 15 / macOS 12 / Mac Catalyst 15 / visionOS 1, 외부 의존성은 [`lukilabs/elk-swift`](https://github.com/lukilabs/elk-swift) `from: 1.0.2` 하나다. [`Package.swift`](https://github.com/lukilabs/beautiful-mermaid-swift/blob/main/Package.swift)는 `swiftLanguageVersions`를 별도로 선언하지 않는다.
- 문서상 지원: flowchart, state, sequence, class, ER, XY chart. [`README`](https://github.com/lukilabs/beautiful-mermaid-swift#supported-diagram-types)

화면 렌더링에서 중요한 사실은 `MermaidLayer`가 직접 `CALayer.draw(in:)`을 override하는 것이 아니라는 점이다. `MermaidLayer`는 source를 parse하고 `GraphLayout`과 `DiagramRenderer`를 거쳐 `PreparedDiagram.render: (CGContext, CGRect) -> Void`를 준비한다. 실제 UIKit 화면 호출점은 [`MermaidView.draw(_:)`](https://github.com/lukilabs/beautiful-mermaid-swift/blob/main/Sources/BeautifulMermaidSwift/Views/MermaidView.swift)이며, 여기서 `UIGraphicsGetCurrentContext()`를 얻어 `prepared.render(...)`를 호출한다. SwiftUI [`MermaidDiagramView`](https://github.com/lukilabs/beautiful-mermaid-swift/blob/main/Sources/BeautifulMermaidSwift/Views/MermaidDiagramView.swift)는 iOS 16+ `UIViewRepresentable`로 이 `MermaidView`를 감싼다.

즉 실제 경로는 다음과 같다.

```text
MermaidDiagramView (SwiftUI, iOS 16+)
  → MermaidView.draw(_:) (UIKit)
  → PreparedDiagram.render(CGContext, CGRect)
  → DiagramRenderer.render(...)
```

[`DiagramRenderer`](https://github.com/lukilabs/beautiful-mermaid-swift/blob/main/Sources/BeautifulMermaidSwift/Render/DiagramRenderer.swift#L25-L45)는 class, ER, sequence, state/flowchart 공용, XY chart를 분기한다. 문서의 여섯 종류 중 state와 flowchart는 같은 draw 경로를 공유한다.

제한도 명시되어 있다. HTML label, click callback/link, tooltip, FontAwesome, `<br>`, 일부 `style`/`linkStyle`, subgraph styling은 무시되거나 예상 밖 결과가 날 수 있다. [`README 제한`](https://github.com/lukilabs/beautiful-mermaid-swift#limitations) 최신 release는 조사 당시 `1.0.4`(2026-04-27)였고, 이 공개 정보만으로 전체 Mermaid 호환성이나 장기 운영 성숙도를 단정할 수 없다. [`Releases`](https://github.com/lukilabs/beautiful-mermaid-swift/releases)

### 4.2 Australware/swift-mermaid

- 저장소: [Australware/swift-mermaid](https://github.com/Australware/swift-mermaid)
- 조사 기준은 `0.3.0`이다. Swift tools 5.10, iOS 16 / macOS 14를 선언한다. README의 macOS-only 표기는 manifest와 일치하지 않았다. [Package.swift](https://github.com/Australware/swift-mermaid/blob/0.3.0/Package.swift)
- MIT 라이선스이며 Dagre의 Swift 구현을 저장소 내부에 포함한다. SPM 외부 의존성이 없다는 것과 배치 알고리즘을 전부 새로 만들었다는 것은 다른 의미다. [저장소](https://github.com/Australware/swift-mermaid/tree/0.3.0)
- 공개 모델은 `MermaidScene`의 rect/path/text 계열이며, 공개 출력은 CGImage/PDF/SVG다. 직접 `CGContext` draw의 핵심 구현은 private이어서, 앱 화면에 붙이려면 공개 scene을 그리는 어댑터 등이 필요하다. [MermaidScene.swift](https://github.com/Australware/swift-mermaid/blob/0.3.0/Sources/Mermaid/Core/MermaidScene.swift), [CGRenderer.swift](https://github.com/Australware/swift-mermaid/blob/0.3.0/Sources/Mermaid/Core/CGRenderer.swift)
- 조사 당시 renderer dispatch는 flowchart, state, sequence, class, pie, ER, gitGraph, journey, architecture의 9종이었다. Gantt, mindmap 등은 지원하지 않았다. [Mermaid.swift](https://github.com/Australware/swift-mermaid/blob/0.3.0/Sources/Mermaid/Mermaid.swift)

두 후보 모두 WebView 없이 CoreGraphics 계열 출력을 목표로 하지만, 지원 범위와 공개 화면 API가 다르다. 두 후보를 SwiftLatex에 연결해 빌드하거나 기기에서 실행한 검증은 하지 않았다. 이 비교는 소스·문서 조사이며 특정 라이브러리 채택 결론이 아니다.

## 5. 외부 라이브러리 없이 구현할 때의 구조

의존성을 추가하지 않는다면 SwiftLatex 내부에 다음 모델을 구현해야 한다.

```text
String
  → Lexer / Parser
  → Diagnostic + Diagram AST
  → Layout input graph / chart model
  → CoreText label measurement
  → Layout result (node frame, edge path, group frame)
  → CoreGraphics renderer
  → SwiftUI/UIKit host + accessibility elements
```

조사에 따른 판단으로는 핵심 난점이 graph layout에 있다. directed graph에는 단계별 배치, 순서, 간선 교차와 경로 계산이 필요하고, subgraph는 중첩 컨테이너와 외부 간선 규칙을 더한다. sequence는 participant와 메시지 순서, Gantt/timeline은 시간축, Sankey는 흐름 폭 등 종류별 규칙을 요구한다. 라벨 크기는 layout 전에 측정해야 한다. Apple은 [CoreText](https://developer.apple.com/documentation/coretext)와 [CoreGraphics](https://developer.apple.com/documentation/coregraphics)를 제공하지만, Mermaid 파서와 자동 배치는 별도로 구현해야 한다.

## 6. Flowchart 문법: 최소 범위와 후순위

공식 기준은 [Mermaid Flowcharts - Basic Syntax](https://mermaid.js.org/syntax/flowchart.html)와 [원문 Markdown](https://github.com/mermaid-js/mermaid/blob/develop/docs/syntax/flowchart.md)이다. 아래는 지원을 확정한 목록이 아니라, 네이티브 flowchart를 설계할 때 빠뜨리기 쉬운 문법을 나눈 것이다.

### 초기 최소 범위 후보

| 항목 | 예시 | 필요한 이유 |
|---|---|---|
| 선언과 방향 | `flowchart LR` | `graph` 별칭과 `TB`/`TD`/`BT`/`LR`/`RL` 방향 |
| 노드 ID와 재선언 | `A[첫 이름]` 뒤 `A[마지막 이름]` | 같은 ID의 마지막 label을 사용하고 이후 간선에서 label을 생략할 수 있음 |
| 기본 도형 | `A["처리"]`, `B("처리")`, `C{"조건"}`, `D(("원"))`, `E[("DB")]`, `F(["종료"])` | 사각형·라운드·마름모·원·원통·캡슐형 |
| 간선과 라벨 | `A -->\|성공\| B`, `A -- 성공 --> B`, `A --- B`, `A -.-> B`, `A ==> B` | 방향, 무방향, 점선, 굵은선과 의미 라벨 |
| 축약 구문 | `A & B --> C --> D` | 여러 시작점과 연쇄 간선 |
| 주석과 문자열 | `%% 설명`, `A["한글·특수문자"]` | 주석 제거, Unicode/특수문자 label |
| 문자 이스케이프 | `A["값 #35;1"]` | 문자 코드 해석 |
| 문장 구분 | 줄바꿈, 세미콜론 | 여러 문장 분리 |
| 기본 subgraph | `subgraph api [API] ... end` | 그룹 표현과 그룹 바깥 간선 |

앞선 대화에서 기본 subgraph는 확장 항목으로도 설명했다. 초기 범위에 넣을지는 아직 선택하지 않았다. `...`는 위 표에서 본문 생략을 뜻하며 실행 가능한 Mermaid 문법 예제가 아니다.

공식 Mermaid는 node ID를 여러 번 정의했을 때 마지막 text를 사용한다고 설명한다. [Node with text](https://github.com/mermaid-js/mermaid/blob/develop/docs/syntax/flowchart.md#a-node-with-text) `%%` 주석은 독립 행에 있어야 하며 그 행 끝까지 parser가 무시한다. [Comments](https://github.com/mermaid-js/mermaid/blob/develop/docs/syntax/flowchart.md#comments) Subgraph의 내부 노드가 외부와 연결되면 내부 `direction`이 부모 방향을 상속하는 제한도 있다. [Subgraphs](https://github.com/mermaid-js/mermaid/blob/develop/docs/syntax/flowchart.md#subgraphs)

### 후순위 확장 후보

- v11.3+ `A@{ shape: ... }`의 확장 도형 30여 종, icon/image shape
- edge ID, animation, circle/cross/bidirectional arrow, invisible link, 간선 길이 rank 힌트
- nested/collapsible subgraph와 내부 direction
- Markdown label과 자동 줄바꿈, `<br/>`를 개행으로 해석하는 호환 처리
- `style`, `classDef`, `class`, `:::`, `linkStyle`, curve
- click/link/tooltip 및 앱 액션·외부 URL 보안 정책

이 문법은 렌더러만의 문제가 아니다. style/class는 별도 cascade 모델, click/link는 앱 정책, image/icon은 원격 리소스 정책, collapse는 간선 재연결 및 visibility 모델을 요구한다.

### 공통 설정·접근성 및 다른 종류의 주요 문법

- 접근성: `accTitle: 제목`, `accDescr: 설명`, 여러 줄의 `accDescr { ... }`. 네이티브 접근성 정보에 연결하는 방안을 제안했으며 아직 API를 정하지 않았다. [공식 접근성 문법](https://mermaid.js.org/config/accessibility.html)
- 설정: YAML frontmatter, `%%{init: ...}%%` 지시문, 테마·배치 설정. 자체 엔진이 지원할 설정을 별도로 정해야 하며 `layout: elk`를 지정했다고 ELK 구현이 제공되는 것은 아니다. [공식 설정 문법](https://mermaid.js.org/intro/syntax-reference.html#configuration)

| 종류 | 조사에서 목록화한 주요 문법 |
|---|---|
| [Sequence](https://mermaid.js.org/syntax/sequenceDiagram.html) | participant, actor, 메시지·응답, 활성화, Note, loop, alt/else, opt, par, autonumber |
| [State](https://mermaid.js.org/syntax/stateDiagram.html) | 상태 선언, `[*]`, 상태 전이, 복합 상태, choice, fork/join, 병렬 상태 |
| [Class](https://mermaid.js.org/syntax/classDiagram.html) | 클래스, 속성·메서드, 접근 수준, 상속·구현·연관·합성, 다중성 |
| [ER](https://mermaid.js.org/syntax/entityRelationshipDiagram.html) | 엔티티, 속성·자료형, PK/FK/UK, 관계·카디널리티 |
| [Pie](https://mermaid.js.org/syntax/pie.html) | 제목, 항목별 수치, 값 표시 |

실패·미지원·스트리밍 중 불완전한 입력은 일부 내용을 누락한 다이어그램 대신 원문 코드 블록으로 표시하는 방안을 제안했다. 파싱 성공만으로 스트림이 완료됐다고 판단할 수는 없으며, 표시 전환 시점은 미정이다.

## 7. Mermaid 공식 메뉴의 30종

공식 Mermaid 문서 메뉴에는 다음 30종이 나열된다. 이 목록은 **모두 구현하기로 정한 목록이 아니다.** 종류별 문법과 layout 모델이 다르다는 작업 범위 확인용이다.

1. Flowchart
2. Swimlanes Diagram
3. Sequence Diagram
4. Class Diagram
5. State Diagram
6. Entity Relationship Diagram
7. User Journey
8. Gantt
9. Pie Chart
10. Quadrant Chart
11. Requirement Diagram
12. GitGraph (Git)
13. C4 Diagram
14. Mindmaps
15. Timeline
16. ZenUML
17. Sankey
18. XY Chart
19. Block Diagram
20. Packet
21. Kanban
22. Architecture
23. Radar
24. Event Modeling
25. Treemap
26. Venn
27. Ishikawa
28. Wardley
29. Cynefin
30. TreeView

출처: [Mermaid Diagram Syntax 메뉴](https://mermaid.js.org/intro/syntax-reference.html). 2026-09-09 조사 시점의 문서 목록이며, 특정 패키지 버전에서 30종 모두를 사용할 수 있음을 검증한 목록은 아니다.

재사용 가능한 layout 계열은 일부 있다. flowchart/state/class/ER은 directed graph, sequence는 participant timeline, Gantt/timeline은 time scale, mindmap/tree는 tree/containment, Sankey는 flow width로 묶을 수 있다. 다만 공통 기반이 있어도 각 종류의 parser, semantic model, layout 규칙, rendering과 회귀 fixture는 별도 작업으로 남는다.

## 8. 기간에 관한 이전 대화의 잠정 기록

아래 기간은 사용자에게 전달된 **거친 가정**이며 실측이 아니다. 1인 숙련 Swift 개발자가 전담하고, 기존 SwiftLatex의 Markdown parsing·SwiftUI/UIKit host를 재사용한다고 가정했다. 픽셀 단위 동일 출력, Mermaid 미래 문법 유지보수, 외부 export 기능은 포함하지 않는다.

| 수준 | 잠정 기간 | 의미 |
|---|---:|---|
| 30종의 제한된 데모 | 6–12개월 | 각 종류의 대표 예제 중심으로 문법과 배치를 제한 |
| 문서화한 기본 문법의 제품 수준 | 18–36개월 | 오류·미지원 입력 처리, 테마, 접근성, 회귀 검증을 포함 |
| 폭넓은 Mermaid 호환 | 3–5년 이상 | 다양한 옵션·예외·style·복잡 layout까지 넓힌 호환성 |

이 수치는 30종 전체 지원을 결정했다는 뜻이 아니다. 대표 종류를 먼저 실험해 parser·layout·텍스트 측정의 실제 비용과 요구되는 fallback을 확인한 뒤 다시 산정해야 한다.

## 9. 다음 논의로 남긴 결정

Mermaid 논의는 여기까지 보류하고 코드 하이라이트 설계로 돌아간다. Mermaid를 다시 검토할 때에는 다음을 하나씩 결정한다.

1. 외부 라이브러리 채택/금지 여부
2. 첫 지원 diagram 종류와 문법 표
3. native renderer 실패·미지원·미완성 source의 fallback
4. 테마와 접근성 계약
5. 대표 종류 실험 결과를 바탕으로 한 일정 재산정
