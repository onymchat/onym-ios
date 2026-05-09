#!/usr/bin/env python3
"""
Static check: forbid identity / per-dialog / group secrets from
crossing into the transport layer.

Complements `lint-secrets.py` — that one ensures every secret read
is justified with a `// onym:allow-secret-read` annotation; this
one ensures the read doesn't end up on the wire unsealed.

Two rules:

1. **Transport barrier.** Source files under
   `Sources/OnymIOS/Transport/` may NOT reference identity-level or
   per-dialog secret material by name. Transport is plumbing for
   sealed bytes; it should never see plaintext secrets. Comments
   are exempt (the docstring may legitimately describe what the
   layer is forbidden from touching).

2. **Send arg shape.** The first argument to
   `<transport>.send(<payload>, to: <inbox>)` MUST NOT be a
   secret-named variable. The first arg should always be
   sealed-envelope bytes — typically a variable named `sealed` (or
   the result of a sealing call). Direct passing of `blsSecret`,
   `groupSecret`, `nostrSecret`, etc. is a leak.

Both rules are heuristic — a determined leaker can still wrap a
secret in a non-suspicious local name and ship it. They catch the
realistic regression: someone refactors a flow and accidentally
plumbs the wrong variable through. The cryptographic gate
(secrets must enter `IdentityRepository.sealInvitation` before the
transport sees them) is documented in the surrounding code; this
linter is the static reminder.

Default-deny. To allow a specific exception, annotate the line
itself or any `//` comment line in the contiguous block directly
above with `// onym:allow-secret-transport`. Each suppression
should justify itself in code review.

Usage:
    python3 scripts/lint-no-secret-transport.py
Exits 0 on success, 1 on any unsuppressed violation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Identity-level + per-dialog + group secret material. These names
# should never appear in the transport layer, and never appear as
# the first argument to a `.send(_:to:)` call.
IDENTITY_SECRET_NAMES: set[str] = {
    "blsSecretKey",
    "nostrSecretKey",
    "inboxKeyAgreementPrivateKey",
    "stellarSigningPrivateKey",
    "peerBlsSecret",
    "peerBlsSecretKey",
    "groupSecret",
    "introPrivateKey",
    "recoveryPhrase",
    "mnemonic",
    "entropy",
    "blsSecret",
    "nostrSecret",
}

# Generic secret-shaped names that shouldn't be the first argument
# to `.send(_:to:)`. Broader than IDENTITY_SECRET_NAMES — catches
# generic helpers that might hold secret bytes locally.
SEND_ARG_FORBIDDEN: set[str] = IDENTITY_SECRET_NAMES | {
    "secretKey",
    "privateKey",
    "phrase",
    "seed",
    "secret",
}

# Path prefix for the transport-barrier rule.
TRANSPORT_BARRIER_DIR = "Sources/OnymIOS/Transport/"

# Suppression token (mirrors `lint-secrets.py`'s pattern).
SUPPRESSION = "onym:allow-secret-transport"
COMMENT_LINE = re.compile(r"^\s*//")

# Pattern for `<receiver>.send(<arg>, to: …)` — captures the first
# identifier of the payload arg. Tolerates `try`, `await`, and
# whitespace before the identifier; bails on more complex
# expressions (where it captures the leading word — e.g.
# `sealAndShip(secret)` captures `sealAndShip`, which is fine —
# the wrapper isn't a secret name).
SEND_CALL_RE = re.compile(
    r"\b\w+\.send\(\s*"
    r"(?:try\s+)?"
    r"(?:await\s+)?"
    r"(?P<arg>\w+)"
    r"\s*,\s*to:"
)


def is_suppressed(lines: list[str], index: int) -> bool:
    """True if the violation on `lines[index]` (1-based) is suppressed.

    Mirrors `lint-secrets.py`'s suppression rules: `SUPPRESSION` on
    the violating line itself, or anywhere in the contiguous block
    of `//`-prefixed comment lines directly above it.
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


def is_comment_line(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("//") or stripped.startswith("///")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    sources = sorted(root.glob("Sources/OnymIOS/**/*.swift"))

    violations: list[tuple[str, int, str, str]] = []

    for file in sources:
        rel = file.relative_to(root).as_posix()
        lines = file.read_text(encoding="utf-8").splitlines()

        # Rule 1: Transport/ doesn't reference identity secrets.
        if rel.startswith(TRANSPORT_BARRIER_DIR):
            for i, line in enumerate(lines, start=1):
                if is_comment_line(line):
                    continue
                for name in IDENTITY_SECRET_NAMES:
                    if not re.search(rf"\b{re.escape(name)}\b", line):
                        continue
                    if is_suppressed(lines, i):
                        continue
                    violations.append((
                        rel, i,
                        f"transport-barrier: secret name '{name}' inside {TRANSPORT_BARRIER_DIR}",
                        line.rstrip(),
                    ))

        # Rule 2: .send(arg, to:) where arg is a secret-shaped name.
        for i, line in enumerate(lines, start=1):
            if is_comment_line(line):
                continue
            for m in SEND_CALL_RE.finditer(line):
                arg = m.group("arg")
                if arg not in SEND_ARG_FORBIDDEN:
                    continue
                if is_suppressed(lines, i):
                    continue
                violations.append((
                    rel, i,
                    f"transport-arg: send() called with secret-named arg '{arg}' (must be sealed bytes)",
                    line.rstrip(),
                ))

    if violations:
        for rel, i, desc, line in violations:
            print(f"{rel}:{i}: {desc}")
            print(f"    {line}")
        print()
        print(f"Found {len(violations)} secret-leak violation(s).")
        print(f"Allow with `// {SUPPRESSION}` on the line or directly above.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
