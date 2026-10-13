#!/usr/bin/env bash
#
# Save one of this widget's own settings, the way `omarchy bar set` does.
#
#   setting.sh <key> <true|false>
#
# One record on stdout:
#   S ok|rejected
#   R <text>          why, when it was refused
#
# The shell keeps a widget's settings in shell.json and hands them back to the
# widget when they change, but gives a plugin no call to write them. This goes
# through omarchy-bar rather than editing shell.json, so the one file this
# plugin does not own is changed by the tool that does. Only the two keys this
# plugin declares are accepted, and only as JSON booleans: the panel is the
# caller, and nothing else needs a way to put arbitrary values in the user's
# bar configuration.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

readonly WIDGET_ID="shilai_li.ssh-manager"

emit() { printf '%s\t%s\n' "$1" "$2"; }
reject() { emit S rejected; emit R "$1"; exit 0; }

key=${1:-}
value=${2:-}

case $key in
  startHidden | hideWhileRecording) ;;
  *) reject "unknown setting" ;;
esac
case $value in
  true | false) ;;
  *) reject "a setting here is true or false" ;;
esac

bar=$(command -v omarchy-bar 2>/dev/null) || reject "omarchy-bar is not installed"

sshm_run_bounded "$SSHM_TOOL_SECONDS" "$bar" set "$WIDGET_ID" "$key" "$value" --json >/dev/null 2>&1 \
  || reject "omarchy-bar could not save it"
emit S ok
exit 0
