#!/bin/bash
# =============================================================================
# Make the root-requiring scripts work whether they are run as a normal user
# with passwordless sudo, or already as root.
#
# Two environments have to work:
#
#   * a developer machine: run as the user, script calls "sudo -n ..."
#   * CI: the runner has passwordless sudo but no cached timestamp, so the
#     scripts are invoked via "sudo script". Inside, sudo must not be called
#     again - and when it is, the wrapper below turns it into a no-op.
#
# Rather than edit twenty call sites, each script sources this and uses $SUDO.
# When already root, $SUDO is empty.
#
# usage:  . "$(dirname "$0")/lib/sudo.sh"
#         $SUDO cp -f "$src" "$dst"
# =============================================================================

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
else
    echo "error: need root, or passwordless sudo" >&2
    exit 1
fi

export SUDO
