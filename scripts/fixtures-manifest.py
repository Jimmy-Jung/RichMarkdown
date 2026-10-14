#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
#
# Tests/Fixtures/manifest.json을 생성하거나 검증한다 (Tests/Fixtures/README.md §1).
#   scripts/fixtures-manifest.py            # 생성 (파일 목록·바이트·SHA-256)
#   scripts/fixtures-manifest.py --check [디렉터리]  # 디렉터리의 파일이 manifest와 일치하는지 검사 (Android sync 검증용)
import hashlib, json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Tests" / "Fixtures"
SKIP = {"manifest.json", "README.md", ".DS_Store"}


def entries(base: pathlib.Path):
    out = []
    for p in sorted(base.rglob("*")):
        if not p.is_file() or p.name in SKIP:
            continue
        data = p.read_bytes()
        out.append({"path": p.relative_to(base).as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return out


def main(argv):
    if argv[1:2] == ["--check"]:
        target = pathlib.Path(argv[2]) if len(argv) > 2 else ROOT
        expected = {e["path"]: e for e in json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["files"]}
        actual = {e["path"]: e for e in entries(target)}
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(p for p in expected.keys() & actual.keys() if expected[p]["sha256"] != actual[p]["sha256"])
        for label, items in (("missing", missing), ("extra", extra), ("changed", changed)):
            for p in items:
                print(f"{label}: {p}")
        ok = not (missing or extra or changed)
        print(f"fixtures manifest check: {'OK' if ok else 'MISMATCH'} ({len(actual)} files)")
        return 0 if ok else 1
    files = entries(ROOT)
    categories = {}
    for e in files:
        categories[e["path"].split("/")[0]] = categories.get(e["path"].split("/")[0], 0) + 1
    manifest = {"generatedBy": "scripts/fixtures-manifest.py", "fileCount": len(files), "categories": categories, "files": files}
    (ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"manifest written: {len(files)} files, categories={categories}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
