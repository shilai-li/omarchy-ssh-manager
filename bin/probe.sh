#!/usr/bin/env bash
#
# Test one SSH host without opening a session.
#
#   probe.sh <host> [config-file]
#
# Records, one per line, tab-separated:
#   T ok|fail|proxy|unknown   TCP reachability of the effective hostname:port
#   A ok|denied|hostkey|unreachable|error   what authentication did
#   M <text>                  ssh's own message, when it had one
#
# Two things are being asked, and they answer different questions: a failed
# TCP connect means the machine is not there, while a refused key means it is
# there and does not want us.
#
# **No credential ever passes through this script.** BatchMode=yes plus
# PasswordAuthentication=no and KbdInteractiveAuthentication=no mean ssh
# fails where it would otherwise prompt, so a host that only takes passwords
# is reported as "denied" rather than asked for one. Nothing is stored,
# nothing is echoed, and no ssh option that weakens host key checking is
# passed — an unknown host key is a finding, not something to accept
# silently.
#
# This is the only thing in the plugin that touches the network, so it is also
# the one that has to be certain it ends. Every ssh here runs in its own
# process group under a deadline that kills the group, not just the leader: a
# ProxyCommand or ProxyJump helper outliving the ssh that spawned it would go
# on holding a pipe into a shell that runs for days.

set -u
set -o pipefail
. "${BASH_SOURCE[0]%/*}/guard.sh"

host=${1:-}
[ -n "$host" ] || exit 0

# See effective.sh: -F is how a caller points ssh at a config file other than
# the one it would find on its own. Omitted in normal use.
ssh_args=()
if [ -n "${2:-}" ]; then
  sshm_check_file "$2" || {
    printf 'T\tunknown\nA\terror\nM\t%s\n' "$sshm_reason"
    exit 0
  }
  ssh_args=(-F "$2")
fi

config=$(sshm_run_bounded "$SSHM_TOOL_SECONDS" \
  ssh "${ssh_args[@]}" -G "$host" 2>/dev/null | head -c "$SSHM_MAX_FILE_BYTES") || {
  printf 'T\tunknown\n'
  printf 'A\terror\n'
  printf 'M\tssh could not parse the configuration for this host\n'
  exit 0
}

hostname=$(printf '%s\n' "$config" | awk '$1 == "hostname" { print $2; exit }')
port=$(printf '%s\n' "$config" | awk '$1 == "port" { print $2; exit }')
proxied=$(printf '%s\n' "$config" | awk '$1 == "proxyjump" || $1 == "proxycommand" { print "yes"; exit }')

# A proxied host is not reachable from here by definition — the jump host
# reaches it. Claiming otherwise would be a red cross on a working setup.
if [ -n "${proxied:-}" ]; then
  printf 'T\tproxy\n'
elif [ -z "${hostname:-}" ] || [ -z "${port:-}" ]; then
  printf 'T\tunknown\n'
else
  case $port in
    *[!0-9]*) printf 'T\tunknown\n' ;;
    *)
      if sshm_run_bounded "$SSHM_TCP_SECONDS" \
          bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$hostname" "$port" 2>/dev/null; then
        printf 'T\tok\n'
      else
        printf 'T\tfail\n'
      fi
      ;;
  esac
fi

# `true` is the cheapest possible remote command: it proves the key was
# accepted and a shell ran, and leaves nothing behind.
message=$(sshm_run_bounded "$SSHM_SSH_SECONDS" ssh "${ssh_args[@]}" \
  -o BatchMode=yes \
  -o ConnectTimeout=6 \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o LogLevel=ERROR \
  "$host" true 2>&1 </dev/null | head -c "$SSHM_MAX_MESSAGE_BYTES")
code=$?

if [ "$code" -eq 0 ]; then
  printf 'A\tok\n'
else
  case "$message" in
    *"Permission denied"*|*"No supported authentication"*|*"Too many authentication failures"*)
      printf 'A\tdenied\n' ;;
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key for"*)
      printf 'A\thostkey\n' ;;
    *"Could not resolve"*|*"Connection timed out"*|*"Connection refused"*|*"No route to host"*|*"Network is unreachable"*|*"Operation timed out"*)
      printf 'A\tunreachable\n' ;;
    *)
      # A deadline kill leaves no message at all; say so rather than showing
      # the user an empty error.
      [ "$code" -eq 124 ] && message=${message:-"timed out after ${SSHM_SSH_SECONDS}s"}
      printf 'A\terror\n' ;;
  esac
fi

[ -n "$message" ] && printf 'M\t%s\n' "$(printf '%s' "$message" | tr '\n\r\t' '   ')"
exit 0
