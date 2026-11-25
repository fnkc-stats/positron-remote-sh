#!/usr/bin/env bash
# docker.sh: the docker CLI with timeouts, ownership-checked lookups and helper containers (ported from
# positron-remote src/docker.ts, src/helper.ts and Agent.own in src/agent.ts).
#
#   source "$FNKC_LIB/docker.sh"
#
#   docker_capture [-t secs] -- <args...>   run docker; sets DOCKER_OUT, DOCKER_ERR, DOCKER_STATUS (124: timed out)
#                                           and returns 0, so a caller's `||` never turns off errexit in here
#   docker_ok [-t secs] -- <args...>        run docker; print its stdout, or die with its error (also on timeout)
#   docker_inspect <kind> <name>            inspect array of one object, or nothing when it does not exist
#   own_object <kind> <user> <project> <name>
#                                           the object's inspect JSON if it is the user's project object, nothing
#                                           if it does not exist; anything else under the name dies with
#                                           "refusing <kind> not owned by this user/project: <name>"
#   find_owned <kind> <user> [project]      JSON array of the user's (project's) objects that pass is_owned
#   run_helper [-o file] [-e file] <kind> <user> <project> <secs> <exited> -- <args...>
#                                           a helper container; sets HELPER_STATUS (124: timed out), returns 0
#   remove_helpers <user> <project>         remove this project's leftover helper containers
#
# Kinds are container, volume and network. Every docker call has a deadline (FNKC_DOCKER_TIMEOUT, default 120 s,
# as exec.ts): `timeout` sends TERM, then KILL 5 s later. A killed docker CLI may leave its container running, which
# is why helpers are removed by name.
#
# Use docker_ok inside "$(...)": a die there stops the caller through errexit. Do not call own_object or find_owned
# as an `if` or `||` condition: errexit is off there, so a refusal would read as "not found". Assign first, then test.

# shellcheck shell=bash
[[ -n "${FNKC_DOCKER_LOADED:-}" ]] && return 0
FNKC_DOCKER_LOADED=1

# shellcheck source=server/lib/names.sh
source "${FNKC_LIB:?FNKC_LIB is not set}/names.sh"

: "${FNKC_DOCKER_TIMEOUT:=120}"
DOCKER_OUT="" DOCKER_ERR="" DOCKER_STATUS=0 HELPER_STATUS=0

# Options of every helper (helper.ts HELPER_OPTIONS): docker-init as PID 1 so it dies on a signal, no log driver,
# read-only image, no network, no capabilities, no privilege gain. The caller adds the user, memory and process
# limits, and any capability it needs back.
readonly -a HELPER_OPTIONS=(--init --log-driver none --read-only --stop-timeout 1 --network none
  --security-opt no-new-privileges --cap-drop ALL --cpus 1)

# _docker_secs <secs>: a positive whole number of seconds or die.
_docker_secs() {
  [[ "${1-}" =~ ^[1-9][0-9]{0,4}$ ]] || die "docker: invalid timeout"
}

docker_capture() {
  local secs="$FNKC_DOCKER_TIMEOUT" errf rc=0
  if [[ "${1-}" == -t ]]; then
    secs="${2-}"
    shift 2 || die "docker_capture: -t needs a value"
  fi
  [[ "${1-}" == -- ]] || die "docker_capture: missing --"
  shift
  _docker_secs "$secs"
  errf="$(mktemp)"
  DOCKER_OUT="$(timeout -k 5 -- "$secs" docker "$@" 2>"$errf")" || rc=$?
  DOCKER_ERR="$(<"$errf")"
  rm -f -- "$errf"
  # timeout: 124 when the deadline passed, 137 when docker had to be killed after it
  if ((rc == 137)); then rc=124; fi
  DOCKER_STATUS=$rc
  return 0
}

# _docker_why: DOCKER_ERR trimmed, or what happened when it is empty (exec.ts runOk; die and log make it one line).
_docker_why() {
  if ((DOCKER_STATUS == 124)); then
    printf 'operation timed out'
    return
  fi
  local why="$DOCKER_ERR"
  why="${why#"${why%%[![:space:]]*}"}"
  why="${why%"${why##*[![:space:]]}"}"
  printf '%s' "${why:-exit code $DOCKER_STATUS}"
}

docker_ok() {
  docker_capture "$@"
  if ((DOCKER_STATUS != 0)); then
    local -a args=("$@")
    while ((${#args[@]})) && [[ "${args[0]}" != -- ]]; do args=("${args[@]:1}"); done
    local what="docker${args[1]+ ${args[1]}}${args[2]+ ${args[2]}}"
    die "$what: $(_docker_why)"
  fi
  [[ -z "$DOCKER_OUT" ]] || printf '%s\n' "$DOCKER_OUT"
}

# _docker_kind <kind>: container, volume or network.
_docker_kind() {
  case "${1-}" in
    container | volume | network) ;;
    *) die "docker: unknown object kind" ;;
  esac
}

# _docker_only_missing: DOCKER_ERR is not empty and every line says an object does not exist (docker.ts onlyMissing).
_docker_only_missing() {
  local line seen=0
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    shopt -s nocasematch
    if ! [[ "$line" =~ no\ such\ (object|container|image|volume|network) ]]; then
      shopt -u nocasematch
      return 1
    fi
    shopt -u nocasematch
    seen=1
  done <<<"$DOCKER_ERR"
  ((seen))
}

docker_inspect() {
  local kind="${1-}" name="${2-}"
  _docker_kind "$kind"
  is_match '[A-Za-z0-9][A-Za-z0-9_.-]*' "$name" 255 || die "docker: invalid $kind name"
  docker_capture -- "$kind" inspect -- "$name"
  if ((DOCKER_STATUS != 0)); then
    _docker_only_missing && return 0
    die "cannot inspect $kind: $(_docker_why)"
  fi
  jq -e 'type == "array" and length == 1' <<<"$DOCKER_OUT" >/dev/null 2>&1 ||
    die "cannot inspect $kind: unexpected output from docker"
  printf '%s\n' "$DOCKER_OUT"
}

own_object() {
  local kind="${1-}" user="${2-}" project="${3-}" name="${4-}" json
  _docker_kind "$kind"
  check_user "$user"
  check_project "$project"
  is_project_object_name "$kind" "$user" "$project" "$name" ||
    die "own_object: $name is not a name of this user's project"
  json="$(docker_inspect "$kind" "$name")"
  [[ -n "$json" ]] || return 0
  is_owned "$kind" "$user" "$project" "$json" || die "refusing $kind not owned by this user/project: $name"
  printf '%s\n' "$json"
}

find_owned() {
  local kind="${1-}" user="${2-}" project="${3-}" ids all keep="[]" i n obj owner_project
  local -a filters idlist=()
  _docker_kind "$kind"
  check_user "$user"
  [[ -z "$project" ]] || check_project "$project"
  filters=(--filter "label=$LABEL_MANAGED=1" --filter "label=$LABEL_USER=$user")
  [[ -z "$project" ]] || filters+=(--filter "label=$LABEL_PROJECT=$project")
  if [[ "$kind" == container ]]; then
    ids="$(docker_ok -- ps -aq --no-trunc "${filters[@]}")"
  else
    ids="$(docker_ok -- "$kind" ls -q "${filters[@]}")"
  fi
  if [[ -n "$ids" ]]; then mapfile -t idlist <<<"$ids"; fi
  for i in "${idlist[@]}"; do
    is_match '[A-Za-z0-9][A-Za-z0-9_.-]*' "$i" 255 || die "docker: unexpected $kind id in listing"
  done
  if ((${#idlist[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  # Objects listed a moment ago may be gone (other users' --rm helpers): docker prints the rest and fails.
  docker_capture -- "$kind" inspect -- "${idlist[@]}"
  if ((DOCKER_STATUS != 0)) && ! _docker_only_missing; then die "cannot inspect ${kind}s: $(_docker_why)"; fi
  all="${DOCKER_OUT:-[]}"
  n="$(jq -er 'if type == "array" then length else error("not an array") end' <<<"$all" 2>/dev/null)" ||
    die "cannot inspect ${kind}s: unexpected output from docker"
  for ((i = 0; i < n; i++)); do
    obj="$(jq -c --argjson i "$i" '[.[$i]]' <<<"$all")"
    if [[ -n "$project" ]]; then
      owner_project="$project"
    else
      owner_project="$(jq -r --arg kind "$kind" --arg p "$LABEL_PROJECT" \
        '.[0] | (if $kind == "container" then .Config.Labels else .Labels end) // {} | .[$p] | strings' <<<"$obj")"
    fi
    if is_owned "$kind" "$user" "$owner_project" "$obj"; then
      keep="$(jq -c --argjson o "$obj" '. + $o' <<<"$keep")"
    fi
  done
  printf '%s\n' "$keep"
}

# _helper_remove <name>: docker rm -f; a container that is already gone or being removed is fine.
_helper_remove() {
  docker_capture -t 30 -- rm -f -- "$1"
  ((DOCKER_STATUS != 0)) || return 0
  shopt -s nocasematch
  if [[ "$DOCKER_ERR" =~ no\ such\ container|already\ in\ progress ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  log warning "could not remove the helper container $1: $(_docker_why)"
}

# Matched by the exact name (is_helper_of), never by a prefix or Docker's name filter (a substring match). A listing
# failure is only a warning, as in helper.ts: the caller's own helper still runs.
remove_helpers() {
  local user="${1-}" project="${2-}" name
  local -a names=()
  check_user "$user"
  check_project "$project"
  docker_capture -t 30 -- ps -a --format '{{.Names}}'
  if ((DOCKER_STATUS != 0)); then
    log warning "could not list leftover helper containers: $(_docker_why)"
    return 0
  fi
  if [[ -n "$DOCKER_OUT" ]]; then mapfile -t names <<<"$DOCKER_OUT"; fi
  for name in "${names[@]}"; do
    name="${name//[[:space:]]/}"
    if is_helper_of "$user" "$project" "$name"; then _helper_remove "$name"; fi
  done
}

# _helper_id: 12 random hex digits.
_helper_id() {
  local id
  id="$(od -An -tx1 -N6 /dev/urandom)"
  id="${id//[^0-9a-f]/}"
  [[ "$id" =~ ^[0-9a-f]{12}$ ]] || die "helper: no random id"
  printf '%s' "$id"
}

# run_helper: the caller holds the project's lock, so no other helper of this project runs and leftovers (from a
# gateway that died while its helper ran) are removed first. <exited> lists the exit codes, space-separated, that mean
# the container ran to its end and --rm removed it; after any other outcome it is removed by name. Output goes to
# -o/-e files when given, else to this process's stdout/stderr.
run_helper() {
  local out=/dev/stdout err=/dev/stderr kind user project secs exited name code clean=0
  local -a codes=()
  while [[ "${1-}" == -o || "${1-}" == -e ]]; do
    [[ -n "${2-}" ]] || die "run_helper: $1 needs a file"
    if [[ "$1" == -o ]]; then out="$2"; else err="$2"; fi
    shift 2
  done
  (($# >= 6)) || die "run_helper: missing arguments"
  kind="$1" user="$2" project="$3" secs="$4" exited="$5"
  [[ "$6" == -- ]] || die "run_helper: missing --"
  shift 6
  [[ "$exited" =~ ^[0-9]{1,3}( [0-9]{1,3})*$ ]] || die "run_helper: invalid exit codes"
  _docker_secs "$secs"
  name="$(helper_container "$kind" "$user" "$project" "$(_helper_id)")"
  remove_helpers "$user" "$project"
  HELPER_STATUS=0
  timeout -k 5 -- "$secs" docker run --rm --name "$name" \
    --label "$HELPER_LABEL_KIND=$kind" --label "$HELPER_LABEL_USER=$user" --label "$HELPER_LABEL_PROJECT=$project" \
    "${HELPER_OPTIONS[@]}" "$@" >"$out" 2>"$err" || HELPER_STATUS=$?
  if ((HELPER_STATUS == 137)); then HELPER_STATUS=124; fi
  read -ra codes <<<"$exited"
  for code in "${codes[@]}"; do
    if ((code == HELPER_STATUS)) && ((HELPER_STATUS != 124)); then clean=1; fi
  done
  ((clean)) || _helper_remove "$name"
  return 0
}
