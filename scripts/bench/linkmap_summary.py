#!/usr/bin/env python3
# Author: JunyoungJung
# Date: 2026-10-14
"""ld 링크 맵(`-Xlinker -map`)에서 모듈별 코드·데이터 크기를 합산한다.

심볼 크기를 오브젝트 파일 경로로 묶고, 경로 패턴으로 모듈을 정한다. 패턴에 안 걸리는 것은 `other`다.
dead strip 이후 남은 심볼만 맵에 있으므로 실제 링크 결과 기준이다(서명·리소스·LINKEDIT 제외).

  linkmap_summary.py <linkmap.txt> [--json out.json]
  linkmap_summary.py --self-test
"""
import argparse
import json
import re

# 위에서부터 첫 일치. Release 빌드에서 SwiftPM 타깃은 `<Target>.o` 하나로 prelink되고(archive 실측),
# Debug/증분 빌드에서는 `<Target>.build/` 아래 오브젝트로 남는다. 두 모양을 다 받는다.
def target(name):
    escaped = re.escape(name)
    return rf"/{escaped}\.o$|/{escaped}\.build/"


MODULES = [
    ("RichMarkdownCore", target("RichMarkdownCore")),
    ("RichMarkdown", target("RichMarkdown")),
    ("RichMarkdownBlockEditor", target("RichMarkdownBlockEditor")),
    ("RichMarkdownHighlight", target("RichMarkdownHighlight")),
    ("RichMarkdownMermaid", target("RichMarkdownMermaid")),
    ("RaTeX (Swift)", target("RaTeX")),
    ("RaTeX (Rust FFI)", r"libratex_ffi\.a"),
    ("swift-markdown", target("Markdown")),
    ("cmark-gfm", r"/cmark-gfm(-extensions)?\.o$|/cmark-gfm(-extensions)?\.build/"),
    ("Demo app", r"/RichMarkdownDemo\.build/|/(AttachmentDemo|BlockEditorDemo|BlockKeyboardToolbar|ChatDemo|"
                 r"CodeBlockExtensionDemo|EditorDemo|SSEDemo|RichMarkdownDemoApp|UIKitChatDemo|UIKitSSEDemo)\.o$"),
]
OBJECT_RE = re.compile(r"^\[\s*(\d+)\]\s+(.*)$")
SYMBOL_RE = re.compile(r"^0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s+(.*)$")


def module_of(path):
    for name, pattern in MODULES:
        if re.search(pattern, path):
            return name
    return "other"


def summarize(lines):
    objects, sizes, section = {}, {}, None
    for line in lines:
        if line.startswith("# Object files:"):
            section = "objects"
        elif line.startswith("# Sections:"):
            section = "sections"
        elif line.startswith("# Symbols:"):
            section = "symbols"
        elif line.startswith("# Dead Stripped Symbols:"):
            section = None
        elif section == "objects" and (match := OBJECT_RE.match(line)):
            objects[int(match.group(1))] = match.group(2)
        elif section == "symbols" and (match := SYMBOL_RE.match(line)):
            module = module_of(objects.get(int(match.group(2)), ""))
            sizes[module] = sizes.get(module, 0) + int(match.group(1), 16)
    total = sum(sizes.values())
    return {"total_bytes": total, "modules": [
        {"module": name, "bytes": size, "kib": round(size / 1024, 1), "share_pct": round(100 * size / total, 1)}
        for name, size in sorted(sizes.items(), key=lambda kv: -kv[1])
    ]}


def self_test():
    sample = """# Object files:
[  0] linker synthesized
[  1] /x/RichMarkdownCore.build/Objects-normal/arm64/MathScanner.o
[  2] /x/Release-iphoneos/Markdown.o
[  3] /x/libratex_ffi.a(ratex.o)
# Sections:
# Address\tSize\tSegment\tSection
# Symbols:
# Address\tSize\tFile\tName
0x100000000\t0x00000100\t[  1] _scan
0x100000100\t0x00000040\t[  2] _doc
0x100000140\t0x00000040\t[  3] _ratex_parse
0x100000180\t0x00000010\t[  0] __mh_execute_header
# Dead Stripped Symbols:
<<dead>>\t0x00000999\t[  1] _gone
""".splitlines()
    result = {m["module"]: m["bytes"] for m in summarize(sample)["modules"]}
    assert result == {"RichMarkdownCore": 256, "swift-markdown": 64, "RaTeX (Rust FFI)": 64, "other": 16}, result
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("linkmap", nargs="?")
    parser.add_argument("--json")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    with open(args.linkmap, encoding="utf-8", errors="replace") as handle:
        result = summarize(handle)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
    print("| 모듈 | KiB | 비중 |\n|---|---:|---:|")
    for item in result["modules"]:
        print(f"| {item['module']} | {item['kib']} | {item['share_pct']}% |")
    print(f"| 합계 | {round(result['total_bytes'] / 1024, 1)} | 100% |")


if __name__ == "__main__":
    main()
