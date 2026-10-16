# Shared guards for the scripts that read the filesystem or run ssh.
# Sourced, never executed:
#
#   . "${BASH_SOURCE[0]%/*}/guard.sh"
#
# Two things live here because getting either of them wrong once is enough.
#
# **The trust boundary around a path.** `~/.ssh/config` and everything it
# Includes are files anything running as this user can replace — with a
# symlink into somewhere else, with a FIFO that never answers a read, with a
# gigabyte of text. Every open in this plugin goes through `sshm_check_file`
# first, and the checks are made on the path components too: a path is only as
# trustworthy as its least trustworthy ancestor.
#
# **Ceilings.** Walking a user-controlled Include graph has to stop. Bytes,
# lines, line length, files, depth and wall-clock each have a limit, and
# hitting one is a reported truncation rather than a shell that never returns.
# The shell this runs inside lives for the length of a login session; anything
# unbounded here is unbounded for days.
#
# Tools resolve through a fixed PATH. The ambient PATH belongs to whatever
# started the shell, and is not somewhere to inherit trust from.

PATH=/usr/bin:/bin
export PATH

# ssh's own messages are what probe.sh classifies, and the keyword folding in
# scan.sh is ASCII by definition. A fixed locale makes both mean the same
# thing on every machine, and makes ${#string} a count of bytes.
LC_ALL=C
export LC_ALL

# Ceilings are constants on purpose: an environment variable that could raise
# them would be one more thing to have to trust.
readonly SSHM_MAX_FILE_BYTES=1048576      # one config file, main or included
readonly SSHM_MAX_RESULTS_BYTES=262144    # the remembered test results
readonly SSHM_MAX_TOTAL_BYTES=4194304     # everything one scan may emit
readonly SSHM_MAX_LINES=100000            # records one scan may emit
readonly SSHM_MAX_LINE_BYTES=4096         # one line, before it is split
readonly SSHM_MAX_FILES=64                # files one scan may open
readonly SSHM_MAX_DEPTH=8                 # Include nesting
readonly SSHM_MAX_SECONDS=10              # wall-clock for one scan
readonly SSHM_MAX_RECORDS=1024            # `ssh -G` lines, or error lines
readonly SSHM_MAX_IDENTITIES=64           # identity files one host may name
readonly SSHM_MAX_MESSAGE_BYTES=4096      # one message quoted back from ssh
readonly SSHM_MAX_PASTE_BYTES=4096        # one paste into an editor field
readonly SSHM_TOOL_SECONDS=5              # one local helper (ssh-keygen…)
readonly SSHM_SSH_SECONDS=20              # one authentication attempt
readonly SSHM_TCP_SECONDS=4               # one TCP connect

sshm_uid=$(id -u)
sshm_reason=""
sshm_size=0

# setsid is what puts a helper in its own process group; without it a deadline
# can only reach the immediate child. Missing is not fatal, just weaker.
sshm_group=(setsid --)
command -v setsid >/dev/null 2>&1 || sshm_group=()

# True when every existing component of an absolute path is an ordinary entry
# owned by this user or by root, and none of them is a symlink. This is what
# stops a read or a write from being redirected somewhere else by replacing a
# directory on the way — `mkdir -p`, `chmod` by name and an open by name all
# follow whatever the path happens to point at right now.
sshm_path_ok() {
  local path=$1 rest component prefix="" info kind owner

  case $path in
    /*) ;;
    *) sshm_reason="not an absolute path"; return 1 ;;
  esac

  rest=${path#/}
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    if [ "$component" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    [ -n "$component" ] || continue
    case $component in
      . | ..) sshm_reason="path is not canonical"; return 1 ;;
    esac

    prefix="$prefix/$component"
    # stat does not follow symlinks, so this reports the entry itself. A
    # component that does not exist ends the walk: nothing below it exists
    # either, and the caller's own stat will say so.
    info=$(stat -c '%F|%u' -- "$prefix" 2>/dev/null) || return 0
    kind=${info%%|*}
    owner=${info##*|}

    if [ "$kind" = "symbolic link" ]; then
      sshm_reason="$prefix is a symbolic link"
      return 1
    fi
    if [ "$owner" != "$sshm_uid" ] && [ "$owner" != "0" ]; then
      sshm_reason="$prefix is owned by uid $owner"
      return 1
    fi
  done

  return 0
}

# 0 when the file is safe to open and `sshm_size` holds its size, 1 when it is
# not (with `sshm_reason`), 2 when it simply is not there — which for
# ~/.ssh/config is an ordinary state rather than a problem.
sshm_check_file() {
  local path=$1 max=${2:-$SSHM_MAX_FILE_BYTES} info kind owner size

  sshm_path_ok "$path" || return 1

  info=$(stat -c '%F|%u|%s' -- "$path" 2>/dev/null) || { sshm_reason="no such file"; return 2; }
  kind=${info%%|*}; info=${info#*|}
  owner=${info%%|*}; size=${info##*|}

  # A FIFO answers `[ -f ]` on some paths and never answers a read; a device
  # is worse. Only a regular file gets opened.
  case $kind in
    "regular file" | "regular empty file") ;;
    *) sshm_reason="$path is $kind, not a regular file"; return 1 ;;
  esac
  if [ "$owner" != "$sshm_uid" ] && [ "$owner" != "0" ]; then
    sshm_reason="$path is owned by uid $owner"
    return 1
  fi
  if [ "$size" -gt "$max" ]; then
    sshm_reason="$path is larger than $max bytes"
    return 1
  fi
  if [ ! -r "$path" ]; then
    sshm_reason="$path is not readable"
    return 1
  fi

  sshm_size=$size
  return 0
}

# The same, for the directory a config file lives in. ~/.ssh has to be ours
# and ours alone — ssh refuses to use one anyone else can write to, and so
# does this.
sshm_check_dir() {
  local dir=$1 info kind owner mode

  sshm_path_ok "$dir" || return 1

  info=$(stat -c '%F|%u|%a' -- "$dir" 2>/dev/null) || { sshm_reason="no such directory"; return 2; }
  kind=${info%%|*}; info=${info#*|}
  owner=${info%%|*}; mode=${info##*|}

  [ "$kind" = "directory" ] || { sshm_reason="$dir is $kind, not a directory"; return 1; }
  [ "$owner" = "$sshm_uid" ] || { sshm_reason="$dir is owned by uid $owner"; return 1; }
  case ${mode: -1} in
    2 | 3 | 6 | 7) sshm_reason="$dir is world-writable"; return 1 ;;
  esac
  case ${mode: -2:1} in
    2 | 3 | 6 | 7) sshm_reason="$dir is group-writable"; return 1 ;;
  esac

  return 0
}

# Run a command with a hard deadline and take its descendants with it.
#
# `timeout` signals only the process it started, so an ssh with a ProxyCommand
# — or a helper that outlives the ssh that spawned it — keeps running with the
# pipe it inherited still open. That is how a helper leaks into a shell that
# stays up for days. setsid gives the command its own process group, and the
# deadline kills the group rather than the leader.
#
# Returns the command's exit status, or 124 when the deadline killed it.
sshm_run_bounded() {
  local secs=$1; shift
  local pid watcher rc

  # stdin is /dev/null on purpose: nothing run through here reads it, and a
  # helper inheriting the caller's stdin is one more way for one to sit
  # waiting for input that is never coming. Anything that does need stdin —
  # config-write.sh reading the new file off a pipe — bounds itself instead.
  "${sshm_group[@]}" "$@" </dev/null &
  pid=$!

  (
    # The watcher inherits this command substitution's pipe; without dropping
    # it here, a caller reading our stdout would wait for the watcher too.
    exec >/dev/null 2>&1
    sleep "$secs"
    kill -0 "$pid" 2>/dev/null || exit 0
    if [ ${#sshm_group[@]} -gt 0 ]; then
      kill -TERM -"$pid" 2>/dev/null
      sleep 2
      kill -KILL -"$pid" 2>/dev/null
    else
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
    fi
  ) &
  watcher=$!

  wait "$pid"; rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  # 143 and 137 are the deadline's own TERM and KILL arriving.
  case $rc in
    143 | 137) return 124 ;;
  esac
  return "$rc"
}
