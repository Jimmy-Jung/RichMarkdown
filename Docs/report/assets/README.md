# 보고서 시각자료

기준일: 2026-10-06

모듈의 의존 관계와 호출 순서는 Markdown 안의 Mermaid 도식으로 제공합니다. 아래 SVG는 요청 순서와 문자 위치 단위를 설명하는 Excalidraw 개념도입니다. 표시용 그림과 편집 원본을 함께 보관합니다. 그림 속 영문 용어는 [용어 안내](../glossary.md)와 아래 설명을 함께 참고합니다.

| 그림 | 핵심 주장 | SVG | 편집 원본 |
| --- | --- | --- | --- |
| 최신 대기 요청 유지 | A 실행 중 B가 대기하고 C가 오면, B 대신 C를 다음 실행으로 선택합니다. | [그림](core-coalescing.svg) | [원본](excalidraw/core-coalescing.excalidraw.md) |
| 최신 결과만 화면 반영 | 이전 계산이 끝나도 현재 요청 번호와 다르면 화면에 쓰지 않습니다. | [그림](render-latest-wins.svg) | [원본](excalidraw/render-latest-wins.excalidraw.md) |
| UTF-16 | 원문은 유지하고 색 범위만 반환합니다. | [그림](highlight-utf16.svg) | [원본](excalidraw/highlight-utf16.excalidraw.md) |
| Mermaid 취소 | 숨긴 임시 영역에서 검사한 뒤 현재 요청의 그림과 높이만 반영합니다. | [그림](mermaid-request-cancellation.svg) | [원본](excalidraw/mermaid-request-cancellation.excalidraw.md) |

그림의 `worker`는 작업 처리기, `pending`은 다음에 실행할 대기 입력, `generation`과 `g1`·`g2`는 요청 순서 번호입니다. A·B·C는 처리 흐름을 설명하기 위한 단순한 예이며 처리 시간 측정값이 아닙니다.

UTF-16 그림의 이모지는 보이는 글자 하나지만 UTF-16 단위 두 개를 차지합니다. Mermaid 그림의 `staging`은 표시 전 임시 영역, `DOM`은 웹 화면을 구성하는 문서 구조, `frame`은 브라우저 화면 갱신 단계입니다. 임시 영역에 숨겨 두는 것과 보안상 안전하게 실행하는 것은 서로 다른 조건입니다.

## 재생성

[build_diagrams.py](excalidraw/build_diagrams.py)는 `excalidraw-concept-diagrams` 스킬의
`slide_kit`와 `technical-document-writing` 스킬의 그림 내보내기 도구(exporter)를 사용합니다. 두 스킬의 설치 경로는
환경 변수로 지정합니다. 생성기 의존성을 문서에 복사하지 않았으며, 그림 원본·SVG 자체는
스킬 없이 읽거나 편집할 수 있습니다.

```sh
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$EXCALIDRAW_SKILL_ROOT/scripts" \
TECH_DOC_SKILL_ROOT="$TECH_DOC_SKILL_ROOT" \
python3 Docs/report/assets/excalidraw/build_diagrams.py \
  --platform ios --output-dir "$DOC_RENDER_OUTPUT"
```

`DOC_RENDER_OUTPUT`은 프로젝트 밖의 검증용 저장소로 지정합니다. 시스템에 저장소 정책이
있다면 먼저 그 정책대로 확인합니다. `TMPDIR`과 npm cache도 해당 정책의 저장소에 지정합니다.
중간 SVG와 검수 PNG는 출력 경로 아래에 두며, 완성 SVG만 문서의 `assets` 폴더에 복사합니다.
exporter는 `@moona3k/excalidraw-export@0.2.1`로 고정되어 있고 최초 실행 시 내려받을 수 있습니다.

편집 원본의 `Visual Brief`는 그림이 설명하려는 내용과 가상 예시의 범위를 적은 절입니다. 생성 후에는 PNG에서 글자·선·상자가 겹치지 않는지 확인합니다. 투명 SVG를 미리보기의 어두운 배경에서 읽을 수 있는지는 흰 배경 PNG 검사와 별도로 확인합니다.
