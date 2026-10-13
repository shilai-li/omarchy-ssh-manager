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
# whenever the panel is up. It is only the answer omarchy's own recorder gives
# about itself: a browser or a meeting app sharing the screen is invisible
# from here, which is why hiding can also be switched on by hand. Anything
# other than a clear yes or no — no recorder installed, a status that hangs —
# is `unknown`, and the panel treats unknown as not recording rather than
# guessing.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

recorder=$(command -v omarchy-capture-screenrecording 2>/dev/null) || { printf 'R\tunknown\n'; exit 0; }

sshm_run_bounded "$SSHM_TOOL_SECONDS" "$recorder" --status >/dev/null 2>&1
case $? in
  0) printf 'R\ton\n' ;;
  1) printf 'R\toff\n' ;;
  *) printf 'R\tunknown\n' ;;
esac
exit 0
