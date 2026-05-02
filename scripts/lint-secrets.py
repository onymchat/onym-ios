#!/usr/bin/env python3
"""
Static check: forbid reads of identity secrets outside IdentityRepository.

The mnemonic (BIP39 recovery phrase) and the persisted private key
bytes (nostr secp256k1, BLS12-381) are owned by `IdentityRepository`.
Any code outside the repository that reads them — even in passing —
invites the secret to leak through logs, crash reports, screenshots,
third-party SDK call sites, or accidental serialization.

Default-deny. To allow a specific read, annotate the line itself or
any `//` comment line in the contiguous block directly above with
`// onym:allow-secret-read`. Each suppression should justify itself
in code review and ideally name a reason inline:

    // Rendered behind biometric on backup screen — production reveal
    // UI owns the gating, this view just renders.
    // onym:allow-secret-read
    let phrase = identity.recoveryPhrase

Usage:
    python3 scripts/lint-secrets.py
Exits 0 on success, 1 on any unsuppressed violation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Files allowed to construct / inspect secrets. Adding to this list
# requires a justification in code review — these are the only files
# that legitimately need to touch raw secret material.
ALLOWED: set[str] = {
    "Sources/OnymIOS/Identity/IdentityRepository.swift",
    "Sources/OnymIOS/Identity/KeychainStore.swift",
    "Sources/OnymIOS/Identity/Identity.swift",
    "Tests/OnymIOSTests/IdentityRepositoryTests.swift",
}

# Field-access patterns that read identity secrets. The regex requires
# a `.` prefix so we only catch member access (not declarations or
# unrelated local variables that happen to share a name).
PATTERNS: list[tuple[str, str]] = [
    (r"\.nostrSecretKey\b", "nostr secp256k1 secret key"),
    (r"\.blsSecretKey\b",   "BLS12-381 secret key"),
    (r"\.recoveryPhrase\b", "BIP39 recovery phrase (mnemonic)"),
    (r"\.entropy\b",        "BIP39 entropy bytes"),
]

SUPPRESSION = "onym:allow-secret-read"
COMMENT_LINE = re.compile(r"^\s*//")


def is_suppressed(lines: list[str], index: int) -> bool:
    """True if the violation on `lines[index]` (1-based) is suppressed.

    A suppression is honoured if `SUPPRESSION` appears on the violating
    line itself, or anywhere in the contiguous block of `//`-prefixed
    comment lines directly above it.
    """
    line = lines[index - 1]
    if SUPPRESSION in line:
        return True
    j = index - 2
    while j >= 0 and COMMENT_LINE.match(lines[j]):
        if SUPPRESSION in lines[j]:
            return True
        j -= 1
    return False


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    sources = sorted(
        list(root.glob("Sources/OnymIOS/**/*.swift"))
        + list(root.glob("Tests/**/*.swift"))
    )

    violations: list[tuple[str, int, str, str]] = []
    for file in sources:
        rel = file.relative_to(root).as_posix()
        if rel in ALLOWED:
            continue

        lines = file.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines, start=1):
            for pattern, desc in PATTERNS:
                if not re.search(pattern, line):
                    continue
                if is_suppressed(lines, i):
                    continue
                violations.append((rel, i, desc, line.rstrip()))

    if violations:
        for rel, i, desc, line in violations:
            print(f"{rel}:{i}: forbidden secret read ({desc})")
            print(f"    {line}")
        print()
        print(f"Found {len(violations)} secret-read violation(s).")
        print(f"Allow with `// {SUPPRESSION}` on the line or directly above.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
