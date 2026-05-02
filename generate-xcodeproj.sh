#!/bin/sh
# Regenerate OnymIOS.xcodeproj from project.yml via xcodegen.
#
# project.yml is the source of truth — *.xcodeproj/ is gitignored
# because pbxproj merge conflicts are a tax on every multi-author PR
# and xcodegen is fast enough that there's no reason to track the
# generated file.
#
# Run before `open OnymIOS.xcodeproj` after pulling, or any time
# project.yml changes.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not installed. Install via:" >&2
    echo "  brew install xcodegen" >&2
    exit 1
fi

xcodegen generate
echo
echo "Generated: $SCRIPT_DIR/OnymIOS.xcodeproj"
echo "Open with: open OnymIOS.xcodeproj"
