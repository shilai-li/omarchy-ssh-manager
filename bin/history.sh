#!/usr/bin/env bash
#
# The launch-history store: which aliases were launched, newest first, kept so
# the host list can put the last thing you went to at the top.
#
#   history.sh add <path> <name>
#   history.sh list <path>
#
# `add` moves the named host to the front of the list and writes the result in
# a transaction: the store is read through the same guards as anything else,
# the new entry and the deduplicated remainder go to a fresh 0600 file in the
# same directory, and a rename publishes it. A reader sees the old file or the
# new one, never a half-written one, and never one readable by anyone else.
#
# `list` prints the store to stdout, or nothing when it does not exist yet —
# a missing store is the ordinary first-launch state rather than an error.
#
# What the store holds is a preference, but the entry is a hostname the user
# may not remember typing, so it gets the rest of the guards: the path is
# checked component by component, the name has to be a plain alias (no
# whitespace, no /, no quotes, no control bytes — the set a Host line may
# hold), and the whole read is capped the way every other read here is.
#
# Records nothing on success; exits non-zero when it could not do the job.

set -u
. "${BASH_SOURCE[0]%/*}/guard.sh"

cmd=${1:-}
path=${2:-}
name=${3:-}

case $cmd in
  add)
    [ -n "$path" ] || exit 2
    case $name in
      "" | *[!A-Za-z0-9._-]*) exit 2 ;;
    esac
    ;;
  list)
    [ -n "$path" ] || exit 2
    ;;
  *)
    exit 2 ;;
esac

dir=${path%/*}
[ -n "$dir" ] || dir=/

# Bring the store's directory into existence, one level at a time. Each level
# is a plain mkdir that fails if anything already sits at that name — mkdir -p
# would follow a symlink somebody else planted on the way. The walk finds the
# nearest existing ancestor, then creates each missing level below it, the
# leaf at 0700; a level that exists already is left with whatever it is.
mkdir_chain() {
  local dir=$1 step=$dir i
  local -a missing=()
  while :; do
    sshm_check_dir "$step"
    case $? in
      0) break ;;
      2) missing+=("$step"); step=${step%/*}; [ -n "$step" ] || return 1 ;;
      *) return 1 ;;
    esac
  done
  for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
    [ -n "${missing[i]}" ] || continue
    local mode=0755; [ "$i" -eq 0 ] && mode=0700
    mkdir -m "$mode" -- "${missing[i]}" 2>/dev/null || return 1
    sshm_check_dir "${missing[i]}" || return 1
  done
  return 0
}

if [ "$cmd" = "add" ]; then
  mkdir_chain "$dir" || exit 1
fi

# One writer at a time, scoped to the lock file the other scripts use.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && command -v flock >/dev/null 2>&1 && sshm_check_dir "$XDG_RUNTIME_DIR"; then
  exec 9>"$XDG_RUNTIME_DIR/ssh-manager.lock" 2>/dev/null || true
  flock -w 5 9 2>/dev/null || true
fi

# Each entry rides its own line, so skipping the host being re-launched is a
# literal match on that one line rather than a parse of half a JSON document.
if [ "$cmd" = "add" ]; then
  ts=$(date +%s)
  next="{\"name\":\"$name\",\"ts\":$ts}"

  current=""
  sshm_check_file "$path"
  case $? in
    0) current=$(timeout "$SSHM_TOOL_SECONDS" head -c "$SSHM_MAX_HISTORY_BYTES" -- "$path") || exit 1 ;;
    2) ;;
    *) exit 1 ;; # a store that failed its checks is not overwritten
  esac

  rest=""
  if [ -n "$current" ]; then
    rest=$(printf '%s\n' "$current" \
      | grep -E '^[[:space:]]*\{[[:space:]]*"name":"[A-Za-z0-9._-]+","ts":[0-9]+\},?$' \
      | grep -Fv "{\"name\":\"$name\",\"ts\":" \
      | sed -E -e 's/^[[:space:]]+//' -e 's/,$//')
  fi

  joined="$next"
  kept=1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    kept=$((kept + 1))
    [ "$kept" -gt "$SSHM_MAX_HISTORY" ] && break
    joined=$(printf '%s,\n  %s' "$joined" "$entry")
  done <<EOF
$rest
EOF

  content=$(printf '[\n  %s\n]\n' "$joined")

  staging=$(mktemp -- "$dir/.ssh-manager-history.XXXXXXXX") || exit 1
  chmod 600 -- "$staging" || exit 1
  if ! printf '%s' "$content" >"$staging" || ! mv -f -- "$staging" "$path"; then
    rm -f -- "$staging"
    exit 1
  fi
  exit 0
fi

# list: the store, as it is. Nothing has been merged or rewritten here.
if sshm_check_file "$path"; then
  timeout "$SSHM_TOOL_SECONDS" head -c "$SSHM_MAX_HISTORY_BYTES" -- "$path" || exit 1
  exit 0
fi
exit 0