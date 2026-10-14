#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""퍼즈 덤프(iOS·Android `fuzz-<seed>.jsonl`)에서 정규화 결과가 다른 입력을 원인별로 나눈다.

    python3 scripts/fuzz-residual.py <ios.jsonl> <android.jsonl> [--json out.json] [--limit 10000]

분류(위에서부터 먼저 맞는 것):
  목록 안 표 행       — 목록 항목 안의 표 개수가 다르다(D-05, 게으른 줄 이어 붙이기)
  표 인식            — 목록 밖의 표 개수가 다르다(D-05, 열 수 불일치 관대 처리)
  표 행 범위         — 표 수는 같고 행 수가 다르다(D-05, 모자란 들여쓰기·`>` 줄을 표 행으로 잇는지)
  코드 블록 끝 공백 줄 — 코드 본문이 끝 공백·빈 줄만 다르다(D-07, 닫히지 않은 펜스의 마지막 공백 줄)
  강조·취소선 규칙    — 블록 구조와, 강조 기호(*·_·~)를 뺀 글자가 같다(D-06, 구분자 해석 차이)
  참조 정의 뒤 빈 항목 — 링크 참조 정의 바로 다음 줄의 `*`를 Android만 빈 목록으로 본다(D-08)
  펜스 정보의 ~       — 백틱 펜스 정보 문자열에 `~`가 있으면 Android만 펜스로 보지 않는다(D-09)
  기타               — 위에 해당하지 않는다. 사람이 입력을 보고 판정해야 한다
"""
import argparse
import importlib.util
import json
import pathlib
import re
import sys

DELIMITERS = str.maketrans("", "", "*_~")
# D-08: 참조 정의 줄 바로 뒤의 빈 목록 표식 줄. D-09: 정보 문자열에 `~`가 든 백틱 펜스.
REFERENCE_THEN_EMPTY_ITEM = re.compile(r"^ {0,3}\[[^\]\n]+\]:[^\n]*\n {0,3}[*+-][ \t]*$", re.M)
BACKTICK_FENCE_WITH_TILDE = re.compile(r"^[ \t]*`{3,}[^`\n]*~", re.M)

# 패리티 판정은 fixtures-parity.py와 같은 정규화(링크 주소 표기 등)를 쓴다.
_spec = importlib.util.spec_from_file_location("fixtures_parity", pathlib.Path(__file__).with_name("fixtures-parity.py"))
parity = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(parity)


def same_document(ios_doc, android_doc):
    return parity.first_diff(parity.mask(ios_doc, set()), parity.mask(android_doc, set())) is None


def table_rows(blocks):
    """모든 표(목록·인용 안 포함)의 본문 행 수 합."""
    total = 0
    for block in blocks:
        if block.get("t") == "table":
            total += len(block.get("rows", []))
        for item in block.get("items", []):
            total += table_rows(item)
        total += table_rows(block.get("blocks", []) + block.get("children", []))
    return total


def block_types(blocks, inside_list=False):
    """블록 종류를 깊이 우선으로 펼친다. 목록 안의 블록은 'list:' 접두사를 붙인다."""
    types = []
    for block in blocks:
        types.append(("list:" if inside_list else "") + str(block.get("t")))
        for item in block.get("items", []):
            types.extend(block_types(item, inside_list=True))
        types.extend(block_types(block.get("blocks", []) + block.get("children", []), inside_list))
    return types


def plain_text(node):
    """문서의 모든 글자를 이어 붙인다(강조 여부·블록 경계 무시)."""
    if isinstance(node, dict):
        parts = [node[key] for key in ("v", "code", "latex") if isinstance(node.get(key), str)]
        parts += [plain_text(value) for value in node.values() if isinstance(value, (list, dict))]
        return "".join(parts)
    if isinstance(node, list):
        return "".join(plain_text(item) for item in node)
    return ""


def classify(ios_doc, android_doc, source=""):
    ios_types, android_types = block_types(ios_doc["blocks"]), block_types(android_doc["blocks"])
    if ios_types != android_types:
        # 표 개수가 다르면 표 확장 해석 차이다(한쪽이 표로 본 줄을 다른 쪽은 문단으로 본다).
        if ios_types.count("list:table") != android_types.count("list:table"):
            return "목록 안 표 행"
        if ios_types.count("table") != android_types.count("table"):
            return "표 인식"
        # 표 수는 같고 행 수가 다르다: commonmark-java가 들여쓰기가 모자라거나 `>`로 시작하는 다음 줄까지 표 행으로
        # 이어 붙이고, cmark-gfm은 GFM 명세대로 표를 끝내 그 줄을 문단·인용으로 둔다(D-05).
        if table_rows(ios_doc["blocks"]) != table_rows(android_doc["blocks"]):
            return "표 행 범위"
        if _lists(android_types) > _lists(ios_types) and REFERENCE_THEN_EMPTY_ITEM.search(source):
            return "참조 정의 뒤 빈 항목"
        # Android는 펜스 여는 줄을 문단으로 두고, 뒤의 닫는 펜스가 새 코드 블록을 연다(블록 순서만 달라진다).
        if BACKTICK_FENCE_WITH_TILDE.search(source):
            return "펜스 정보의 ~"
        return "기타"
    if table_rows(ios_doc["blocks"]) != table_rows(android_doc["blocks"]):
        return "표 행 범위"
    if table_columns(ios_doc["blocks"]) != table_columns(android_doc["blocks"]):
        return "표 인식"
    if code_texts(ios_doc["blocks"], strip=True) == code_texts(android_doc["blocks"], strip=True) and \
            code_texts(ios_doc["blocks"]) != code_texts(android_doc["blocks"]):
        return "코드 블록 끝 공백 줄"
    if plain_text(ios_doc).translate(DELIMITERS) == plain_text(android_doc).translate(DELIMITERS):
        return "강조·취소선 규칙"
    return "기타"


def _lists(types):
    """목록 안팎을 가리지 않고 목록 블록(ul·ol) 개수를 센다."""
    return sum(1 for t in types if t.split(":")[-1] in ("ul", "ol"))


def table_columns(blocks):
    """표마다 열 수(정렬 배열 길이)."""
    columns = []
    for block in blocks:
        if block.get("t") == "table":
            columns.append(len(block.get("align", [])))
        for item in block.get("items", []):
            columns += table_columns(item)
        columns += table_columns(block.get("blocks", []) + block.get("children", []))
    return columns


def code_texts(blocks, strip=False):
    """코드 블록 본문. strip이면 끝 공백·빈 줄을 뺀다(닫히지 않은 펜스의 마지막 공백 줄 처리 차이)."""
    texts = []
    for block in blocks:
        if block.get("t") == "code":
            texts.append(block.get("code", "").rstrip() if strip else block.get("code", ""))
        for item in block.get("items", []):
            texts += code_texts(item, strip)
        texts += code_texts(block.get("blocks", []) + block.get("children", []), strip)
    return texts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ios")
    parser.add_argument("android")
    parser.add_argument("--json")
    parser.add_argument("--limit", type=int, default=sys.maxsize, help="앞에서부터 비교할 입력 수(예: 10000)")
    args = parser.parse_args()
    counts, others, compared, same = {}, [], 0, 0
    with open(args.ios, encoding="utf-8") as ios_file, open(args.android, encoding="utf-8") as android_file:
        for ios_line, android_line in zip(ios_file, android_file):
            if compared >= args.limit:
                break
            compared += 1
            ios, android = json.loads(ios_line), json.loads(android_line)
            if ios["input"] != android["input"]:
                counts["입력 불일치"] = counts.get("입력 불일치", 0) + 1
                continue
            if same_document(ios["doc"], android["doc"]):
                same += 1
                continue
            kind = classify(ios["doc"], android["doc"], ios["input"])
            counts[kind] = counts.get(kind, 0) + 1
            if kind == "기타":
                others.append({"n": ios["n"], "input": ios["input"][:200]})
    result = {"compared": compared, "sameDoc": same, "counts": counts, "other": others}
    print(json.dumps({k: v for k, v in result.items() if k != "other"}, ensure_ascii=False))
    for item in others[:10]:
        print("기타", item["n"], repr(item["input"]))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
