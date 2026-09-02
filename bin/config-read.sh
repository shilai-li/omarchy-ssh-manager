#!/usr/bin/env bash
#
# Read ~/.ssh/config, with the checks that have to happen before the open.
#
#   config-read.sh <path>          the file's bytes, and what it is
#   config-read.sh --stat <path>   only what it is, without reading it
#
# The bytes go to stdout, byte for byte. Everything else goes to stderr, one
# tab-separated record per line:
#
#   S <ok|missing|rejected>   what happened
#   R <text>                  why, when it was rejected
#   D <sha256>                digest of exactly the bytes on stdout, or -
#   V <size>:<inode>:<mtime>  cheap identity, for noticing an outside edit
#
# The digest is the point of the D record: config-write.sh is handed it back
# as the version this edit was made against, so an edit built on a stale copy
# is refused rather than quietly overwriting whatever arrived in between.
#
# ~/.ssh/config is a path anything running as this user can replace. Reading
# it by name and trusting what comes back lets a symlink redirect the read, a
# FIFO block it forever, and a very large file hold the shell's memory.
# guard.sh turns each of those into a rejection, before the file is opened.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

stat_only=0
if [ "${1:-}" = "--stat" ]; then
  stat_only=1
  shift
fi

path=${1:-$HOME/.ssh/config}
buffer=""

cleanup() { [ -n "$buffer" ] && rm -f -- "$buffer"; }
trap cleanup EXIT

emit() { printf '%s\t%s\n' "$1" "$2" >&2; }

identity() {
  local info
  info=$(stat -c '%s:%i:%Y' -- "$path" 2>/dev/null) || info="-"
  emit V "$info"
}

reject() {
  emit S rejected
  emit R "$1"
  emit D -
  identity
  exit 0
}

sshm_check_file "$path"
case $? in
  1) reject "$sshm_reason" ;;
  2)
    emit S missing
    emit D -
    emit V -
    exit 0
    ;;
esac

if [ "$stat_only" = "1" ]; then
  emit S ok
  emit D -
  identity
  exit 0
fi

# Read into a private buffer first. The file can be rewritten between the
# checks above and the read below, and nothing may reach stdout until we know
# the bytes are one coherent version of it — half of one file followed by half
# of the next is exactly what the digest is meant to prevent.
buffer=$(mktemp -t ssh-manager-read.XXXXXXXX) || reject "no writable temporary directory"
chmod 600 -- "$buffer"

attempt=0
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))

  before=$(stat -c '%s:%i:%Y' -- "$path" 2>/dev/null) || reject "$path disappeared while it was being read"
  sshm_run_bounded "$SSHM_TOOL_SECONDS" \
    head -c "$((SSHM_MAX_FILE_BYTES + 1))" -- "$path" >"$buffer" || reject "$path could not be read"
  after=$(stat -c '%s:%i:%Y' -- "$path" 2>/dev/null) || reject "$path disappeared while it was being read"

  [ "$before" = "$after" ] || continue

  read_size=$(stat -c '%s' -- "$buffer")
  [ "$read_size" -le "$SSHM_MAX_FILE_BYTES" ] || reject "$path is larger than $SSHM_MAX_FILE_BYTES bytes"

  emit S ok
  emit D "$(sha256sum <"$buffer" | cut -d' ' -f1)"
  emit V "$after"
  cat -- "$buffer"
  exit 0
done

reject "$path kept changing while it was being read"
