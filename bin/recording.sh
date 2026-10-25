#!/usr/bin/env bash
#
# Whether Omarchy is recording the screen right now.
#
#   recording.sh
#
# One record on stdout:
#   R on|off|unknown
#
# The panel hides users and addresses while a recording runs, so this is asked
# whenever the panel is up. The answer is whether this user runs
# gpu-screen-recorder or wf-recorder, the two backends omarchy records with
# (Linux cuts the first's name to 15 characters) and what omarchy's recorder
# looks for about itself. A browser or a meeting app sharing the screen is
# invisible from here, which is why hiding can also be switched on by hand.
# Anything other than a clear yes or no — no pgrep, a check that hangs — is
# `unknown`, and the panel treats unknown as not recording rather than
# guessing.
#
# Never ask omarchy-capture-screenrecording. It is a toggle, and a release
# without --status ignores the flag and starts a recording instead of
# answering; polled every few seconds, that starts and saves one after another.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

command -v pgrep >/dev/null 2>&1 || { printf 'R\tunknown\n'; exit 0; }

sshm_run_bounded "$SSHM_TOOL_SECONDS" pgrep -u "$UID" -x 'gpu-screen-reco(rder)?|wf-recorder' >/dev/null 2>&1
case $? in
  0) printf 'R\ton\n' ;;
  1) printf 'R\toff\n' ;;
  *) printf 'R\tunknown\n' ;;
esac
exit 0
