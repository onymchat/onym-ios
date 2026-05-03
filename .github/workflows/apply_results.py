#!/usr/bin/env python3
"""Tick `[x]` in the issue body for every class that passed.

Usage:
    apply_results.py --body <body.md> --results <results.json> --out <new_body.md>

Only edits text **between** `<!-- UI_TESTS_START -->` and
`<!-- UI_TESTS_END -->`. Manual QA + everything else is byte-for-byte
preserved. Idempotent — running twice produces the same body.

Result-state semantics:
- "passed"  → flip `[ ]` to `[x]`
- "failed"  → flip `[x]` back to `[ ]` (rerun-friendly: a previously-passing
              class that now fails should re-open its checkbox so the
              reviewer notices)
- absent    → leave the line untouched (class was discovered but its
              bundle was missing, e.g. test-job killed before upload)
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


START = "<!-- UI_TESTS_START -->"
END = "<!-- UI_TESTS_END -->"

# Match `- [ ] <FQN>` or `- [x] <FQN>` and capture the box state + FQN.
LINE_RE = re.compile(r"^(?P<prefix>\s*-\s*\[)(?P<box>[ xX])(?P<mid>\]\s+)(?P<fqn>\S+)\s*$")


def rewrite_section(section: str, results: dict[str, str]) -> str:
    out_lines = []
    for line in section.splitlines():
        m = LINE_RE.match(line)
        if not m:
            out_lines.append(line)
            continue
        fqn = m.group("fqn")
        verdict = results.get(fqn)
        if verdict == "passed":
            box = "x"
        elif verdict == "failed":
            box = " "
        else:
            box = m.group("box")  # leave as-is
        out_lines.append(f"{m.group('prefix')}{box}{m.group('mid')}{fqn}")
    return "\n".join(out_lines) + ("\n" if section.endswith("\n") else "")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--body", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    body = pathlib.Path(args.body).read_text()
    results = json.loads(pathlib.Path(args.results).read_text())

    pattern = re.compile(
        re.escape(START) + r"(?P<section>.*?)" + re.escape(END),
        re.DOTALL,
    )
    if not pattern.search(body):
        sys.exit(f"FATAL: markers {START!r} / {END!r} not found in issue body")

    def replace(match: re.Match[str]) -> str:
        new_section = rewrite_section(match.group("section"), results)
        return f"{START}{new_section}{END}"

    pathlib.Path(args.out).write_text(pattern.sub(replace, body))
    return 0


if __name__ == "__main__":
    sys.exit(main())
