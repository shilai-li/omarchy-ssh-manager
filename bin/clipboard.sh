#!/usr/bin/env bash
#
# The clipboard's text, for one paste into the editor.
#
#   clipboard.sh
#
# The text goes to stdout. Everything else goes to stderr, in the records
# config-read.sh uses:
#
#   S <ok|empty|rejected>   what happened
#   R <text>                why, when it was rejected
#
# The editor's fields are read-only to Qt, because a writable Qt text field
# fetches the whole clipboard every time anything on the desktop copies, inside
# the shell's own process and with no limit on size or time. Whatever is on
# the clipboard was put there by another program, and may be very large or
# never finish arriving. So the only read is this one: made when the user
# pastes, in a process of its own, cut off after SSHM_MAX_PASTE_BYTES and
# killed with its process group at the deadline. A paste longer than a field
# could ever hold is refused whole rather than cut.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

emit() { printf '%s\t%s\n' "$1" "$2" >&2; }

command -v wl-paste >/dev/null 2>&1 || { emit S rejected; emit R "wl-paste is not installed"; exit 0; }

# One byte past the ceiling is read so that "exactly the limit" and "more than
# the limit" can be told apart; head closing the pipe ends wl-paste early. NUL
# cannot live in a shell variable or a field, so it is dropped on the way.
text=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" wl-paste --no-newline --type text 2>/dev/null \
  | head -c "$((SSHM_MAX_PASTE_BYTES + 1))" | tr -d '\000'; exit "${PIPESTATUS[0]}")
rc=$?

if [ "$rc" -eq 124 ]; then
  emit S rejected
  emit R "the clipboard did not answer in time"
  exit 0
fi
if [ "${#text}" -gt "$SSHM_MAX_PASTE_BYTES" ]; then
  emit S rejected
  emit R "the clipboard holds more than $SSHM_MAX_PASTE_BYTES bytes"
  exit 0
fi
# wl-paste exits non-zero when nothing is copied, or nothing as text; there is
# simply nothing to paste then. A pipe closed early by head is not a failure.
if [ -z "$text" ]; then
  emit S empty
  exit 0
fi

printf '%s' "$text"
emit S ok
exit 0
