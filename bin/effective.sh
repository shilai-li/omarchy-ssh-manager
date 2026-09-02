#!/usr/bin/env bash
#
# Ask ssh itself what it would do for a host, and check the identity files
# that answer names.
#
#   effective.sh <host> [config-file]
#
# Records, one per line, tab-separated:
#   G ok|fail                      whether the configuration parses
#   C <keyword> <value>            one line of `ssh -G <host>` output
#   I <path> <yes|no> <fingerprint>  an identity ssh would offer: expanded
#                                  path, whether it exists, and its
#                                  fingerprint (empty when unreadable)
#   X <text>                       ssh's own error output when G is fail
#
# `ssh -G` is the only honest answer to "what will ssh actually do": it
# resolves Include, Match and wildcard blocks exactly as the client will.
# Nothing here re-implements that.
#
# Read-only and offline: no connection is made, and nothing is decrypted —
# `ssh-keygen -l` reads the public half of a key, never the private one.
#
# Every helper runs under a deadline that kills its process group, and every
# capture has a ceiling. A config can point ssh at a ProxyCommand or a Match
# exec that never returns; without both, one bad entry hangs a shell that is
# supposed to stay up for the length of the login session.

set -u
set -o pipefail
. "${BASH_SOURCE[0]%/*}/guard.sh"

host=${1:-}
[ -n "$host" ] || exit 0

# ssh finds ~/.ssh/config through the passwd database, not $HOME, so the only
# way to point it at another file — a test fixture, a config kept elsewhere —
# is -F. Omitted in normal use, which is what makes this the same view of the
# configuration the user's own `ssh` has.
ssh_args=()
if [ -n "${2:-}" ]; then
  sshm_check_file "$2" || { printf 'G\tfail\nX\t%s\n' "$sshm_reason"; exit 0; }
  ssh_args=(-F "$2")
fi

if ! config=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" \
    ssh "${ssh_args[@]}" -G "$host" 2>/dev/null | head -c "$SSHM_MAX_FILE_BYTES"); then
  printf 'G\tfail\n'
  # Re-run only to collect the diagnostic; the first run kept stdout clean.
  sshm_run_bounded "$SSHM_TOOL_SECONDS" ssh "${ssh_args[@]}" -G "$host" 2>&1 >/dev/null |
    head -c "$SSHM_MAX_FILE_BYTES" | head -n "$SSHM_MAX_RECORDS" |
    while IFS= read -r line; do
      printf 'X\t%s\n' "$line"
    done
  exit 0
fi

printf 'G\tok\n'
printf '%s\n' "$config" | head -n "$SSHM_MAX_RECORDS" | while IFS= read -r line; do
  printf 'C\t%s\n' "$line"
done

printf '%s\n' "$config" | awk '$1 == "identityfile" { $1 = ""; sub(/^ /, ""); print }' |
  head -n "$SSHM_MAX_IDENTITIES" |
  while IFS= read -r path; do
    case "$path" in
      "~/"*) expanded="$HOME/${path#\~/}" ;;
      *) expanded=$path ;;
    esac

    if [ ! -f "$expanded" ]; then
      printf 'I\t%s\tno\t\n' "$expanded"
      continue
    fi

    # The .pub half if it is there, the key file itself otherwise. Either way
    # ssh-keygen only reads the public key material, and </dev/null means an
    # encrypted key can never turn this into a passphrase prompt.
    if [ -f "$expanded.pub" ]; then
      fingerprint=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" \
        ssh-keygen -l -f "$expanded.pub" </dev/null 2>/dev/null | awk 'NR == 1 { print $2 }') || fingerprint=""
    else
      fingerprint=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" \
        ssh-keygen -l -f "$expanded" </dev/null 2>/dev/null | awk 'NR == 1 { print $2 }') || fingerprint=""
    fi
    printf 'I\t%s\tyes\t%s\n' "$expanded" "${fingerprint:-}"
  done

exit 0
