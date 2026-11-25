#!/usr/bin/env bash
# names.sh: Docker object names and labels of a user's project, user/project validation and the ownership predicate
# (docs/spec.md «Names»; ported from positron-remote src/layout.ts, src/validate.ts and the ownership checks of
# src/agent.ts).
#
#   source "$FNKC_LIB/names.sh"
#
#   check_user <user> / check_project <project>     validate or die (message from validate.ts)
#   is_user <user> / is_project <project>           the same as a predicate
#   project_container <user> <project>              fnkcsh-<user>-<project>
#   project_volume <user> <project> <project|data|library>
#   project_network <user> <project>                fnkcsh-<user>-<project>-net
#   extensions_volume <user> <project> <x64|arm64> <commit>
#   recovery_container <user> <project>             fnkcsh.recovery.<user>.<project>
#   helper_container <read|ext> <user> <project> <12 hex>
#   is_helper_of <user> <project> <name>            the anchored helperPattern, without building a regex from input
#   is_project_object_name <kind> <user> <project> <name>   <name> is one of the names above for this kind
#   is_owned <kind> <user> <project> <inspect-json> one object passes the ownership predicate
#
# Every name function validates its arguments first and dies on a bad one, so a name is never built from unchecked
# input. All names start "fnkcsh-" or "fnkcsh.": positron-remote's start "fnkc-" or "fnkc." and its labels are
# "fnkc.<key>", so neither tool ever matches the other's objects.
#
# Ownership (docs/spec.md «Names»): an object belongs to <user>'s <project> only when its labels say
# fnkcsh.managed=1, fnkcsh.user=<user>, fnkcsh.project=<project>, it carries no fnkcsh.restore label, and its name is
# one this file computes for that user, project and kind. Labels alone are not enough (a mislabelled object under
# someone else's name), and neither is the name (an object under the name that someone else created).

# shellcheck shell=bash
[[ -n "${FNKC_NAMES_LOADED:-}" ]] && return 0
FNKC_NAMES_LOADED=1

# shellcheck source=server/lib/core.sh
source "${FNKC_LIB:?FNKC_LIB is not set}/core.sh"

readonly FNKC_PREFIX=fnkcsh

# Letters and digits only: the user is the part of fnkcsh-<user>-<project> up to the first "-", so objects of
# different users never get the same name (validate.ts USER_RE).
readonly FNKC_USER_RE='[a-z][a-z0-9]{0,31}'
readonly FNKC_PROJECT_RE='[A-Za-z0-9][A-Za-z0-9_.-]{0,62}'
readonly FNKC_COMMIT_RE='[0-9a-f]{40}'
readonly FNKC_ARCH_RE='x64|arm64'
readonly FNKC_HELPER_KIND_RE='read|ext'
readonly FNKC_HELPER_ID_RE='[0-9a-f]{12}'

# Labels (layout.ts LABEL, HELPER_LABEL). LABEL_RESTORE: on a volume an archive was restored into, never read,
# mounted or deleted as a project's, whatever its name. Helpers carry their own labels, not fnkcsh.user and
# fnkcsh.project, which admission counts as projects.
# shellcheck disable=SC2034 # used by the scripts that source this file
readonly LABEL_MANAGED=fnkcsh.managed LABEL_USER=fnkcsh.user LABEL_PROJECT=fnkcsh.project LABEL_SETUP=fnkcsh.setup \
  LABEL_REPOSITORY=fnkcsh.repository LABEL_REVISION=fnkcsh.revision LABEL_PROVENANCE=fnkcsh.provenance \
  LABEL_RESTORE=fnkcsh.restore \
  HELPER_LABEL_KIND=fnkcsh.helper HELPER_LABEL_USER=fnkcsh.helper.user HELPER_LABEL_PROJECT=fnkcsh.helper.project

is_user() { is_match "$FNKC_USER_RE" "${1-}" 32; }
is_project() { is_match "$FNKC_PROJECT_RE" "${1-}" 63; }

check_user() {
  is_user "${1-}" || die "invalid user name: '${1:0:64}' (lowercase letters and digits, starting with a letter)"
}

check_project() {
  is_project "${1-}" || die "invalid project name: '${1:0:64}'"
}

_names_check() { # _names_check <user> <project>
  check_user "${1-}"
  check_project "${2-}"
}

project_container() {
  _names_check "${1-}" "${2-}"
  printf '%s\n' "$FNKC_PREFIX-$1-$2"
}

project_volume() {
  _names_check "${1-}" "${2-}"
  case "${3-}" in
    project | data | library) printf '%s\n' "$FNKC_PREFIX-$1-$2-$3" ;;
    *) die "project_volume: unknown volume kind" ;;
  esac
}

project_network() {
  _names_check "${1-}" "${2-}"
  printf '%s\n' "$FNKC_PREFIX-$1-$2-net"
}

extensions_volume() {
  _names_check "${1-}" "${2-}"
  is_match "$FNKC_ARCH_RE" "${3-}" 5 || die "extensions_volume: invalid architecture"
  is_match "$FNKC_COMMIT_RE" "${4-}" 40 || die "not a Positron commit: '${4:0:64}'"
  printf '%s\n' "$FNKC_PREFIX-ext-$1-$2-$3-${4:0:12}"
}

recovery_container() {
  _names_check "${1-}" "${2-}"
  printf '%s\n' "$FNKC_PREFIX.recovery.$1.$2"
}

helper_container() {
  is_match "$FNKC_HELPER_KIND_RE" "${1-}" 4 || die "helper_container: unknown helper kind"
  _names_check "${2-}" "${3-}"
  is_match "$FNKC_HELPER_ID_RE" "${4-}" 12 || die "helper_container: invalid helper id"
  printf '%s\n' "$FNKC_PREFIX.$1.$2.$3.$4"
}

# is_helper_of <user> <project> <name>: <name> is fnkcsh.(read|ext).<user>.<project>.<12 hex>, exactly. The user and
# project are compared as literal strings, so project "a" never matches helpers of project "a.b".
is_helper_of() {
  local user="${1-}" project="${2-}" name="${3-}" rest
  is_user "$user" && is_project "$project" || return 1
  is_match '[A-Za-z0-9_.-]+' "$name" 128 || return 1
  case "$name" in
    "$FNKC_PREFIX.read."*) rest="${name#"$FNKC_PREFIX.read."}" ;;
    "$FNKC_PREFIX.ext."*) rest="${name#"$FNKC_PREFIX.ext."}" ;;
    *) return 1 ;;
  esac
  [[ "${rest%.*}" == "$user.$project" ]] && is_match "$FNKC_HELPER_ID_RE" "${rest##*.}" 12
}

# is_project_object_name <container|volume|network> <user> <project> <name>
is_project_object_name() {
  local kind="${1-}" user="${2-}" project="${3-}" name="${4-}" base rest
  is_user "$user" && is_project "$project" || return 1
  base="$FNKC_PREFIX-$user-$project"
  case "$kind" in
    container) [[ "$name" == "$base" || "$name" == "$FNKC_PREFIX.recovery.$user.$project" ]] ;;
    network) [[ "$name" == "$base-net" ]] ;;
    volume)
      case "$name" in
        "$base-project" | "$base-data" | "$base-library") return 0 ;;
        "$FNKC_PREFIX-ext-$user-$project-"*)
          rest="${name#"$FNKC_PREFIX-ext-$user-$project-"}"
          is_match "($FNKC_ARCH_RE)-[0-9a-f]{12}" "$rest" 18
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# _names_fields <kind> <inspect-json>: name, managed, user, project and restore (1 if the label is present) of one
# inspected object, one per line as jq's @json strings. Values are only compared, never used as names.
_names_fields() {
  local kind="$1" json="$2"
  jq -er --arg kind "$kind" --arg m "$LABEL_MANAGED" --arg u "$LABEL_USER" --arg p "$LABEL_PROJECT" \
    --arg r "$LABEL_RESTORE" '
      (if type == "array" then .[0] else . end) as $o
      | ($o | objects) as $o
      | (if $kind == "container" then $o.Config.Labels else $o.Labels end) as $l
      | (($l | objects) // {}) as $l
      | [($o.Name | strings | ltrimstr("/")) // "",
         ($l[$m] | strings) // "", ($l[$u] | strings) // "", ($l[$p] | strings) // "",
         (if $l | has($r) then "1" else "0" end)]
      | map(@json) | .[]' <<<"$json"
}

# is_owned <container|volume|network> <user> <project> <inspect-json>: the object (an inspect array of one, or one
# object) belongs to <user>'s <project> by labels and name. Anything else, unreadable JSON included, is not owned.
is_owned() {
  local kind="${1-}" user="${2-}" project="${3-}" json="${4-}" fields
  local -a f=()
  is_user "$user" && is_project "$project" || return 1
  fields="$(_names_fields "$kind" "$json" 2>/dev/null)" || return 1
  mapfile -t f <<<"$fields"
  ((${#f[@]} == 5)) || return 1
  [[ "${f[1]}" == '"1"' && "${f[2]}" == "\"$user\"" && "${f[3]}" == "\"$project\"" && "${f[4]}" == '"0"' ]] ||
    return 1
  # @json of a valid name is the name in quotes; anything that needed escaping fails the name check.
  [[ "${f[0]}" == \"*\" ]] || return 1
  is_project_object_name "$kind" "$user" "$project" "${f[0]:1:${#f[0]}-2}"
}
