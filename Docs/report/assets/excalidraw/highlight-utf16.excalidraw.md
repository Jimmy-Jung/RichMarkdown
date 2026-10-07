---

excalidraw-plugin: parsed
tags: [excalidraw]

---
Excalidraw의 MORE OPTIONS 메뉴에서 이 파일을 그림 보기로 열 수 있습니다.

## Visual Brief

이 절은 그림이 설명하려는 내용과 예시의 범위를 적은 그림 설명입니다. 그림의 영문 용어는 [용어 안내](../../glossary.md)에서 확인할 수 있습니다.

- 핵심 주장: 색칠을 위해 나눈 조각을 합친 결과가 원문과 같을 때만 UTF-16 구간을 반환합니다.
- 시작과 끝: 원문 문자열 입력부터 역할별 범위 출력까지
- 주 흐름: 입력 → 함수 → 범위
- 상태 변화: 문자열은 유지하고 표시 역할만 추가
- 등장 주체: 원문 · Prism · 범위 검증
- 상황 설명: A😀B는 위치 단위 설명을 위한 가상 예이며 실제 토큰 분류 결과가 아닙니다.

## Text Elements

하이라이트 — 원문 동일성과 UTF-16 범위 ^highlight-utf16-text-001
색을 입히기 위해 글자를 수정하거나 HTML로 바꾸지 않습니다. ^highlight-utf16-text-002
원문 String
A + 이모지 + B ^highlight-utf16-text-004
UTF-16 길이 = 4 ^highlight-utf16-text-005
Prism 토큰화
원문 재조합 검증 ^highlight-utf16-text-007
범위 + 색 역할
NSRange(location: 1, length: 2) ^highlight-utf16-text-015
A: 0 · 이모지: 1~2 · B: 3 ^highlight-utf16-text-017
문자 3개와 UTF-16 단위 4개를 구분합니다. ^highlight-utf16-text-018
원문 재조합이 다르거나 언어를 지원하지 않으면 빈 범위 목록을 반환합니다. ^highlight-utf16-text-019

%%
## Drawing
```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://github.com/zsviczian/obsidian-excalidraw-plugin",
  "elements": [
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700001,
      "isDeleted": false,
      "id": "highlight-utf16-text-001",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800001,
      "groupIds": [],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 40,
      "y": 20,
      "width": 412.06,
      "height": 27.5,
      "text": "하이라이트 — 원문 동일성과 UTF-16 범위",
      "fontSize": 22,
      "fontFamily": 2,
      "textAlign": "left",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "하이라이트 — 원문 동일성과 UTF-16 범위",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 22
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700002,
      "isDeleted": false,
      "id": "highlight-utf16-text-002",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#2d5be3",
      "backgroundColor": "transparent",
      "seed": 800002,
      "groupIds": [],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 40,
      "y": 54,
      "width": 398.44,
      "height": 17.5,
      "text": "색을 입히기 위해 글자를 수정하거나 HTML로 바꾸지 않습니다.",
      "fontSize": 14,
      "fontFamily": 2,
      "textAlign": "left",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "색을 입히기 위해 글자를 수정하거나 HTML로 바꾸지 않습니다.",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 14
    },
    {
      "type": "rectangle",
      "version": 1,
      "versionNonce": 700003,
      "isDeleted": false,
      "id": "highlight-utf16-rectangle-003",
      "fillStyle": "solid",
      "strokeWidth": 2,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "#f8d088",
      "seed": 800003,
      "groupIds": [
        "nodeinst:highlight-utf16:input"
      ],
      "frameId": null,
      "roundness": {
        "type": 3
      },
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 60,
      "y": 160,
      "width": 240,
      "height": 110
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700004,
      "isDeleted": false,
      "id": "highlight-utf16-text-004",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800004,
      "groupIds": [
        "nodeinst:highlight-utf16:input"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 117.11,
      "y": 191.25,
      "width": 125.78,
      "height": 47.5,
      "text": "원문 String\nA + 이모지 + B",
      "fontSize": 19,
      "fontFamily": 2,
      "textAlign": "center",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "원문 String\nA + 이모지 + B",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 19
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700005,
      "isDeleted": false,
      "id": "highlight-utf16-text-005",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#3aa387",
      "backgroundColor": "transparent",
      "seed": 800005,
      "groupIds": [],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 85,
      "y": 290,
      "width": 106.54,
      "height": 17.5,
      "text": "UTF-16 길이 = 4",
      "fontSize": 14,
      "fontFamily": 2,
      "textAlign": "left",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "UTF-16 길이 = 4",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 14
    },
    {
      "type": "rectangle",
      "version": 1,
      "versionNonce": 700006,
      "isDeleted": false,
      "id": "highlight-utf16-rectangle-006",
      "fillStyle": "solid",
      "strokeWidth": 3,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "#ffffff",
      "seed": 800006,
      "groupIds": [
        "nodeinst:highlight-utf16:tokenize"
      ],
      "frameId": null,
      "roundness": {
        "type": 3
      },
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 420,
      "y": 150,
      "width": 300,
      "height": 150
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700007,
      "isDeleted": false,
      "id": "highlight-utf16-text-007",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800007,
      "groupIds": [
        "nodeinst:highlight-utf16:tokenize"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 500.88,
      "y": 202.5,
      "width": 138.24,
      "height": 45.0,
      "text": "Prism 토큰화\n원문 재조합 검증",
      "fontSize": 18,
      "fontFamily": 2,
      "textAlign": "center",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "Prism 토큰화\n원문 재조합 검증",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 18
    },
    {
      "type": "line",
      "version": 1,
      "versionNonce": 700008,
      "isDeleted": false,
      "id": "highlight-utf16-line-008",
      "fillStyle": "solid",
      "strokeWidth": 3,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800008,
      "groupIds": [
        "connector:highlight-utf16:tokenize-in-l"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 460,
      "y": 120,
      "points": [
        [
          0,
          0
        ],
        [
          14,
          30
        ]
      ],
      "width": 14,
      "height": 30,
      "startArrowhead": null,
      "endArrowhead": null
    },
    {
      "type": "line",
      "version": 1,
      "versionNonce": 700009,
      "isDeleted": false,
      "id": "highlight-utf16-line-009",
      "fillStyle": "solid",
      "strokeWidth": 3,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800009,
      "groupIds": [
        "connector:highlight-utf16:tokenize-in-r"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 540,
      "y": 120,
      "points": [
        [
          0,
          0
        ],
        [
          -14,
          30
        ]
      ],
      "width": 14,
      "height": 30,
      "startArrowhead": null,
      "endArrowhead": null
    },
    {
      "type": "line",
      "version": 1,
      "versionNonce": 700010,
      "isDeleted": false,
      "id": "highlight-utf16-line-010",
      "fillStyle": "solid",
      "strokeWidth": 3,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800010,
      "groupIds": [
        "connector:highlight-utf16:tokenize-out-l"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 600,
      "y": 300,
      "points": [
        [
          0,
          0
        ],
        [
          -14,
          30
        ]
      ],
      "width": 14,
      "height": 30,
      "startArrowhead": null,
      "endArrowhead": null
    },
    {
      "type": "line",
      "version": 1,
      "versionNonce": 700011,
      "isDeleted": false,
      "id": "highlight-utf16-line-011",
      "fillStyle": "solid",
      "strokeWidth": 3,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800011,
      "groupIds": [
        "connector:highlight-utf16:tokenize-out-r"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 680,
      "y": 300,
      "points": [
        [
          0,
          0
        ],
        [
          14,
          30
        ]
      ],
      "width": 14,
      "height": 30,
      "startArrowhead": null,
      "endArrowhead": null
    },
    {
      "type": "arrow",
      "version": 1,
      "versionNonce": 700012,
      "isDeleted": false,
      "id": "highlight-utf16-arrow-012",
      "fillStyle": "solid",
      "strokeWidth": 2,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800012,
      "groupIds": [
        "connector:highlight-utf16:input-arrow"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 305,
      "y": 210,
      "points": [
        [
          0,
          0
        ],
        [
          85,
          0
        ]
      ],
      "width": 85,
      "height": 0,
      "startArrowhead": null,
      "endArrowhead": "arrow"
    },
    {
      "type": "arrow",
      "version": 1,
      "versionNonce": 700013,
      "isDeleted": false,
      "id": "highlight-utf16-arrow-013",
      "fillStyle": "solid",
      "strokeWidth": 2,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800013,
      "groupIds": [
        "connector:highlight-utf16:output-arrow"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 735,
      "y": 250,
      "points": [
        [
          0,
          0
        ],
        [
          65,
          0
        ]
      ],
      "width": 65,
      "height": 0,
      "startArrowhead": null,
      "endArrowhead": "arrow"
    },
    {
      "type": "rectangle",
      "version": 1,
      "versionNonce": 700014,
      "isDeleted": false,
      "id": "highlight-utf16-rectangle-014",
      "fillStyle": "solid",
      "strokeWidth": 2,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "#d797fb",
      "seed": 800014,
      "groupIds": [
        "nodeinst:highlight-utf16:output"
      ],
      "frameId": null,
      "roundness": {
        "type": 3
      },
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 820,
      "y": 170,
      "width": 365,
      "height": 110
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700015,
      "isDeleted": false,
      "id": "highlight-utf16-text-015",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800015,
      "groupIds": [
        "nodeinst:highlight-utf16:output"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 869.94,
      "y": 205.0,
      "width": 265.12,
      "height": 40.0,
      "text": "범위 + 색 역할\nNSRange(location: 1, length: 2)",
      "fontSize": 16,
      "fontFamily": 2,
      "textAlign": "center",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "범위 + 색 역할\nNSRange(location: 1, length: 2)",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 16
    },
    {
      "type": "rectangle",
      "version": 1,
      "versionNonce": 700016,
      "isDeleted": false,
      "id": "highlight-utf16-rectangle-016",
      "fillStyle": "solid",
      "strokeWidth": 2,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#ededed",
      "backgroundColor": "#ededed",
      "seed": 800016,
      "groupIds": [
        "nodeinst:highlight-utf16:offsets"
      ],
      "frameId": null,
      "roundness": {
        "type": 3
      },
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 820,
      "y": 315,
      "width": 365,
      "height": 40
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700017,
      "isDeleted": false,
      "id": "highlight-utf16-text-017",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#1b1b1b",
      "backgroundColor": "transparent",
      "seed": 800017,
      "groupIds": [
        "nodeinst:highlight-utf16:offsets"
      ],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 908.1,
      "y": 325.0,
      "width": 188.8,
      "height": 20.0,
      "text": "A: 0 · 이모지: 1~2 · B: 3",
      "fontSize": 16,
      "fontFamily": 2,
      "textAlign": "center",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "A: 0 · 이모지: 1~2 · B: 3",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 16
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700018,
      "isDeleted": false,
      "id": "highlight-utf16-text-018",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#2d5be3",
      "backgroundColor": "transparent",
      "seed": 800018,
      "groupIds": [],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 60,
      "y": 395,
      "width": 277.90000000000003,
      "height": 17.5,
      "text": "문자 3개와 UTF-16 단위 4개를 구분합니다.",
      "fontSize": 14,
      "fontFamily": 2,
      "textAlign": "left",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "문자 3개와 UTF-16 단위 4개를 구분합니다.",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 14
    },
    {
      "type": "text",
      "version": 1,
      "versionNonce": 700019,
      "isDeleted": false,
      "id": "highlight-utf16-text-019",
      "fillStyle": "solid",
      "strokeWidth": 1,
      "strokeStyle": "solid",
      "roughness": 0,
      "opacity": 100,
      "angle": 0,
      "strokeColor": "#e5533a",
      "backgroundColor": "transparent",
      "seed": 800019,
      "groupIds": [],
      "frameId": null,
      "roundness": null,
      "boundElements": [],
      "updated": 1788134400000,
      "link": null,
      "locked": false,
      "x": 60,
      "y": 430,
      "width": 483.56,
      "height": 17.5,
      "text": "원문 재조합이 다르거나 언어를 지원하지 않으면 빈 범위 목록을 반환합니다.",
      "fontSize": 14,
      "fontFamily": 2,
      "textAlign": "left",
      "verticalAlign": "top",
      "containerId": null,
      "originalText": "원문 재조합이 다르거나 언어를 지원하지 않으면 빈 범위 목록을 반환합니다.",
      "autoResize": true,
      "lineHeight": 1.25,
      "baseline": 14
    }
  ],
  "appState": {
    "theme": "light",
    "viewBackgroundColor": "transparent",
    "currentItemStrokeColor": "#000000",
    "currentItemFontFamily": 2,
    "gridSize": 10
  },
  "files": {}
}
```
%%
