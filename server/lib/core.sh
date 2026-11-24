#!/usr/bin/env bash
# core.sh: the base every server script sources first (docs/conventions.md).
#
#   source "$FNKC_LIB/core.sh"
#
# It turns on strict mode and provides:
#   log <priority> <message...>   one line to journald via logger, or to stderr (see FNKC_LOG)
#   die <message...>              log at err, print "fnkc-ctl: <message>" to stderr, exit 1
#   die_status <status> <msg...>  the same with an explicit exit status (1-125)
#   is_match <regex> <value> [max]       anchored ERE match in the C locale, with a length cap
#   require_match <what> <regex> <value> [max]   is_match or die "invalid <what>"
#   is_uint <value>               decimal integer without sign or leading zeros
#
# Validation rules (Bash rules in CLAUDE.md): every untrusted value (gateway argument, file name, Docker output) goes
# through is_match/require_match before use. The pattern is anchored here (^(...)$), so callers write it without ^ and
# $. Independently of the pattern, a value is refused when it is empty, starts with "-" (it could be read as an
# option), contains a control character (newline, tab, ESC...) or is longer than <max> bytes (default 256). Matching
# runs with LC_ALL=C, so ranges like [a-z] are ASCII only and Unicode look-alikes never match.
#
# "--" discipline: validated values are still passed after "--" (or as the value of an explicit option) to every
# command that takes options: docker, git, rm, logger, jq --arg. Never eval, never bash -c with input.

# shellcheck shell=bash
[[ -n "${FNKC_CORE_LOADED:-}" ]] && return 0
FNKC_CORE_LOADED=1

set -euo pipefail
shopt -s inherit_errexit

# Name in log lines and messages; scripts may set it before sourcing core.sh.
: "${FNKC_LOG_TAG:=fnkc-ctl}"
# auto: journald via logger when /dev/log is a socket, else stderr; journal: always logger; stderr: never logger.
: "${FNKC_LOG:=auto}"

# Default length cap for validated values, in bytes.
FNKC_MAX_ARG=256

# _fnkc_oneline <text>: control characters (newlines included) replaced by "?", so one call is one log line and input
# cannot forge extra lines.
_fnkc_oneline() {
  local LC_ALL=C
  printf '%s' "${1//[[:cntrl:]]/?}"
}

# _fnkc_journal <priority> <message>: send to journald through logger; fails when FNKC_LOG/the host say stderr or
# logger is missing or fails.
_fnkc_journal() {
  case "$FNKC_LOG" in
    journal) ;;
    stderr) return 1 ;;
    *) [[ -S /dev/log ]] || return 1 ;;
  esac
  command -v logger >/dev/null 2>&1 || return 1
  logger -t "$FNKC_LOG_TAG" -p "user.$1" -- "$2" 2>/dev/null
}

log() {
  local prio="${1:-}"
  shift || true
  case "$prio" in
    debug | info | notice | warning | err | crit) ;;
    *) prio=err ;;
  esac
  local msg
  msg="$(_fnkc_oneline "$*")"
  _fnkc_journal "$prio" "$msg" || printf '%s[%s]: %s\n' "$FNKC_LOG_TAG" "$prio" "$msg" >&2
}

die_status() {
  local status="${1:-}"
  shift || true
  if ! [[ "$status" =~ ^[1-9][0-9]{0,2}$ ]] || ((status > 125)); then status=1; fi
  local msg
  msg="$(_fnkc_oneline "$*")"
  _fnkc_journal err "$msg" || true
  printf '%s: %s\n' "$FNKC_LOG_TAG" "$msg" >&2
  exit "$status"
}

die() {
  die_status 1 "$@"
}

is_match() {
  local regex="${1:-}" value="${2-}" max="${3:-$FNKC_MAX_ARG}"
  local LC_ALL=C
  [[ -n "$regex" && "$max" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ -n "$value" ]] || return 1
  ((${#value} <= max)) || return 1
  [[ "$value" != -* ]] || return 1
  [[ "$value" != *[[:cntrl:]]* ]] || return 1
  [[ "$value" =~ ^($regex)$ ]]
}

require_match() {
  local what="${1:-value}" regex="${2:-}" value="${3-}" max="${4:-$FNKC_MAX_ARG}"
  local rc=0
  is_match "$regex" "$value" "$max" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) die "require_match: bad pattern or limit for $what" ;;
    *) die "invalid $what" ;;
  esac
}

is_uint() {
  is_match '0|[1-9][0-9]*' "${1-}" 19
}
