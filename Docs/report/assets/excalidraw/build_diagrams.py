#!/usr/bin/env python3
"""보고서 개념도 재생성. 기준일: 2026-10-06.

EXCALIDRAW_SKILL_ROOT/scripts를 PYTHONPATH로 지정하고 --output-dir에
검증용 저장소를 전달합니다. SVG·PNG 임시 출력은 그 경로에만 저장합니다.
"""

import argparse
import shutil
from pathlib import Path

from slide_kit import (
    INACTIVE, LIME, ORANGE, PANEL, PINK, PURPLE, TEAL,
    TXT_BLUE, TXT_GRAY, TXT_GREEN, TXT_RED,
    ann, arrow, box, brief, build_all, chip, hopper, lane, marker,
    new_diagram, task, title,
)

REPORT_PLATFORM = "ios"


def coalescing(out):
    d = new_diagram("core-coalescing", "실행 하나와 최신 대기 하나", brief(
        claim="A 실행 중 B와 C가 도착하면 B 대기를 C로 교체합니다.",
        span="A 제출부터 C 실행까지", flow="왼쪽에서 오른쪽으로 시간 진행",
        change="B 대기 → C 대기", actors="제출자 · pending · worker",
        caption="요청 A·B·C를 단순화한 예이며 처리 시간은 측정값이 아닙니다."), out)
    title(d, "Coalescing — 대기는 최신 입력 하나", "계산 중인 A를 즉시 중단하지 않고, 다음 실행으로 C를 고릅니다.")
    a = lane(d, "input", 130, "입력 제출", label_w=160)
    p = lane(d, "pending", 260, "최신 대기", label_w=160)
    w = lane(d, "worker", 390, "실행 worker", label_w=160)
    marker(d, "replace", 660, "C 제출 시점", y_rule_to=465)
    task(d, "a", 235, a, 140, "A 제출 · g1", ORANGE)
    task(d, "b", 470, a, 140, "B 제출 · g2", ORANGE)
    task(d, "c", 695, a, 140, "C 제출 · g3", ORANGE)
    task(d, "wait-b", 470, p, 160, "B 대기", INACTIVE)
    task(d, "wait-c", 695, p, 160, "C 대기", LIME)
    task(d, "run-a", 235, w, 600, "A 실행 중", TEAL)
    task(d, "run-c", 895, w, 190, "C 실행", LIME)
    arrow(d, "b-pending", 540, a + 28, [[0, 0], [0, 74]])
    arrow(d, "c-pending", 765, a + 28, [[0, 0], [0, 74]])
    ann(d, "B는 실행되지 않습니다: C가 대기 슬롯을 교체했습니다.", 235, 490, color=TXT_RED)
    ann(d, "generation을 전달한 제출은 더 작은 번호가 최신 대기를 덮지 못합니다.", 235, 520, color=TXT_BLUE)
    return d


def latest_wins(out):
    d = new_diagram("render-latest-wins", "화면 게시와 계산 완료는 다른 시점", brief(
        claim="이전 generation의 계산 결과는 현재 화면에 게시하지 않습니다.",
        span="요청 g1부터 요청 g2의 화면 게시까지", flow="왼쪽에서 오른쪽으로 시간 진행",
        change="현재 g1 → 현재 g2", actors="render model · worker · 화면 게시",
        caption="계산 완료 순서와 화면 반영 조건을 분리한 가상 예입니다."), out)
    title(d, "Latest-wins — 현재 generation만 화면에 게시", "늦게 끝난 이전 작업의 결과를 새 요청의 화면에 섞지 않습니다.")
    m = lane(d, "model", 130, "render model", label_w=160)
    w = lane(d, "worker", 260, "계산 worker", label_w=160)
    u = lane(d, "ui", 390, "화면 게시", label_w=160)
    marker(d, "new", 645, "새 요청 g2", y_rule_to=465)
    task(d, "g1", 235, m, 370, "현재 generation = 1", INACTIVE)
    task(d, "g2", 680, m, 440, "현재 generation = 2", LIME)
    task(d, "old-work", 235, w, 490, "g1 계산은 이미 시작됨", TEAL)
    task(d, "old-result", 775, w, 140, "g1 완료", PINK)
    task(d, "next-work", 985, w, 180, "g2 계산 · 완료", PURPLE)
    task(d, "drop", 775, u, 160, "g1 ≠ g2\n게시하지 않음", PINK, size=13)
    task(d, "publish", 1005, u, 180, "g2 = 현재\n화면 반영", LIME, size=13)
    arrow(d, "drop-result", 845, w + 28, [[0, 0], [0, 74]], color=TXT_RED, style="dashed")
    arrow(d, "publish-result", 1095, w + 28, [[0, 0], [0, 74]])
    ann(d, "세대 검사는 화면 게시를 결정합니다. 계산의 즉시 중단을 보장하지 않습니다.", 235, 490, color=TXT_BLUE)
    ann(d, "공유 수식 캐시의 재사용과 캐시 적재 시점은 별도 계약입니다.", 235, 520, color=TXT_GRAY)
    return d


def utf16(out, platform):
    d = new_diagram("highlight-utf16", "원문은 보존하고 색 범위만 반환", brief(
        claim="원문과 토큰 조각이 같을 때만 UTF-16 색 범위를 반환합니다.",
        span="원문 문자열 입력부터 역할별 범위 출력까지", flow="입력 → 함수 → 범위",
        change="문자열은 유지하고 표시 역할만 추가", actors="원문 · Prism · 범위 검증",
        caption="A😀B는 위치 단위 설명을 위한 가상 예이며 실제 토큰 분류 결과가 아닙니다."), out)
    title(d, "하이라이트 — 원문 동일성과 UTF-16 범위", "색을 입히기 위해 글자를 수정하거나 HTML로 바꾸지 않습니다.")
    box(d, "input", 60, 160, 240, 110, "원문 String\nA + 이모지 + B", fill=ORANGE, size=19)
    ann(d, "UTF-16 길이 = 4", 85, 290, color=TXT_GREEN)
    hopper(d, "tokenize", 420, 150, 300, 150, "Prism 토큰화\n원문 재조합 검증", size=18)
    arrow(d, "input-arrow", 305, 210, [[0, 0], [85, 0]])
    arrow(d, "output-arrow", 735, 250, [[0, 0], [65, 0]])
    label = "NSRange(location: 1, length: 2)" if platform == "ios" else "Utf16Range(start=1, end=3)"
    box(d, "output", 820, 170, 365, 110, "범위 + 색 역할\n" + label, fill=PURPLE, size=16)
    chip(d, "offsets", 820, 315, 365, "A: 0 · 이모지: 1~2 · B: 3", size=16)
    ann(d, "문자 3개와 UTF-16 단위 4개를 구분합니다.", 60, 395, color=TXT_BLUE)
    ann(d, "원문 재조합이 다르거나 언어를 지원하지 않으면 빈 범위 목록을 반환합니다.", 60, 430, color=TXT_RED)
    return d


def mermaid_cancellation(out, platform):
    d = new_diagram("mermaid-request-cancellation", "최신 요청의 SVG만 게시합니다", brief(
        claim="SVG 계산과 DOM 게시를 나누고 현재 request ID만 반영합니다.",
        span="A 렌더 시작부터 B 요청과 이전 결과 폐기까지", flow="왼쪽에서 오른쪽으로 시간 진행",
        change="A 요청 → A 취소 + B 요청", actors="native 요청 · JavaScript 계산 · DOM과 높이 게시",
        caption="최신 ID와 게시 경계를 설명한 단순화한 예이며 처리 시간은 측정값이 아닙니다."), out)
    title(d, "Mermaid — 최신 request ID만 DOM과 높이에 반영", "숨겨진 staging에서 계산하고 마지막 frame 확인 뒤 현재 결과를 게시합니다.")
    n = lane(d, "native", 130, "native 뷰", label_w=160)
    j = lane(d, "js", 260, "JavaScript", label_w=160)
    r = lane(d, "result", 390, "DOM / 높이 게시", label_w=160)
    marker(d, "cancel", 650, "B 요청 · A 취소", y_rule_to=465)
    task(d, "a-request", 235, n, 200, "A 요청 시작", ORANGE)
    task(d, "b-request", 705, n, 200, "B 요청 시작", LIME)
    task(d, "js-a", 235, j, 350, "A 렌더 실행", TEAL)
    task(d, "js-late", 705, j, 450, "A 계산 완료 · 이전 ID", PINK)
    gate = "A ID ≠ 최신 ID\nDOM·높이 게시하지 않음"
    task(d, "gate", 745, r, 290, gate, PANEL, size=15)
    arrow(d, "native-drop", 900, j + 28, [[0, 0], [0, 74]], color=TXT_RED, style="dashed")
    ann(d, "최신 ID가 아니면 계산이 끝나도 화면과 높이에 반영하지 않습니다.", 235, 490, color=TXT_RED)
    ann(d, "native 취소와 JS 게시 검사를 연결하고, 남은 작업은 다음 요청에서 재로드로 격리합니다.", 235, 520, color=TXT_BLUE)
    return d


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("ios", "android"), required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if args.platform != REPORT_PLATFORM:
        parser.error("이 저장소의 보고서 플랫폼과 일치하는 인자를 사용하세요.")
    source_dir = Path(__file__).resolve().parent
    staging = args.output_dir.resolve()
    if staging.is_relative_to(source_dir.parents[3]):
        parser.error("검증 출력은 프로젝트 밖의 지정 저장소를 사용하세요.")
    builders = {
        "core-coalescing": coalescing,
        "render-latest-wins": latest_wins,
        "highlight-utf16": lambda out: utf16(out, args.platform),
        "mermaid-request-cancellation": lambda out: mermaid_cancellation(out, args.platform),
    }
    generated = build_all(builders, source_dir=source_dir,
                          svg_dir=staging / "svg", png_dir=staging / "renders")
    for svg in generated:
        shutil.copyfile(svg, source_dir.parent / svg.name)


if __name__ == "__main__":
    main()
