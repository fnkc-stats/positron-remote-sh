# shellcheck shell=bash
# journal.sh: one line per request in the system journal (docs/spec.md «Journal»; src/journal.ts). All users share
# the gateway account, so this line is the only record of who asked for what, from where, and how it went.
#
#   journal_begin <dir>             start a request's record; fields are kept in files under <dir>, so values set in
#                                   subshells (requests run in one) still count
#   journal_set <key> <value>...    set fields (key=value pairs as separate words; an empty value leaves it out); a
#                                   key set again keeps its first position, as Object.assign does
#   journal_warn <message>          a warning for the line's `warnings`
#   journal_end <ok|error> [code] [error]   append ms, result, code, error, warnings, ctl and write the line
#   journal_format <key> <value>... the line itself (formatLine): values with spaces, quotes, "=", "\" or anything
#                                   outside printable ASCII are JSON-quoted; values over 1000 characters are cut
#
# The line goes to `logger -t fnkc-ctl-sh` (user.info, user.warning for a failure); a host without logger, or a
# logger that fails, loses the line, never the request.

[[ -n "${FNKC_JOURNAL_LOADED:-}" ]] && return 0
FNKC_JOURNAL_LOADED=1

FNKC_JOURNAL_TAG=fnkc-ctl-sh
_FNKC_JOURNAL_DIR=''
_FNKC_JOURNAL_T0=''

_journal_now_ms() {
  local t="${EPOCHREALTIME/./}"
  printf '%s' "$((10#$t / 1000))"
}

journal_begin() {
  _FNKC_JOURNAL_DIR="$1"
  _FNKC_JOURNAL_T0="$(_journal_now_ms)"
  : >"$_FNKC_JOURNAL_DIR/journal-fields"
  : >"$_FNKC_JOURNAL_DIR/journal-warnings"
}

journal_set() {
  [[ -n "$_FNKC_JOURNAL_DIR" ]] || return 0
  while (($# >= 2)); do
    printf '%s\0%s\0' "$1" "$2" >>"$_FNKC_JOURNAL_DIR/journal-fields"
    shift 2
  done
}

journal_warn() {
  [[ -n "$_FNKC_JOURNAL_DIR" ]] || return 0
  printf '%s\0' "${1-}" >>"$_FNKC_JOURNAL_DIR/journal-warnings"
}

journal_format() {
  # Every word goes in as the value of --arg (never as a positional, which an old jq may read as an option).
  local -a named=()
  local i=0
  while (($# >= 2)); do
    named+=(--arg "k$i" "$1" --arg "v$i" "$2")
    i=$((i + 1))
    shift 2
  done
  jq -nr --argjson n "$i" "${named[@]}" '
    [range(0; $n) as $i | [$ARGS.named["k\($i)"], $ARGS.named["v\($i)"]] | select(.[1] != "")
     | (.[1] | if length > 1000 then .[0:1000] + "\u2026" else . end) as $s
     | .[0] + "=" + (if ($s | test("^[!-~]+$")) and ($s | test("[\"=\\\\]") | not) then $s else ($s | tojson) end)]
    | join(" ")'
}

journal_end() {
  [[ -n "$_FNKC_JOURNAL_DIR" ]] || return 0
  local result="${1:-error}" code="${2-}" error="${3-}"
  local -a order=() pairs=()
  local -A value=()
  local k v
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    [[ -n "${value[$k]+x}" ]] || order+=("$k")
    value[$k]="$v"
  done <"$_FNKC_JOURNAL_DIR/journal-fields"
  for k in "${order[@]}"; do pairs+=("$k" "${value[$k]}"); done
  local warnings='' w
  while IFS= read -r -d '' w; do
    warnings+="${warnings:+ | }$w"
  done <"$_FNKC_JOURNAL_DIR/journal-warnings"
  local ms=$(($(_journal_now_ms) - _FNKC_JOURNAL_T0))
  pairs+=(ms "$ms" result "$result" code "$code" error "$error" warnings "$warnings" ctl "${FNKC_VERSION-}")
  _FNKC_JOURNAL_DIR=''
  local line prio=user.info
  line="$(journal_format "${pairs[@]}")" || return 0
  [[ "$result" == ok ]] || prio=user.warning
  command -v logger >/dev/null 2>&1 || return 0
  timeout 5 logger -t "$FNKC_JOURNAL_TAG" -p "$prio" -- "$line" </dev/null >/dev/null 2>&1 || true
}
