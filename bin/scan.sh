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
#
# Order is the whole point. ssh takes the *first* value it obtains for each
# keyword, so a keyword's position in this stream decides whether it wins or
# is shadowed — which is what lets the panel say who overrode whom.
#
# Read-only. This script never writes, and never runs anything from the
# files it reads.

set -u

ssh_dir=$(dirname -- "${1:-$HOME/.ssh/config}")
max_depth=8

emit_file() {
  local file=$1 depth=$2 line kw rest pattern match included=0 saved_ifs

  # A cycle of Includes, or a nest deeper than anyone means to write, is a
  # broken config rather than something to follow to the end.
  [ "$depth" -gt "$max_depth" ] && return 0
  [ -f "$file" ] && [ -r "$file" ] || return 0

  printf 'F\t%s\n' "$file"

  # The `|| [ -n "$line" ]` keeps a final line with no trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    printf 'L\t%s\n' "$line"

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
      printf 'F\t%s\n' "$file"
    fi
  done <"$file"
}

emit_file "${1:-$HOME/.ssh/config}" 0
exit 0
