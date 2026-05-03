#!/usr/bin/env python3
"""Parse one or more `.xcresult` bundles into per-class pass/fail.

Usage:
    parse_xcresult.py
        --bundle <dir> --target <name>  [...repeat...]
        --results <out.json>
        --comment-md <out.md>

For each bundle, runs `xcrun xcresulttool get test-results tests --format
json --path <dir>` and walks the resulting tree:

    Test Plan
      └── (Unit|UI) test bundle
            └── Test Suite             ← class name (XCTestCase subclass)
                  └── Test Case        ← method, with `result`

A class "passes" when no descendant Test Case has `result == "Failed"`.
Skipped tests don't count against pass status (the E2E test skips when
`ONYM_INTEGRATION` is unset; that's not a failure).

The `--target` argument prefixes class names so the FQN matches what
`release-from-issue.yml` writes into the issue body
(`OnymIOSTests.GroupRepositoryTests`, `OnymIOSUITests.AnchorsUITests`,
…).

Outputs:
    --results        — JSON `{ <FQN>: "passed" | "failed" }`
    --comment-md     — markdown listing each failed class with the
                       first failed method + first ~5 lines of the
                       failure backtrace. Empty file when no failures.

Bundles that don't exist (download-artifact may have skipped them when
the test job died before upload) are silently ignored — the apply step
will leave their classes as-is.
"""
from __future__ import annotations

import argparse
import itertools
import json
import pathlib
import subprocess
import sys
from typing import Iterable


BACKTRACE_LINES = 5


def run_xcresulttool(bundle: pathlib.Path) -> dict:
    """Invoke xcresulttool and return the parsed JSON tree."""
    proc = subprocess.run(
        [
            "xcrun", "xcresulttool", "get", "test-results", "tests",
            "--path", str(bundle),
            "--format", "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.exit(
            f"xcresulttool failed for {bundle}:\n"
            f"  stdout: {proc.stdout[:200]}\n"
            f"  stderr: {proc.stderr[:200]}"
        )
    return json.loads(proc.stdout)


def find_xcresult_dir(root: pathlib.Path) -> pathlib.Path | None:
    """download-artifact unzips the bundle directly into the path; that's
    enough for xcresulttool. But if a future runner change wraps it, walk
    one level looking for an `Info.plist` companion that confirms it's
    really a `.xcresult` bundle."""
    if not root.exists():
        return None
    if (root / "Info.plist").exists():
        return root
    for child in root.iterdir():
        if child.suffix == ".xcresult" or (child / "Info.plist").exists():
            return child
    # download-artifact often produces an inner directory whose name
    # matches the artifact name. Walk one more level.
    for child in root.iterdir():
        if child.is_dir():
            inner = find_xcresult_dir(child)
            if inner is not None:
                return inner
    return None


def walk_classes(node: dict, target: str) -> Iterable[tuple[str, str, list[dict]]]:
    """Yield `(fqn, suite_result, test_cases)` for every Test Suite under
    `node`. `suite_result` is xcresulttool's roll-up; `test_cases` is the
    list of leaf Test Case dicts so the caller can find the first failing
    method + its failure messages.
    """
    nt = node.get("nodeType", "")
    name = node.get("name", "")
    if nt == "Test Suite" and name:
        cases = list(_collect_test_cases(node))
        yield f"{target}.{name}", node.get("result", ""), cases
        return  # don't recurse into nested suites — keep granularity at top suite
    for child in node.get("children", []):
        yield from walk_classes(child, target)


def _collect_test_cases(node: dict) -> Iterable[dict]:
    if node.get("nodeType") == "Test Case":
        yield node
        return
    for child in node.get("children", []):
        yield from _collect_test_cases(child)


def class_passed(test_cases: list[dict]) -> bool:
    """Pass when no test case is `Failed`. `Skipped` and `Expected Failure`
    don't count against the class.
    """
    for case in test_cases:
        if case.get("result") == "Failed":
            return False
    return True


def first_failure(test_cases: list[dict]) -> tuple[str, list[str]] | None:
    """Return `(method_name, failure_lines)` for the first failed case,
    truncated to BACKTRACE_LINES. None if no case failed.
    """
    for case in test_cases:
        if case.get("result") != "Failed":
            continue
        method = case.get("name", "<unknown>")
        msgs = []
        for child in case.get("children", []):
            if child.get("nodeType") == "Failure Message":
                # `name` carries the message; sub-children sometimes
                # carry stack frames.
                msgs.append(child.get("name", ""))
                for grand in child.get("children", []):
                    msgs.append(grand.get("name", ""))
        # Trim to BACKTRACE_LINES non-empty lines
        flat = list(
            itertools.islice(
                (line for line in msgs if line.strip()),
                BACKTRACE_LINES,
            )
        )
        return method, flat
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bundle", action="append", default=[],
        help="Path to a downloaded xcresult artifact directory.",
    )
    parser.add_argument(
        "--target", action="append", default=[],
        help="Test target name to prefix class names with (one per --bundle).",
    )
    parser.add_argument("--results", required=True, help="Output JSON path.")
    parser.add_argument(
        "--comment-md", required=True,
        help="Output markdown path for the failure-summary comment.",
    )
    args = parser.parse_args()

    if len(args.bundle) != len(args.target):
        sys.exit("Each --bundle needs a matching --target.")

    results: dict[str, str] = {}
    failure_blocks: list[str] = []

    for bundle_root, target in zip(args.bundle, args.target):
        bundle = find_xcresult_dir(pathlib.Path(bundle_root))
        if bundle is None:
            print(f"[skip] no xcresult bundle under {bundle_root!r}")
            continue
        tree = run_xcresulttool(bundle)
        for plan in tree.get("testNodes", []):
            for fqn, _suite_result, cases in walk_classes(plan, target):
                if class_passed(cases):
                    results[fqn] = "passed"
                else:
                    results[fqn] = "failed"
                    failure = first_failure(cases)
                    if failure is None:
                        continue
                    method, lines = failure
                    backtrace = (
                        "\n".join(f"    {ln}" for ln in lines)
                        if lines
                        else "    _(no failure message captured)_"
                    )
                    failure_blocks.append(
                        f"- **{fqn}** — first failure in `{method}`:\n{backtrace}"
                    )

    pathlib.Path(args.results).write_text(json.dumps(results, sort_keys=True, indent=2))
    pathlib.Path(args.comment_md).write_text(
        "\n".join(failure_blocks) + ("\n" if failure_blocks else "")
    )

    passed = sum(1 for v in results.values() if v == "passed")
    failed = sum(1 for v in results.values() if v == "failed")
    print(f"Parsed {len(results)} class results: {passed} passed, {failed} failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
