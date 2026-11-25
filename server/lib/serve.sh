# shellcheck shell=bash
# serve.sh: `fnkc-ctl serve --user <user>`, the forced command (docs/spec.md «Entry»; src/cli.ts serve, src/serve.ts).
# server/fnkc-ctl has already replaced the environment. Order: arguments and config (failures: "Error: …" on stderr,
# exit 1, no reply), SSH_ORIGINAL_COMMAND (the same), then the request: known word and request file (else
# unknown-command), word count and values (grammar.sh), the user's key, bounded stdin, and the request file, run as
# its own process (request.sh). One reply line on stdout (connect: none), one journal line, exit 0 or 1.

source "$FNKC_LIB/grammar.sh"
source "$FNKC_LIB/reply.sh"
source "$FNKC_LIB/journal.sh"

FNKC_DEFAULT_AGENT_CONFIG=/etc/fnkc-ctl-sh/agent.json
FNKC_DEFAULT_TRUSTED_ROOT=/etc/fnkc-ctl-sh/trusted-root.jsonl
# Longer than any valid command line (the longest word is 1024 bytes).
FNKC_MAX_COMMAND=4096
FNKC_UNKNOWN_HELP='ping, list, images, stop <project> [<repository>], busy <project>, keep <project>, checkout <project>, remove-check <project>, remove <project> <fingerprint>, start, install-image <image>'

_SERVE_DIR=''
_SERVE_REPLY=none # none: nothing to send yet; json: an envelope is owed; sent

# _serve_fatal <message>: a failure outside a request: journal line, "Error: …" on stderr, exit 1.
_serve_fatal() {
  journal_end error '' "$1"
  printf 'Error: %s\n' "$(_fnkc_oneline "$1")" >&2
  exit 1
}

# _serve_answer_error <message> [code] [extra-file]: the request's error reply (or stderr for connect) and exit 1.
_serve_answer_error() {
  journal_end error "${2-}" "$1"
  if [[ "$_SERVE_REPLY" == json ]]; then
    _SERVE_REPLY=sent
    reply_error "$@"
  else
    printf 'Error: %s\n' "$(_fnkc_oneline "$1")" >&2
  fi
  exit 1
}

_serve_exit() {
  local status=$?
  # serve itself failed (set -e): still answer and journal, as positron-remote's catch-all does.
  if [[ "$_SERVE_REPLY" == json ]]; then
    _SERVE_REPLY=sent
    reply_error "internal error (status $status)" || true
  fi
  journal_end error '' "internal error (status $status)" || true
  [[ -z "$_SERVE_DIR" ]] || rm -rf -- "$_SERVE_DIR"
}

_serve_version() {
  local v=''
  [[ ! -f "$FNKC_ROOT/VERSION" ]] || v="$(head -c 64 -- "$FNKC_ROOT/VERSION")"
  v="${v%%[[:space:]]*}"
  is_match '[0-9A-Za-z][0-9A-Za-z.+-]*' "$v" 64 || v=0.0.0-unknown
  printf '%s' "$v"
}

# _serve_config <file> <given>: the few agent.json keys serve needs (R4 replaces this with config.sh).
_serve_config() {
  local file="$1" given="$2" json='{}'
  if [[ -e "$file" || "$given" == 1 ]]; then
    json="$(jq -c 'if type == "object" then . else error("not an object") end' <"$file" 2>/dev/null)" ||
      _serve_fatal "agent config $file: not a readable JSON object"
  fi
  local keys
  keys="$(jq -r '
    def str($k): if has($k) | not then ""
      elif (.[$k] | type) == "string" and (.[$k] | explode | all(. >= 32)) then .[$k]
      else error("agent config: \"\($k)\" must be a string") end;
    def bool($k): if has($k) | not then "" elif (.[$k] | type) == "boolean" then (.[$k] | tostring)
      else error("agent config: \"\($k)\" must be true or false") end;
    [str("keysDir"), bool("requireProvenance"), str("trustedRootFile")] | join("\u0001")' \
    <<<"$json" 2>&1)" || _serve_fatal "${keys#jq: error (at <stdin>:*): }"
  IFS=$'\001' read -r FNKC_KEYS_DIR FNKC_REQUIRE_PROVENANCE FNKC_TRUSTED_ROOT_FILE <<<"$keys"
  [[ -n "$FNKC_KEYS_DIR" ]] || _serve_fatal 'server mode requires keysDir'
  : "${FNKC_REQUIRE_PROVENANCE:=true}"
  : "${FNKC_TRUSTED_ROOT_FILE:=$FNKC_DEFAULT_TRUSTED_ROOT}"
  FNKC_AGENT_CONFIG="$file"
}

# _serve_words <line>: SSH_ORIGINAL_COMMAND as parseCommand reads it, into SERVE_WORDS (the words after "agent").
_serve_words() {
  local line="$1" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  local bad="unsupported command: '$trimmed' (expected: agent ping|list|images|stop|busy|keep|checkout|remove-check|remove|start|install-image)"
  ((${#line} <= FNKC_MAX_COMMAND)) || _serve_fatal "unsupported command: '${trimmed:0:64}...' (too long)"
  local -a w=()
  read -r -d '' -a w <<<"${line//[$'\r\v\f']/ }" || true
  [[ "${w[0]-}" != fnkc-ctl ]] || w=("${w[@]:1}")
  [[ "${w[0]-}" == agent ]] || _serve_fatal "$bad"
  SERVE_WORDS=("${w[@]:1}")
}

# _serve_key <user>: the user's key is still enrolled (src/agent.ts authorized): a revoked user gets nothing more.
_serve_key() {
  local file="$FNKC_KEYS_DIR/$1.pub" key
  [[ -f "$file" && -r "$file" ]] || _serve_answer_error "no SSH key for user '$1' on this host"
  key="$(head -c 16385 -- "$file")" || _serve_answer_error "no SSH key for user '$1' on this host"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  grammar_value sshkey "$key" || _serve_answer_error "$GRAMMAR_ERROR"
}

# _serve_stdin <request>: the bounded request document (src/serve.ts readStdin) into $FNKC_STDIN_FILE.
_serve_stdin() {
  FNKC_STDIN_FILE="$_SERVE_DIR/stdin"
  local rc=0 size plain
  timeout "$FNKC_REQUEST_SECONDS" head -c "$((FNKC_MAX_REQUEST + 1))" >"$FNKC_STDIN_FILE" || rc=$?
  ((rc != 124)) || _serve_answer_error 'request timed out'
  ((rc == 0)) || _serve_answer_error "could not read the request (status $rc)"
  size="$(wc -c <"$FNKC_STDIN_FILE")"
  ((size <= FNKC_MAX_REQUEST)) || _serve_answer_error 'request too large'
  plain="$(tr -d '\000' <"$FNKC_STDIN_FILE" | wc -c)"
  ((plain == size)) || _serve_answer_error "$1: expected a JSON request on stdin"
}

serve_main() {
  local user='' config="$FNKC_DEFAULT_AGENT_CONFIG" given=0 path=''
  while (($#)); do
    case "$1" in
      --user | --agent-config | --path)
        (($# >= 2)) || {
          printf 'Error: serve: %s needs a value\n' "$1" >&2
          exit 1
        }
        case "$1" in
          --user) user="$2" ;;
          --agent-config) config="$2" given=1 ;;
          --path) path="$2" ;;
        esac
        shift 2
        ;;
      *)
        printf 'Error: serve: unknown argument %s\n' "'$(_fnkc_oneline "$1")'" >&2
        exit 1
        ;;
    esac
  done
  [[ -n "$user" ]] || {
    printf 'Error: serve: --user is required\n' >&2
    exit 1
  }
  if [[ -n "$path" ]]; then
    is_match '/[A-Za-z0-9._/-]+(:/[A-Za-z0-9._/-]+)*' "$path" 4096 || {
      printf 'Error: serve: --path must be absolute directories separated by ":"\n' >&2
      exit 1
    }
    PATH="$path"
  fi

  FNKC_VERSION="$(_serve_version)"
  _SERVE_DIR="$(mktemp -d)"
  trap _serve_exit EXIT
  # A dropped connection (HUP) or a kill still journals the request and removes the temporary directory.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # One journal line per request, whatever its outcome (src/journal.ts Entry).
  journal_begin "$_SERVE_DIR"
  local from="${SSH_CONNECTION-}"
  from="${from%% *}"
  journal_set user "$user" from "$from"

  grammar_value user "$user" || _serve_fatal "$GRAMMAR_ERROR"
  _serve_config "$config" "$given"
  _serve_words "${SSH_ORIGINAL_COMMAND-}"

  local request="${SERVE_WORDS[0]-}" arg="${SERVE_WORDS[1]-}"
  if [[ "$request" == install-image ]]; then
    journal_set command "$request" image "$arg"
  else
    journal_set command "$request" project "$arg"
  fi
  [[ "$request" == connect ]] || _SERVE_REPLY=json

  local known=0 r file=''
  for r in "${FNKC_REQUESTS[@]}"; do [[ "$request" != "$r" ]] || known=1; done
  ((known)) && file="$FNKC_ROOT/requests/$request.sh"
  [[ -n "$file" && -f "$file" ]] ||
    _serve_answer_error "unknown agent command: '$request' ($FNKC_UNKNOWN_HELP)" unknown-command

  grammar_check "${SERVE_WORDS[@]}" || _serve_answer_error "$GRAMMAR_ERROR"
  local -a args=("${GRAMMAR_ARGS[@]}")

  _serve_key "$user"
  FNKC_STDIN_FILE=''
  [[ "${FNKC_REQUEST_STDIN[$request]}" != json ]] || _serve_stdin "$request"

  FNKC_USER="$user" FNKC_REQUEST="$request" FNKC_REQ_DIR="$_SERVE_DIR"
  export FNKC_USER FNKC_REQUEST FNKC_REQ_DIR FNKC_ROOT FNKC_LIB FNKC_VERSION FNKC_AGENT_CONFIG FNKC_KEYS_DIR \
    FNKC_REQUIRE_PROVENANCE FNKC_TRUSTED_ROOT_FILE FNKC_STDIN_FILE FNKC_LOG FNKC_LOG_TAG

  local rc=0
  if [[ "${FNKC_REQUEST_STDIN[$request]}" == stream ]]; then
    "$BASH" -- "$file" "${args[@]}" >"$_SERVE_DIR/result" || rc=$?
  elif [[ "$_SERVE_REPLY" == json ]]; then
    "$BASH" -- "$file" "${args[@]}" </dev/null >"$_SERVE_DIR/result" || rc=$?
  else
    "$BASH" -- "$file" "${args[@]}" || rc=$?
  fi

  if ((rc == 0)); then
    if [[ "$_SERVE_REPLY" == json ]]; then
      local out
      out="$(reply_ok "$_SERVE_DIR/result" 2>/dev/null)" || _serve_answer_error "internal error: $request gave no valid result"
      _SERVE_REPLY=sent
      printf '%s\n' "$out"
    fi
    journal_end ok
    exit 0
  fi
  local err="$_SERVE_DIR/error" message code
  if [[ -f "$err" ]] && message="$(jq -r '.error | strings' <"$err" 2>/dev/null)" && [[ -n "$message" ]]; then
    code="$(jq -r '.code // "" | strings' <"$err")"
    _serve_answer_error "$message" "$code" "$err"
  fi
  _serve_answer_error "internal error: $request failed (status $rc)"
}
