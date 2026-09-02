#!/usr/bin/env bash
#
# Replace ~/.ssh/config with a new version, or refuse to.
#
#   config-write.sh <path> <digest-this-edit-was-made-against>
#
# The new contents arrive on stdin, length-prefixed: one line holding the byte
# count, then exactly that many bytes. A length prefix rather than end-of-file
# because the caller is a long-lived QML process writing into a pipe it keeps
# open, and rather than argv because argv is world-readable in /proc.
#
# Records on stdout, one per line, tab-separated:
#   S <ok|conflict|rejected>   what happened
#   R <text>                   why, when it was refused
#   D <sha256>                 digest of the file as it now stands
#   V <size>:<inode>:<mtime>   its identity afterwards
#
# The write is a transaction:
#
#   1. ~/.ssh must be a directory this user owns and nobody else can write —
#      created 0700 if it is not there, one level, never `mkdir -p`, which
#      would happily follow a symlink somebody else planted on the way.
#   2. The file as it is now must still digest to what the editor read. If it
#      does not, someone else edited it since, and this edit is refused with
#      `conflict` rather than dropping their change.
#   3. The new text goes to a fresh file in the same directory, at mode 0600
#      *before* it holds anything, and is renamed over the target. A reader
#      sees the old file or the new one, never a half-written one, and never a
#      window where the new one is readable by anyone else.
#
# `chmod` after the fact — the old shape of this — leaves exactly that window,
# and chmods whatever the path points at by then rather than the file that was
# just written.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

path=${1:-}
expected=${2:-}
[ -n "$path" ] && [ -n "$expected" ] || { printf 'S\trejected\nR\tusage: config-write.sh <path> <digest>\n'; exit 0; }

dir=${path%/*}
[ -n "$dir" ] || dir=/
staging=""

cleanup() { [ -n "$staging" ] && rm -f -- "$staging"; }
trap cleanup EXIT

emit() { printf '%s\t%s\n' "$1" "$2"; }

reject() {
  emit S "${2:-rejected}"
  emit R "$1"
  exit 0
}

# ---- 1. The directory.

sshm_check_dir "$dir"
case $? in
  1) reject "$sshm_reason" ;;
  2)
    parent=${dir%/*}
    [ -n "$parent" ] || parent=/
    sshm_check_dir "$parent" || reject "$sshm_reason"
    # One level, and it fails outright if something already sits there — a
    # symlink at $dir is an EEXIST here rather than a write somewhere else.
    mkdir -m 700 -- "$dir" 2>/dev/null || reject "could not create $dir"
    sshm_check_dir "$dir" || reject "$sshm_reason"
    ;;
esac

# Only one writer at a time. The digest check below already refuses an edit
# built on a stale copy, so the lock is about two writers interleaving their
# staging and rename rather than about losing an edit.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && command -v flock >/dev/null 2>&1 && sshm_check_dir "$XDG_RUNTIME_DIR"; then
  exec 9>"$XDG_RUNTIME_DIR/ssh-manager.lock" 2>/dev/null || true
  flock -w 5 9 2>/dev/null || true
fi

# ---- 2. Stage the new contents, at 0600 from the moment the file exists.

IFS= read -r want || reject "no content on stdin"
case $want in
  "" | *[!0-9]*) reject "malformed length prefix" ;;
esac
[ "$want" -le "$SSHM_MAX_FILE_BYTES" ] || reject "refusing to write more than $SSHM_MAX_FILE_BYTES bytes"

staging=$(mktemp -- "$dir/.ssh-manager.XXXXXXXX") || reject "could not create a staging file in $dir"
chmod 600 -- "$staging" || reject "could not set the mode of the staging file"

# Not sshm_run_bounded: this one has to read the pipe we were handed, and
# `head` has no descendants for a group kill to be about.
timeout "$SSHM_TOOL_SECONDS" head -c "$want" >"$staging" || reject "the new contents did not arrive"
got=$(stat -c '%s' -- "$staging")
[ "$got" = "$want" ] || reject "expected $want bytes, got $got"

# ---- 3. The file has to still be the one the edit was made against, and the
#         check has to be the last thing before the rename.

sshm_check_file "$path"
case $? in
  0) current=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" head -c "$SSHM_MAX_FILE_BYTES" -- "$path" | sha256sum | cut -d' ' -f1) ;;
  2) current=- ;;
  *) reject "$sshm_reason" ;;
esac
[ "$current" = "$expected" ] || reject "$path changed since it was read" conflict

# rename(2) replaces the entry itself, so a symlink that appeared at $path
# since the checks above is overwritten rather than followed.
mv -f -- "$staging" "$path" || reject "could not replace $path"
staging=""

emit S ok
emit D "$(sha256sum <"$path" | cut -d' ' -f1)"
emit V "$(stat -c '%s:%i:%Y' -- "$path")"
exit 0
