#!/usr/bin/env bash
#
# Remember the last test of each host across shell restarts, or recall it.
#
#   results.sh read <path>    the file's bytes on stdout, a status on stderr
#   results.sh write <path>   replace it with what arrives on stdin
#
# Status records, one per line, tab-separated — on stderr for a read, so the
# bytes on stdout stay exactly the file, and on stdout for a write:
#   S <ok|missing|rejected>   what happened
#   R <text>                  why, when it was refused
#
# What is stored is the least that answers "what did the last test find": the
# alias, the two outcome codes and when. No hostname, no user, no port, no key
# path and none of ssh's own message, which can quote an address. The file is
# still a list of hosts this user reaches, so it is written the way the config
# is: the directory created 0700 one level at a time and checked before every
# use, the contents staged at 0600 before they exist and renamed into place,
# and every open gated by guard.sh first.
#
# A write arrives length-prefixed on stdin, for the same reason config-write.sh
# takes it that way: the caller holds the pipe open for the life of the
# session, so end-of-file never comes.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

mode=${1:-}
path=${2:-}
staging=""

cleanup() { [ -n "$staging" ] && rm -f -- "$staging"; }
trap cleanup EXIT

# Reads report on stderr, writes on stdout; the rest is the same.
out=1
[ "$mode" = "read" ] && out=2
emit() { printf '%s\t%s\n' "$1" "$2" >&"$out"; }

reject() {
  emit S rejected
  emit R "$1"
  exit 0
}

case $mode in
  read | write) ;;
  *) out=1; reject "usage: results.sh read|write <path>" ;;
esac
[ -n "$path" ] || reject "usage: results.sh $mode <path>"

dir=${path%/*}
[ -n "$dir" ] || dir=/

# ---- Reading. Nothing remembered is an ordinary state, as is a directory
#      that was never created.
if [ "$mode" = "read" ]; then
  sshm_check_dir "$dir"
  case $? in
    1) reject "$sshm_reason" ;;
    2) emit S missing; exit 0 ;;
  esac
  sshm_check_file "$path" "$SSHM_MAX_RESULTS_BYTES"
  case $? in
    0) ;;
    2) emit S missing; exit 0 ;;
    *) reject "$sshm_reason" ;;
  esac
  sshm_run_bounded "$SSHM_TOOL_SECONDS" head -c "$SSHM_MAX_RESULTS_BYTES" -- "$path" || reject "could not read $path"
  emit S ok
  exit 0
fi

# ---- Writing. The directory first: ours, nobody else's to write, created
#      one level if it is not there and never with `mkdir -p`.
sshm_check_dir "$dir"
case $? in
  1) reject "$sshm_reason" ;;
  2)
    parent=${dir%/*}
    [ -n "$parent" ] || parent=/
    sshm_check_dir "$parent" || reject "$sshm_reason"
    mkdir -m 700 -- "$dir" 2>/dev/null || reject "could not create $dir"
    sshm_check_dir "$dir" || reject "$sshm_reason"
    ;;
esac

IFS= read -r want || reject "no content on stdin"
case $want in
  "" | *[!0-9]*) reject "malformed length prefix" ;;
esac
[ "$want" -le "$SSHM_MAX_RESULTS_BYTES" ] || reject "refusing to write more than $SSHM_MAX_RESULTS_BYTES bytes"

staging=$(mktemp -- "$dir/.results.XXXXXXXX") || reject "could not create a staging file in $dir"
chmod 600 -- "$staging" || reject "could not set the mode of the staging file"

timeout "$SSHM_TOOL_SECONDS" head -c "$want" >"$staging" || reject "the new contents did not arrive"
got=$(stat -c '%s' -- "$staging")
[ "$got" = "$want" ] || reject "expected $want bytes, got $got"

# Whatever sits at the name now has to be something this would have read; a
# directory or a FIFO planted there is refused rather than renamed over.
sshm_check_file "$path" "$SSHM_MAX_RESULTS_BYTES"
case $? in
  0 | 2) ;;
  *) reject "$sshm_reason" ;;
esac

# rename(2) replaces the entry itself, so a symlink that appeared at $path
# since the check above is overwritten rather than followed.
mv -f -- "$staging" "$path" || reject "could not replace $path"
staging=""

emit S ok
exit 0
