#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
#
# 두 플랫폼의 fixture 정규화 출력(Tests/Fixtures/README.md §3)을 비교한다.
#   scripts/fixtures-parity.py <ios-out-dir> <android-out-dir> [--json 결과.json] [--md 결과.md]
# 결과: 일치 / 예외 승인(parity-exceptions.json) / 미해결 차이 — 미해결이 있으면 종료 코드 1.
import argparse, json, pathlib, sys
from urllib.parse import unquote, urlsplit, urlunsplit


def canonical_href(href: str) -> str:
    """같은 대상의 표기 차이를 맞춘다: 퍼센트 디코딩, 비ASCII 호스트는 IDNA(punycode), 빈 포트(`host:`) 제거.
    iOS `URL`은 이렇게 정규화하고 Android `URI`는 원문을 보존한다 (Tests/Fixtures/README.md §4)."""
    text = unquote(href)
    try:
        parts = urlsplit(text)
        host = parts.hostname or ""
        if host and not host.isascii():
            host = host.encode("idna").decode("ascii")
        netloc = parts.netloc
        if parts.hostname:
            netloc = host + (f":{parts.port}" if parts.port else "")
        return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))
    except (ValueError, UnicodeError):
        return text

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Tests" / "Fixtures"


def load(dir_: pathlib.Path):
    docs = {}
    for p in dir_.rglob("*.json"):
        if p.name.startswith("fuzz-"):
            continue
        docs[p.relative_to(dir_).with_suffix("").as_posix()] = json.loads(p.read_text(encoding="utf-8"))
    return docs


def mask(obj, ignore):
    """예외로 승인된 필드(`href` 등)의 값을 지운다. `href`는 퍼센트 디코딩해 비교한다 — 같은 대상을 iOS URL은
    `%5D`로, Android URI는 `]`로 쓰는 표기 차이를 결함으로 세지 않는다 (Tests/Fixtures/README.md §4)."""
    if isinstance(obj, dict):
        return {k: ("<ignored>" if k in ignore else canonical_href(v) if k == "href" and isinstance(v, str) else mask(v, ignore)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [mask(v, ignore) for v in obj]
    return obj


def first_diff(a, b, path=""):
    if type(a) is not type(b):
        return path or "/", a, b
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return f"{path}.{k}", a.get(k, "<없음>"), b.get(k, "<없음>")
            d = first_diff(a[k], b[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(a, list):
        if len(a) != len(b):
            return f"{path}[len]", len(a), len(b)
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d:
                return d
        return None
    return None if a == b else (path or "/", a, b)


def compare_fuzz(ios_dir: pathlib.Path, android_dir: pathlib.Path):
    """퍼즈 덤프(fuzz-<seed>.jsonl)가 양쪽에 있으면 같은 순번의 입력이 같은지(생성기 일치)와 정규화 결과가 같은지 센다."""
    results = []
    for ios_file in sorted(ios_dir.glob("fuzz-*.jsonl")):
        android_file = android_dir / ios_file.name
        if not android_file.exists():
            continue
        ios_lines = ios_file.read_text(encoding="utf-8").splitlines()
        android_lines = android_file.read_text(encoding="utf-8").splitlines()
        same_input = same_doc = 0
        diffs = []
        for a, b in zip(ios_lines, android_lines):
            x, y = json.loads(a), json.loads(b)
            if x["input"] != y["input"]:
                diffs.append({"n": x["n"], "kind": "input"})
                continue
            same_input += 1
            d = first_diff(mask(x["doc"], set()), mask(y["doc"], set()))
            if d is None:
                same_doc += 1
            else:
                diffs.append({"n": x["n"], "kind": "doc", "path": d[0], "input": x["input"][:120]})
        results.append({"file": ios_file.name, "compared": min(len(ios_lines), len(android_lines)),
                        "sameInput": same_input, "sameDoc": same_doc, "diffs": diffs[:20], "diffCount": len(diffs)})
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ios"); ap.add_argument("android")
    ap.add_argument("--json"); ap.add_argument("--md")
    args = ap.parse_args()
    ios, android = load(pathlib.Path(args.ios)), load(pathlib.Path(args.android))
    exceptions = {e["id"]: e for e in json.loads((ROOT / "parity-exceptions.json").read_text(encoding="utf-8"))["exceptions"]}
    rows = []
    for fid in sorted(set(ios) | set(android)):
        if fid not in ios or fid not in android:
            rows.append({"id": fid, "status": "missing", "detail": "iOS 출력 없음" if fid not in ios else "Android 출력 없음"})
            continue
        exc = exceptions.get(fid)
        ignore = set(exc.get("ignore", [])) if exc else set()
        a, b = mask(ios[fid], ignore), mask(android[fid], ignore)
        d = first_diff(a, b)
        if d is None or (exc and not exc.get("ignore")):
            rows.append({"id": fid, "status": "exception" if exc else "match", "detail": exc["reason"] if exc else ""})
        else:
            rows.append({"id": fid, "status": "diff", "detail": f"{d[0]}: iOS={json.dumps(d[1], ensure_ascii=False)[:80]} / Android={json.dumps(d[2], ensure_ascii=False)[:80]}"})
    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    by_cat = {}
    for r in rows:
        cat = r["id"].split("/")[0]
        by_cat.setdefault(cat, {}).setdefault(r["status"], 0)
        by_cat[cat][r["status"]] += 1
    fuzz = compare_fuzz(pathlib.Path(args.ios), pathlib.Path(args.android))
    summary = {"counts": counts, "byCategory": by_cat, "rows": rows, "fuzz": fuzz}
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if args.md:
        lines = ["| 범주 | 일치 | 예외 승인 | 미해결 차이 | 누락 |", "|---|---:|---:|---:|---:|"]
        for cat, c in sorted(by_cat.items()):
            lines.append(f"| {cat} | {c.get('match',0)} | {c.get('exception',0)} | {c.get('diff',0)} | {c.get('missing',0)} |")
        lines.append(f"| **합계** | {counts.get('match',0)} | {counts.get('exception',0)} | {counts.get('diff',0)} | {counts.get('missing',0)} |")
        lines += ["", "| id | 상태 | 내용 |", "|---|---|---|"]
        for r in rows:
            if r["status"] != "match":
                lines.append(f"| `{r['id']}` | {r['status']} | {r['detail'].replace('|', '\\|')} |")
        pathlib.Path(args.md).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("parity:", counts)
    for f in fuzz:
        print(f"fuzz {f['file']}: 비교 {f['compared']} · 입력 일치 {f['sameInput']} · 결과 일치 {f['sameDoc']} · 차이 {f['diffCount']}")
        for d in f["diffs"][:5]:
            print("  ", d)
    for r in rows:
        if r["status"] in ("diff", "missing"):
            print(f"  {r['status']}: {r['id']} — {r['detail']}")
    return 1 if counts.get("diff") or counts.get("missing") or any(f["diffCount"] for f in fuzz) else 0


if __name__ == "__main__":
    sys.exit(main())
