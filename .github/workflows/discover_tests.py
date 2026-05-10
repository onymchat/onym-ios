#!/usr/bin/env python3
"""Discover XCTestCase classes + their `test_*` methods, extract the
`///` doc comments preceding each, and emit a markdown checklist for
the release-issue body.

Output shape:
    - [ ] OnymIOSUITests.<Class> — <first sentence of class doc>
      - <first sentence of test doc>
      - ...

Per-class lines stay tickable (the same `apply_results.py` flips them
to `[x]`). Per-test bullets are nested non-checkbox items, emitted only
when the test method has an authored `///` doc — keeps unit tests
listed by class without exploding the issue body with humanized
method names.

Usage:
    discover_tests.py --root <repo> --out <md>

The script prints the discovered class count to stdout for the
workflow's summary step.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

DOC_RE   = re.compile(r"^\s*///\s?(.*)$")
CLASS_RE = re.compile(r"^\s*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase")
FUNC_RE  = re.compile(r"^\s*func\s+(test_[A-Za-z_0-9]+)\s*\(")
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def first_sentence(lines: list[str]) -> str:
    """Collapse the first contiguous paragraph (up to the first blank
    `///` separator) into one line, then trim to the first sentence."""
    para: list[str] = []
    for line in lines:
        if line.strip() == "":
            if para:
                break
            continue
        para.append(line.strip())
    flat = " ".join(para).strip()
    if not flat:
        return ""
    return SENTENCE_END.split(flat, maxsplit=1)[0]


def parse_file(path: pathlib.Path) -> list[dict]:
    """Return [{name, doc, tests:[{name, doc}]}] for classes in this file."""
    classes: list[dict] = []
    pending: list[str] = []
    current: dict | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        m = DOC_RE.match(raw)
        if m:
            pending.append(m.group(1).rstrip())
            continue
        # Blank lines and `// MARK: ...` style non-doc comments don't
        # break the doc-block → declaration association.
        if not raw.strip() or raw.lstrip().startswith("//"):
            continue
        cls = CLASS_RE.match(raw)
        if cls:
            current = {"name": cls.group(1), "doc": first_sentence(pending), "tests": []}
            classes.append(current)
            pending = []
            continue
        fn = FUNC_RE.match(raw)
        if fn and current is not None:
            current["tests"].append({"name": fn.group(1), "doc": first_sentence(pending)})
            pending = []
            continue
        # Unrelated code line — drop pending docs.
        pending = []
    return classes


def render(targets: dict[str, list[pathlib.Path]]) -> tuple[str, int]:
    lines: list[str] = []
    class_count = 0
    for target_name, files in targets.items():
        for f in files:
            for cls in parse_file(f):
                class_count += 1
                fqn = f"{target_name}.{cls['name']}"
                head = f"- [ ] {fqn}"
                if cls["doc"]:
                    head += f" — {cls['doc']}"
                lines.append(head)
                for t in cls["tests"]:
                    if t["doc"]:
                        lines.append(f"  - {t['doc']}")
    return "\n".join(lines), class_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="Repository root.")
    parser.add_argument("--out", required=True, help="Markdown output path.")
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    targets = {
        "OnymIOSTests":   sorted((root / "Tests" / "OnymIOSTests").rglob("*.swift")),
        "OnymIOSUITests": sorted((root / "Tests" / "OnymIOSUITests").rglob("*.swift")),
    }
    md, count = render(targets)
    pathlib.Path(args.out).write_text(md + "\n", encoding="utf-8")
    print(count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
