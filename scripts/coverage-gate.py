#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
#
# xccov JSON에서 Sources/<모듈>/ 파일의 줄 커버리지를 모듈별·전체로 계산하고 기준 미달이면 1로 끝난다.
#   scripts/coverage-gate.py <coverage.json> [--core 0.90] [--total 0.80] [--json 결과.json]
# 같은 소스가 여러 테스트 번들에 정적 링크되어 중복으로 나타나므로 파일별 최대값을 쓴다 (check-core-coverage.sh와 같은 규칙).
import argparse, json, sys
from collections import defaultdict


def per_module(report):
    best = {}
    for target in report.get("targets", []):
        for entry in target.get("files", []):
            path = entry.get("path", "")
            if "/Sources/" not in path or "/checkouts/" in path:
                continue
            covered, executable = entry.get("coveredLines", 0), entry.get("executableLines", 0)
            if path not in best or covered > best[path][0]:
                best[path] = (covered, executable, path.split("/Sources/", 1)[1].split("/", 1)[0])
    modules = defaultdict(lambda: [0, 0])
    for covered, executable, module in best.values():
        modules[module][0] += covered
        modules[module][1] += executable
    return dict(modules)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("coverage")
    ap.add_argument("--core", type=float, default=0.90)
    ap.add_argument("--total", type=float, default=0.80)
    ap.add_argument("--json")
    args = ap.parse_args()
    modules = per_module(json.load(open(args.coverage)))
    if "RichMarkdownCore" not in modules:
        print("RichMarkdownCore 파일이 coverage 리포트에 없다", file=sys.stderr)
        return 2
    total_c = sum(c for c, _ in modules.values())
    total_e = sum(e for _, e in modules.values())
    rows = {m: {"covered": c, "executable": e, "ratio": c / e if e else 0.0} for m, (c, e) in sorted(modules.items())}
    rows["TOTAL"] = {"covered": total_c, "executable": total_e, "ratio": total_c / total_e if total_e else 0.0}
    for name, r in rows.items():
        print(f"{name:28} {r['covered']:6}/{r['executable']:6}  {r['ratio']:6.1%}")
    if args.json:
        open(args.json, "w").write(json.dumps(rows, indent=2) + "\n")
    failures = []
    if rows["RichMarkdownCore"]["ratio"] < args.core:
        failures.append(f"Core {rows['RichMarkdownCore']['ratio']:.1%} < {args.core:.0%}")
    if rows["TOTAL"]["ratio"] < args.total:
        failures.append(f"전체 {rows['TOTAL']['ratio']:.1%} < {args.total:.0%}")
    print("coverage gate:", "FAIL — " + ", ".join(failures) if failures else "OK")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
