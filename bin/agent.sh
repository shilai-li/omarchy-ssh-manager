#!/usr/bin/env bash
#
# What the ssh-agent is holding.
#
#   agent.sh
#
# Prints `ssh-add -l` unchanged and exits with its status — 0 with keys, 1
# running but empty, 2 no agent — because that status is the whole answer and
# the listing is only the detail.
#
# It exists as a script rather than as a bare `ssh-add -l` from QML so that the
# binary is resolved through guard.sh's fixed PATH rather than through whatever
# PATH the shell was started with, and so that an agent that has stopped
# answering its socket is a five-second wait rather than a permanent one.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

sshm_run_bounded "$SSHM_TOOL_SECONDS" ssh-add -l 2>/dev/null | head -c "$SSHM_MAX_FILE_BYTES"
exit "${PIPESTATUS[0]}"
