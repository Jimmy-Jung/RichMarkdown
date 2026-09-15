#!/bin/bash
# RichMarkdownCore line coverage gate (DEVELOPMENT.md §8).
# 사용법: scripts/check-core-coverage.sh <coverage.json> [threshold=0.80]
# xccov JSON에서 Sources/RichMarkdownCore/ 파일들의 라인 가중 커버리지를 계산해
# threshold 미만이면 nonzero로 종료한다. -enableCodeCoverage YES만으로 합격 처리하지 않는다.
set -euo pipefail

coverage_json="${1:?usage: $0 <coverage.json> [threshold]}"
threshold="${2:-0.80}"

python3 - "$coverage_json" "$threshold" <<'PY'
import json
import sys

coverage_path, threshold = sys.argv[1], float(sys.argv[2])
report = json.load(open(coverage_path))

# Core 소스는 테스트 번들에 정적 링크되어 여러 target에 나타난다. 파일별 최대값을 취한다.
per_file = {}
for target in report.get("targets", []):
    for file_entry in target.get("files", []):
        path = file_entry.get("path", "")
        if "/Sources/RichMarkdownCore/" not in path:
            continue
        covered = file_entry.get("coveredLines", 0)
        executable = file_entry.get("executableLines", 0)
        prev = per_file.get(path)
        if prev is None or covered > prev[0]:
            per_file[path] = (covered, executable)

if not per_file:
    print("RichMarkdownCore 파일이 coverage 리포트에 없다", file=sys.stderr)
    sys.exit(2)

covered = sum(c for c, _ in per_file.values())
executable = sum(e for _, e in per_file.values())
ratio = covered / executable if executable else 0.0
print(f"RichMarkdownCore line coverage: {ratio:.1%} ({covered}/{executable})")
for path, (c, e) in sorted(per_file.items()):
    name = path.rsplit("/", 1)[-1]
    print(f"  {name}: {c / e:.1%}" if e else f"  {name}: n/a")

sys.exit(0 if ratio >= threshold else 1)
PY
