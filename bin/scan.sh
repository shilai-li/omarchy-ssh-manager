#!/usr/bin/env bash
#
# Print an ssh_config the way ssh reads it: every line of the file, with
# Include directives expanded in place, and a marker naming the file each
# line came from.
#
#   scan.sh ~/.ssh/config
#
# Records, one per line, tab-separated:
#   F <path>   every following L record comes from this file
#   L <line>   one raw configuration line, in ssh's reading order
#   E <text>   something was skipped or cut short, and why
#
# Order is the whole point. ssh takes the *first* value it obtains for each
# keyword, so a keyword's position in this stream decides whether it wins or
# is shadowed — which is what lets the panel say who overrode whom.
#
# Read-only. This script never writes, and never runs anything from the files
# it reads.
#
# The include graph belongs to whoever can write ~/.ssh, so walking it needs
# an end: every file is checked before it is opened (guard.sh), a file already
# on the current path is a cycle and is not followed again, and bytes, lines,
# line length, file count, depth and wall-clock all have ceilings. Reaching
# one emits an E record and stops — a partial config the panel can say is
# partial, rather than a shell that never comes back.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

config=${1:-$HOME/.ssh/config}
ssh_dir=${config%/*}
[ -n "$ssh_dir" ] || ssh_dir=/

emitted_bytes=0
emitted_lines=0
opened_files=0
deadline=$((SECONDS + SSHM_MAX_SECONDS))
stack=""
stopped=""

out() {
  emitted_lines=$((emitted_lines + 1))
  emitted_bytes=$((emitted_bytes + ${#2} + 3))
  printf '%s\t%s\n' "$1" "$2"
}

# True once anything this run is allowed to spend has run out. Checked before
# every record rather than at the end, so the ceiling is on what is produced,
# not on what has already been produced.
over_budget() {
  [ -n "$stopped" ] && return 0
  if [ "$emitted_bytes" -gt "$SSHM_MAX_TOTAL_BYTES" ]; then
    stopped="stopped after $SSHM_MAX_TOTAL_BYTES bytes"
  elif [ "$emitted_lines" -gt "$SSHM_MAX_LINES" ]; then
    stopped="stopped after $SSHM_MAX_LINES lines"
  elif [ "$SECONDS" -ge "$deadline" ]; then
    stopped="stopped after $SSHM_MAX_SECONDS seconds"
  fi
  [ -n "$stopped" ]
}

emit_file() {
  local file=$1 depth=$2 line kw rest pattern match included=0 saved_ifs real

  over_budget && return 0

  # A nest deeper than anyone means to write is a broken config rather than
  # something to follow to the end.
  if [ "$depth" -gt "$SSHM_MAX_DEPTH" ]; then
    out E "Include nesting deeper than $SSHM_MAX_DEPTH, not followed: $file"
    return 0
  fi
  if [ "$opened_files" -ge "$SSHM_MAX_FILES" ]; then
    stopped="stopped after $SSHM_MAX_FILES files"
    return 0
  fi

  # Everything about the file that has to be true before it is opened: not a
  # symlink, not a FIFO, ours or root's, and small enough to read.
  sshm_check_file "$file"
  case $? in
    1) out E "skipped: $sshm_reason" ; return 0 ;;
    2) return 0 ;;
  esac

  # A file that includes something that includes it again would otherwise be
  # walked to the depth limit, once per path through the graph.
  real=$(readlink -f -- "$file" 2>/dev/null) || real=$file
  case "|$stack|" in
    *"|$real|"*)
      out E "Include cycle, not followed again: $file"
      return 0
      ;;
  esac
  stack="$stack|$real"
  opened_files=$((opened_files + 1))

  out F "$file"

  # The `|| [ -n "$line" ]` keeps a final line with no trailing newline. `-n`
  # caps how much of one line is read at a time: a config that is one enormous
  # line arrives as several, which reads oddly but ends.
  while IFS= read -r -n "$SSHM_MAX_LINE_BYTES" line || [ -n "$line" ]; do
    over_budget && break
    out L "$line"

    read -r kw rest <<<"$line" || true
    [ "${kw,,}" = "include" ] || continue
    [ -n "${rest:-}" ] || continue

    # ssh splits Include arguments on whitespace and expands each as a glob,
    # except that one quoted argument may contain spaces. Word splitting
    # covers the first; the quoted form is unwrapped here rather than through
    # eval, which would hand the file's contents to the shell.
    case "$rest" in
      '"'*'"') set -- "${rest#\"}" ; set -- "${1%\"}" ;;
      *)
        # shellcheck disable=SC2086
        set -- $rest ;;
    esac

    for pattern in "$@"; do
      over_budget && break
      case "$pattern" in
        "~/"*) pattern="$HOME/${pattern#\~/}" ;;
        /*) ;;
        # A relative Include is relative to the directory of the file the scan
        # started from — ~/.ssh for the config ssh itself reads.
        *) pattern="$ssh_dir/$pattern" ;;
      esac

      # Pathname expansion without word splitting: with IFS empty, a glob
      # that expands to "my configs/work.conf" stays one path instead of
      # becoming two.
      saved_ifs=$IFS
      IFS=
      # shellcheck disable=SC2086
      for match in $pattern; do
        IFS=$saved_ifs
        emit_file "$match" $((depth + 1))
        included=1
        IFS=
      done
      IFS=$saved_ifs
    done

    # An include is expanded where it sits, so the lines after it belong to
    # this file again. Without saying so, every line below an Include would be
    # blamed on the last file it pulled in.
    if [ "${included:-0}" = "1" ]; then
      included=0
      out F "$file"
    fi
  done <"$file"

  stack=${stack%"|$real"}
}

emit_file "$config" 0
[ -n "$stopped" ] && out E "$stopped — the configuration below this point was not read"
exit 0
