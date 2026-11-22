#!/bin/bash
# =============================================================================
# Fail if a script is committed without the executable bit.
#
# This has bitten twice: every script went in as 100644 at first, and later
# apply-tree-delta.sh did the same, each time failing CI with exit 126 long
# after the change was pushed. Checking here makes it a local failure instead.
#
# usage: scripts/check-modes.sh
# =============================================================================
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO"

bad=0
while read -r mode _ _ path; do
    case "$path" in
        *.sh|*.py)
            if [ "$mode" != "100755" ]; then
                echo "  missing +x: $path (mode $mode)"
                bad=$((bad + 1))
            fi
            ;;
    esac
done < <(git ls-files -s scripts/)

if [ "$bad" -gt 0 ]; then
    echo
    echo "error: $bad script(s) need the executable bit. Fix with:"
    echo "  git update-index --chmod=+x <path>"
    exit 1
fi

echo "  all scripts are executable"
