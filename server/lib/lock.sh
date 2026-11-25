#!/usr/bin/env bash
# lock.sh: the gateway's host-wide locks with flock (docs/spec.md «Names», reference/lifecycle.md «Lock ordering and
# availability»; ported from positron-remote src/lock.ts).
#
#   source "$FNKC_LIB/lock.sh"
#
#   project_lock <user> <project>                 print the project lock name, project-<user>-<project>
#   lock_acquire [-m <wait message>] <name> [timeout seconds]
#                                                 take the lock; busy after the timeout (default 120 s)
#   lock_release <name>                           give it back (closes the descriptor)
#   with_lock [-m <wait message>] <name> <timeout seconds> -- <command...>
#                                                 acquire, run the command in this shell, release
#   is_lock_held <name>                           this process holds the lock
#
# Lock names: host, image-upload, image-store, project-<user>-<project>. Each is the file <name>.kernel in
# FNKC_LOCK_DIR (agent.json lockDir; default ~/.cache/fnkc-ctl/locks). The files are never deleted: unlinking a locked
# inode would create a second lock domain, so two holders at once.
#
# Busy: when the lock is not free within the timeout, the process ends with exit status FNKC_BUSY_STATUS (75) and
# "fnkc-ctl: operation is busy; timed out waiting for <file>" on stderr; the reply layer answers code "busy" with that
# message. Any other flock failure dies with status 1.
#
# Release: the lock belongs to the open file description, so the kernel drops it when the last process holding the
# descriptor ends, however it ends (exit, die, a signal, kill -9); no trap is needed and none could catch kill -9.
# Children inherit the descriptor: a command started in the background while a lock is held keeps the lock until it
# ends. Never leave a background process running past lock_release.
#
# Lock order (reference/lifecycle.md): project-* before image-upload before image-store before host. A process
# holding a lock may only take locks later in this order and never the same lock twice (a second flock on the same
# file from this process would wait for itself); anything else is a programming error and dies before it can
# deadlock. Starts take project then host (admission) and, with pullImages, project then image-store; uploads take
# image-upload then image-store; image operations never take a project lock.
#
# Waiting: when the lock is taken at the first try and -m is given, the message goes to stderr once, never only to
# the journal (an upload says it waits for another upload, docs/spec.md «install-image stream»).

# shellcheck shell=bash
[[ -n "${FNKC_LOCK_LOADED:-}" ]] && return 0
FNKC_LOCK_LOADED=1

# shellcheck source=server/lib/names.sh
source "${FNKC_LIB:?FNKC_LIB is not set}/names.sh"

readonly FNKC_BUSY_STATUS=75
readonly FNKC_LOCK_TIMEOUT=120
: "${FNKC_LOCK_DIR:=${HOME:?HOME is not set}/.cache/fnkc-ctl/locks}"

# Descriptor of each lock this process holds, by name.
declare -gA _FNKC_LOCK_FD=()

project_lock() {
  check_user "${1-}"
  check_project "${2-}"
  printf 'project-%s-%s\n' "$1" "$2"
}

# _lock_rank <name>: position in the lock order, or fail for a name that is not a lock.
_lock_rank() {
  case "${1-}" in
    host) printf '40\n' ;;
    image-store) printf '30\n' ;;
    image-upload) printf '20\n' ;;
    project-*)
      is_match "project-($FNKC_USER_RE)-($FNKC_PROJECT_RE)" "$1" 128 || return 1
      printf '10\n'
      ;;
    *) return 1 ;;
  esac
}

is_lock_held() {
  [[ -n "${_FNKC_LOCK_FD[${1:-}]+x}" ]]
}

lock_acquire() {
  local msg=""
  if [[ "${1-}" == -m ]]; then
    msg="${2-}"
    shift 2 || die "lock_acquire: -m needs a message"
  fi
  local name="${1-}" timeout="${2:-$FNKC_LOCK_TIMEOUT}" rank held hrank
  rank="$(_lock_rank "$name")" || die "invalid lock name"
  is_match '[0-9]{1,6}(\.[0-9]{1,3})?' "$timeout" 16 || die "lock_acquire: invalid timeout for $name"
  for held in "${!_FNKC_LOCK_FD[@]}"; do
    hrank="$(_lock_rank "$held")"
    ((hrank < rank)) || die "lock order violation: $name while holding $held"
  done

  local dir="$FNKC_LOCK_DIR"
  [[ "$dir" == /* ]] || die "lock directory must be an absolute path: $dir"
  # Parents with the default mode, the lock directory itself private; another process may create it meanwhile.
  if [[ ! -d "$dir" ]]; then
    mkdir -p -- "${dir%/*}" && { mkdir -m 700 -- "$dir" 2>/dev/null || [[ -d "$dir" ]]; } ||
      die "cannot create lock directory $dir"
  fi
  local path="$dir/$name.kernel"
  [[ ! -L "$path" ]] || die "refusing lock file that is a symlink: $path"

  local fd old_umask
  old_umask="$(umask)"
  umask 077
  if ! exec {fd}>>"$path"; then
    umask "$old_umask"
    die "cannot open lock file $path"
  fi
  umask "$old_umask"
  # Root (admin commands) creates the file for the account that owns the directory, which takes it later.
  if ((EUID == 0)); then
    chown --reference="$dir" -- "$path" || {
      exec {fd}>&-
      die "cannot hand lock file $path to the owner of $dir"
    }
  fi

  local rc=0
  flock -n "$fd" || rc=$?
  if ((rc == 1)); then
    # stderr itself, not log: on a host log goes to the journal, and the waiting user must see this.
    [[ -z "$msg" ]] || printf '%s: %s\n' "$FNKC_LOG_TAG" "$(_fnkc_oneline "$msg")" >&2
    rc=0
    flock -E "$FNKC_BUSY_STATUS" -w "$timeout" "$fd" || rc=$?
  fi
  if ((rc != 0)); then
    exec {fd}>&-
    ((rc == FNKC_BUSY_STATUS)) && die_status "$FNKC_BUSY_STATUS" "operation is busy; timed out waiting for $path"
    die "cannot lock $path (flock status $rc)"
  fi
  _FNKC_LOCK_FD["$name"]="$fd"
}

lock_release() {
  local name="${1-}"
  is_lock_held "$name" || die "lock_release: $name is not held"
  local fd="${_FNKC_LOCK_FD[$name]}"
  unset '_FNKC_LOCK_FD[$name]'
  exec {fd}>&-
}

with_lock() {
  local opt=()
  if [[ "${1-}" == -m ]]; then
    opt=(-m "${2-}")
    shift 2 || die "with_lock: -m needs a message"
  fi
  local name="${1-}" timeout="${2-}"
  [[ "${3-}" == -- && $# -ge 4 ]] || die "usage: with_lock [-m <message>] <name> <timeout> -- <command...>"
  shift 3
  lock_acquire "${opt[@]}" "$name" "$timeout"
  # Under errexit a failing command ends the process here, and the kernel releases the lock; when the caller turned
  # errexit off (with_lock ... || ...), its status is kept and the lock released.
  local rc=0
  "$@"
  rc=$?
  lock_release "$name"
  return "$rc"
}
