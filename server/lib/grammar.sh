# shellcheck shell=bash disable=SC2034 # the tables and GRAMMAR_* are read by serve.sh and the request files
# grammar.sh: every gateway request, its arguments and its stdin, and the value patterns (docs/spec.md «Requests»,
# «Argument rules»; src/serve.ts handle, src/validate.ts, src/repository.ts). Complete from the spec: a request task
# adds its server/requests/<request>.sh and never edits this file.
#
#   grammar_check <request> [word...]   validates the words after the request; on success fills GRAMMAR_ARGS with
#                                        the values to use (repository without trailing "/"), on failure sets
#                                        GRAMMAR_ERROR to the message (src/serve.ts wording) and returns 1
#   grammar_value <kind> <value>         one value against its pattern and extra rule; the value to use in
#                                        GRAMMAR_VALUE, or GRAMMAR_ERROR and status 1
#
# Patterns are written without ^ and $: is_match (core.sh) anchors them, matches in the C locale and refuses empty
# values, a leading "-", control characters and values over the cap below.

[[ -n "${FNKC_GRAMMAR_LOADED:-}" ]] && return 0
FNKC_GRAMMAR_LOADED=1

# Requests, in the spec's order.
FNKC_REQUESTS=(ping list images start stop busy keep checkout remove-check remove install-image connect)

# Argument kinds after the request word; a trailing "?" marks the last one optional.
declare -A FNKC_REQUEST_ARGS=(
  [ping]='' [list]='' [images]='' [start]=''
  [stop]='project repository?' [busy]=project [keep]=project [checkout]=project ["remove-check"]=project
  [remove]='project fingerprint' ["install-image"]=image [connect]=project
)

# stdin: ignored (never read), json (one document of at most FNKC_MAX_REQUEST bytes, read within
# FNKC_REQUEST_SECONDS, handed to the request as a file), stream (the request reads it), raw (connect: the stream).
declare -A FNKC_REQUEST_STDIN=(
  [ping]=ignored [list]=ignored [images]=ignored [start]=json [stop]=ignored [busy]=ignored [keep]=ignored
  [checkout]=ignored ["remove-check"]=ignored [remove]=ignored ["install-image"]=stream [connect]=raw
)

# Message for a wrong number of words where src/serve.ts has its own; otherwise "too many arguments" and
# "<request>: project name required".
declare -A FNKC_REQUEST_USAGE=(
  [remove]='remove: expected <project> <fingerprint from remove-check>'
  ["install-image"]='install-image: expected <image>'
  [connect]='connect requires exactly one project'
)

FNKC_MAX_REQUEST=$((2 * 1024 * 1024))
FNKC_REQUEST_SECONDS=10

# Value patterns (unanchored; ERE, so a bracket holds no escapes: is_match refuses every control character, which
# covers the key comment's [^\r\n]) and length caps in bytes.
declare -A FNKC_RE=(
  [project]='[A-Za-z0-9][A-Za-z0-9_.-]{0,62}'
  [user]='[a-z][a-z0-9]{0,31}'
  [fingerprint]='[0-9a-f]{64}'
  [image]='[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}'
  [repository]='(ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+(:[0-9]+)?/|https://[A-Za-z0-9.-]+(:[0-9]+)?/|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)[A-Za-z0-9_./-]+'
  [version]='[0-9]{4}\.[0-9]{2}\.[0-9]+-[0-9]+'
  [commit]='[0-9a-f]{40}'
  [sshkey]='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^[:cntrl:]]*)?'
)
declare -A FNKC_MAX=(
  [project]=63 [user]=32 [fingerprint]=64 [image]=1024 [repository]=1024 [version]=64 [commit]=40 [sshkey]=16384
)

# Messages for a refused value (src/validate.ts, src/repository.ts); %s is the value.
declare -A FNKC_INVALID=(
  [project]="invalid project name: '%s'"
  [user]="invalid user name: '%s' (lowercase letters and digits, starting with a letter)"
  [fingerprint]='remove: expected <project> <fingerprint from remove-check>'
  [image]='image must be pinned as repository@sha256:<64 lowercase hex digits>: %s'
  [repository]='repository must be an SSH or HTTPS URL without embedded credentials or shell syntax'
  [version]="not a Positron version: '%s' (expected something like 2026.07.1-5)"
  [commit]="not a Positron commit: '%s'"
  [sshkey]='not an SSH public key (expected one line such as "ssh-ed25519 AAAA... name")'
)

GRAMMAR_ARGS=()
GRAMMAR_VALUE=''
GRAMMAR_ERROR=''

grammar_value() {
  local kind="${1:-}" value="${2-}"
  GRAMMAR_VALUE='' GRAMMAR_ERROR=''
  [[ -n "$kind" && -n "${FNKC_RE[$kind]+x}" ]] || die "grammar: unknown value kind"
  if ! is_match "${FNKC_RE[$kind]}" "$value" "${FNKC_MAX[$kind]}"; then
    # shellcheck disable=SC2059 # the formats are the fixed messages above
    printf -v GRAMMAR_ERROR "${FNKC_INVALID[$kind]}" "$value"
    return 1
  fi
  if [[ "$kind" == repository ]]; then
    case "/$value/" in
      */../*)
        GRAMMAR_ERROR='repository path cannot contain ..'
        return 1
        ;;
    esac
    while [[ "$value" == */ ]]; do value="${value%/}"; done
  fi
  GRAMMAR_VALUE="$value"
}

grammar_check() {
  local request="${1:-}"
  shift || true
  GRAMMAR_ARGS=() GRAMMAR_ERROR=''
  [[ -n "$request" && -n "${FNKC_REQUEST_ARGS[$request]+x}" ]] || {
    GRAMMAR_ERROR="unknown request"
    return 1
  }
  local -a kinds
  read -r -a kinds <<<"${FNKC_REQUEST_ARGS[$request]}"
  local min=0 max=${#kinds[@]} k
  for k in "${kinds[@]}"; do [[ "$k" == *'?' ]] || min=$((min + 1)); done
  if (($# < min || $# > max)); then
    if [[ -n "${FNKC_REQUEST_USAGE[$request]+x}" ]]; then
      GRAMMAR_ERROR="${FNKC_REQUEST_USAGE[$request]}"
    elif (($# > max)); then
      GRAMMAR_ERROR='too many arguments'
    else
      GRAMMAR_ERROR="$request: project name required"
    fi
    return 1
  fi
  local i=0 w
  for w in "$@"; do
    k="${kinds[$i]%\?}"
    grammar_value "$k" "$w" || return 1
    GRAMMAR_ARGS+=("$GRAMMAR_VALUE")
    i=$((i + 1))
  done
}
