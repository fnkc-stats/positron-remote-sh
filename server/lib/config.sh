#!/usr/bin/env bash
# config.sh: the host settings, /etc/fnkc-ctl-sh/agent.json (docs/spec.md «agent.json»; ported from positron-remote
# src/agent-config.ts). Requests cannot change any of them.
#
#   source "$FNKC_LIB/config.sh"
#
#   config_load [file] [home]   read, check and fill in defaults; on success set the CFG_* variables below (readonly)
#                               and return 0; on a bad file set CONFIG_ERROR and return 1. <file> empty: the
#                               default path if it exists, else all defaults; a given file must exist. <home>: the
#                               gateway account's home for the defaults under "~" (default $HOME); admin commands
#                               running as root pass the account's home (config_account_home).
#   config_require [file] [home]  config_load or die with CONFIG_ERROR
#   config_unknown_keys         after config_load: one warning line per key the file has that is not a setting, with
#                               a suggestion when it looks like a typo (edit distance, as unknownConfigKeys)
#   config_account_home <name>  the home directory of an account (getent passwd), or die
#
# Variables set by config_load (all readonly; arrays are indexed arrays):
#   CFG_FILE                    the file read, empty when none (all defaults)
#   CFG_JSON                    the settings in force, compact JSON in the key order of agent-config.ts
#   CFG_ALLOWED_IMAGES[]        exact repositories that may be started
#   CFG_KEYS_DIR                empty when unset
#   CFG_LIMIT_MEMORY CFG_LIMIT_CPUS CFG_LIMIT_PIDS
#   CFG_IDLE_MINUTES            0: never stop idle containers
#   CFG_SKIP_EXTENSIONS[]       extension id prefixes not installed into containers
#   CFG_IDLE_CHECK_SECONDS      empty when unset (or 0 in the file)
#   CFG_PULL_IMAGES CFG_REQUIRE_PROVENANCE   true or false
#   CFG_IMAGE_STAGING_DIR CFG_LOCK_DIR CFG_VERIFIED_DIR CFG_TRUSTED_ROOT_FILE   absolute paths
#   CFG_MAX_PROJECTS_PER_USER   0 admits no starts
#   CFG_IMAGE_RESERVE CFG_MAX_UNPACKED_IMAGE CFG_MAX_IMAGE_STORAGE CFG_MAX_MEMORY_PER_USER CFG_RESERVE_MEMORY
#   CFG_EXTRA_HOST_NAMES[] CFG_EXTRA_HOST_IPS[]   extraHosts as two parallel arrays, in file order
#   CFG_CRAN_MIRROR CFG_PROVENANCE_REPOSITORY CFG_PROVENANCE_WORKFLOW
#
# Validation is one fixed jq program (no input ever becomes part of it). Its regexes are anchored with \A and \z,
# because jq's ^ and $ also match at a newline. Beyond agent-config.ts (docs/spec.md lists these as changed): JSON
# null is a wrong type like any other, "limits" must be an object, whole numbers stay below 2^53, path settings
# must be absolute, free-text settings may not be empty or start with "-", strings have length caps, and no value
# may contain a control character, so every value is safe on one line and as a command argument. The "docker" key of positron-remote is no longer a setting.

# shellcheck shell=bash
[[ -n "${FNKC_CONFIG_LOADED:-}" ]] && return 0
FNKC_CONFIG_LOADED=1

# shellcheck source=server/lib/core.sh
source "${FNKC_LIB:?FNKC_LIB is not set}/core.sh"

readonly CONFIG_DEFAULT_FILE=/etc/fnkc-ctl-sh/agent.json
readonly FNKC_ACCOUNT_RE='[a-z_][a-z0-9_-]{0,31}'

# The settings agent.json may have, in agent-config.ts order (CONFIG_KEYS without "docker"), and those of "limits".
readonly -a CONFIG_KEYS=(allowedImages keysDir limits idleMinutes skipExtensions idleCheckSeconds pullImages
  imageStagingDir lockDir maxProjectsPerUser imageReserve maxUnpackedImage maxImageStorage maxMemoryPerUser
  reserveMemory extraHosts cranMirror requireProvenance provenanceRepository provenanceWorkflow trustedRootFile
  verifiedDir)
readonly -a CONFIG_LIMIT_KEYS=(memory cpus pids)

CONFIG_ERROR=""

# Input: the file slurped (an array of its JSON values). Output: {"config": {...}} or {"error": "<message>"}.
# shellcheck disable=SC2016 # a jq program, not shell
readonly _CONFIG_JQ='
def fail($k; $m): error("agent config: \"\($k)\" must \($m)");
def clean: (test("[[:cntrl:]]") | not) and (startswith("-") | not);
def text($k):
  if type == "string" and length > 0 and length <= 4096 and clean then . else fail($k; "be a non-empty string") end;
def path($k):
  if type == "string" and startswith("/") and length <= 4096 and clean then . else fail($k; "be an absolute path") end;
def uint($k):
  if type == "number" and . == floor and . >= 0 and . < 9007199254740992 then floor
  else fail($k; "be a whole number, 0 or more") end;
def bool($k): if type == "boolean" then . else fail($k; "be true or false") end;
def size($k):
  if type == "string" and length <= 32 and test("\\A[0-9]+[bkmgBKMG]?\\z") and test("[1-9]") then .
  else fail($k; "be a size such as 4g, greater than 0") end;

def settings($home):
  . as $f
  | def opt($k; f; $d): if $f | has($k) then $f[$k] | f else $d end;
  ($f.limits // {}) as $l
  | if ($f | has("limits")) and ($f.limits | type) != "object" then fail("limits"; "be an object") else . end
  | def lim($k; f; $d): if $l | has($k) then $l[$k] | f else $d end;
  {
    allowedImages: opt("allowedImages";
      if type == "array" and all(.[]; type == "string") then . else fail("allowedImages"; "be a list of strings") end
      | if length > 0 and all(.[]; length <= 255 and test("\\A[a-z0-9][a-z0-9._/:-]*[a-z0-9]\\z")) then .
        else fail("allowedImages"; "contain exact approved repository names (no prefixes or empty list)") end;
      ["ghcr.io/fnkc-stats/r-env"]),
    keysDir: opt("keysDir"; path("keysDir"); null),
    limits: {
      memory: lim("memory"; size("limits.memory"); "4g"),
      cpus: lim("cpus";
        (if type == "number" then tostring else . end)
        | if type == "string" and length <= 32 and test("\\A[0-9]+(\\.[0-9]+)?\\z") and test("[1-9]") then .
          else fail("limits.cpus"; "be a number greater than 0, such as 2 or 0.5") end;
        "2"),
      pids: lim("pids";
        if type == "number" and . == floor and . > 0 and . < 9007199254740992 then floor
        else fail("limits.pids"; "be a positive integer") end;
        512)
    },
    idleMinutes: opt("idleMinutes"; uint("idleMinutes"); 0),
    skipExtensions: opt("skipExtensions";
      if type == "array" and all(.[]; type == "string" and length <= 128 and test("\\A[A-Za-z0-9._-]+\\z")) then .
      else fail("skipExtensions"; "be a list of extension ids or prefixes") end;
      ["ms-toolsai.", "ms-python.debugpy", "meta.pyrefly", "charliermarsh.ruff", "github.vscode-pull-request-github"]),
    idleCheckSeconds: (opt("idleCheckSeconds"; uint("idleCheckSeconds"); 0) | if . == 0 then null else . end),
    pullImages: opt("pullImages"; bool("pullImages"); false),
    imageStagingDir: opt("imageStagingDir"; path("imageStagingDir"); $home + "/.cache/fnkc-ctl/images"),
    lockDir: opt("lockDir"; path("lockDir"); $home + "/.cache/fnkc-ctl/locks"),
    imageReserve: opt("imageReserve"; size("imageReserve"); "2g"),
    maxUnpackedImage: opt("maxUnpackedImage"; size("maxUnpackedImage"); "64g"),
    maxImageStorage: opt("maxImageStorage"; size("maxImageStorage"); "128g"),
    maxProjectsPerUser: opt("maxProjectsPerUser"; uint("maxProjectsPerUser"); 2),
    maxMemoryPerUser: opt("maxMemoryPerUser"; size("maxMemoryPerUser"); "16g"),
    reserveMemory: opt("reserveMemory"; size("reserveMemory"); "2g"),
    extraHosts: opt("extraHosts";
      if type == "object" and all(to_entries[];
        (.key | length <= 253 and test("\\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\\z"))
        and (.value | type == "string" and length <= 45 and test("\\A[0-9A-Fa-f.:]+\\z")))
      then . else fail("extraHosts"; "map host names to IP addresses") end;
      {}),
    cranMirror: opt("cranMirror";
      if type == "string" and length <= 2048
        and test("\\Ahttps://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/\\z") then .
      else fail("cranMirror"; "be an https URL ending in \"/\", e.g. https://mirror.truenetwork.ru/CRAN/") end;
      "https://mirror.truenetwork.ru/CRAN/"),
    requireProvenance: opt("requireProvenance"; bool("requireProvenance"); $f | has("keysDir")),
    provenanceRepository: opt("provenanceRepository"; text("provenanceRepository"); "fnkc-stats/positron-remote"),
    provenanceWorkflow: opt("provenanceWorkflow"; text("provenanceWorkflow"); ".github/workflows/positron.yml"),
    trustedRootFile: opt("trustedRootFile"; path("trustedRootFile"); "/etc/fnkc-ctl-sh/trusted-root.jsonl"),
    verifiedDir: opt("verifiedDir"; path("verifiedDir"); $home + "/.cache/fnkc-ctl/verified")
  }
  | del(.keysDir | select(. == null)) | del(.idleCheckSeconds | select(. == null));

try (
  if length != 1 or (.[0] | type) != "object" then error($file + ": expected a JSON object") else .[0] end
  | {config: settings($home)}
) catch {error: (if type == "string" then . else "agent config: invalid" end)}
'

# The values of the checked settings, one per line (none contains a newline); arrays as their length, then items.
readonly _CONFIG_LINES_JQ='
(.allowedImages | length, .[]), (.keysDir // ""), .limits.memory, .limits.cpus, (.limits.pids | tostring),
(.idleMinutes | tostring), (.skipExtensions | length, .[]), (.idleCheckSeconds // "" | tostring),
(.pullImages | tostring), .imageStagingDir, .lockDir, (.maxProjectsPerUser | tostring), .imageReserve,
.maxUnpackedImage, .maxImageStorage, .maxMemoryPerUser, .reserveMemory,
(.extraHosts | length, (to_entries[] | .key, .value)), .cranMirror, (.requireProvenance | tostring),
.provenanceRepository, .provenanceWorkflow, .trustedRootFile, .verifiedDir
'

# _config_fail <message>: set CONFIG_ERROR and return 1.
_config_fail() {
  CONFIG_ERROR="$1"
  return 1
}

# shellcheck disable=SC2034 # the CFG_* variables are for the scripts that source this file
config_load() {
  local file="${1-}" home="${2-${HOME-}}" out json
  [[ -z "${CFG_JSON+x}" ]] || return 0
  CONFIG_ERROR=""
  is_match '/.*' "$home" 4096 || _config_fail "agent config: the account's home directory is not an absolute path" ||
    return 1
  home="${home%/}"
  if [[ -n "$file" ]]; then
    is_match '.+' "$file" 4096 || _config_fail "agent config: invalid file name" || return 1
    [[ -f "$file" && -r "$file" ]] || _config_fail "cannot read $file" || return 1
  elif [[ -e "$CONFIG_DEFAULT_FILE" ]]; then
    file="$CONFIG_DEFAULT_FILE"
    [[ -f "$file" && -r "$file" ]] || _config_fail "cannot read $file" || return 1
  fi
  if [[ -n "$file" ]]; then
    out="$(jq -c --slurp --arg home "$home" --arg file "$file" "$_CONFIG_JQ" <"$file" 2>/dev/null)" ||
      _config_fail "$file: not valid JSON" || return 1
  else
    out="$(jq -c --slurp --arg home "$home" --arg file "" "$_CONFIG_JQ" <<<'{}')" ||
      _config_fail "agent config: jq failed" || return 1
  fi
  if ! json="$(jq -c '.config // empty' <<<"$out")" || [[ -z "$json" ]]; then
    _config_fail "$(jq -r '.error // "agent config: invalid"' <<<"$out")" || return 1
  fi

  local -a v
  mapfile -t v < <(jq -r "$_CONFIG_LINES_JQ" <<<"$json") || _config_fail "agent config: jq failed" || return 1
  local -i i=0 n
  local -a allowed=() skip=() host_names=() host_ips=()
  n="${v[i++]}"
  while ((n-- > 0)); do allowed+=("${v[i++]}"); done
  declare -gr CFG_KEYS_DIR="${v[i++]}" CFG_LIMIT_MEMORY="${v[i++]}" CFG_LIMIT_CPUS="${v[i++]}" \
    CFG_LIMIT_PIDS="${v[i++]}" CFG_IDLE_MINUTES="${v[i++]}"
  n="${v[i++]}"
  while ((n-- > 0)); do skip+=("${v[i++]}"); done
  declare -gr CFG_IDLE_CHECK_SECONDS="${v[i++]}" CFG_PULL_IMAGES="${v[i++]}" CFG_IMAGE_STAGING_DIR="${v[i++]}" \
    CFG_LOCK_DIR="${v[i++]}" CFG_MAX_PROJECTS_PER_USER="${v[i++]}" CFG_IMAGE_RESERVE="${v[i++]}" \
    CFG_MAX_UNPACKED_IMAGE="${v[i++]}" CFG_MAX_IMAGE_STORAGE="${v[i++]}" CFG_MAX_MEMORY_PER_USER="${v[i++]}" \
    CFG_RESERVE_MEMORY="${v[i++]}"
  n="${v[i++]}"
  while ((n-- > 0)); do
    host_names+=("${v[i++]}")
    host_ips+=("${v[i++]}")
  done
  declare -gr CFG_CRAN_MIRROR="${v[i++]}" CFG_REQUIRE_PROVENANCE="${v[i++]}" \
    CFG_PROVENANCE_REPOSITORY="${v[i++]}" CFG_PROVENANCE_WORKFLOW="${v[i++]}" CFG_TRUSTED_ROOT_FILE="${v[i++]}" \
    CFG_VERIFIED_DIR="${v[i++]}"
  ((i == ${#v[@]})) || die "config.sh: settings list out of step"
  declare -gra CFG_ALLOWED_IMAGES=("${allowed[@]}") CFG_SKIP_EXTENSIONS=("${skip[@]}")
  declare -gra CFG_EXTRA_HOST_NAMES=("${host_names[@]}") CFG_EXTRA_HOST_IPS=("${host_ips[@]}")
  declare -gr CFG_FILE="$file" CFG_JSON="$json"
}

config_require() {
  config_load "$@" || die "$CONFIG_ERROR"
}

# _config_distance <a> <b>: Levenshtein distance, case-insensitive.
_config_distance() {
  local a="${1,,}" b="${2,,}"
  local -i i j la=${#a} lb=${#b} del ins sub
  local -a row next
  for ((j = 0; j <= lb; j++)); do row[j]=$j; done
  for ((i = 1; i <= la; i++)); do
    next=("$i")
    for ((j = 1; j <= lb; j++)); do
      del=$((row[j] + 1)) ins=$((next[j - 1] + 1)) sub=$((row[j - 1] + 1))
      [[ "${a:i-1:1}" != "${b:j-1:1}" ]] || sub=$((row[j - 1]))
      ((ins < del)) && del=$ins
      ((sub < del)) && del=$sub
      next[j]=$del
    done
    row=("${next[@]}")
  done
  printf '%s\n' "${row[lb]}"
}

# _config_suggest <key> <known...>: the first known key nearest to <key>, if near enough
# (max(2, floor(length/4)), as unknownConfigKeys); nothing otherwise.
_config_suggest() {
  local key="$1" best="" c
  local -i d min=-1 limit=$((${#1} / 4))
  shift
  ((limit >= 2)) || limit=2
  ((${#key} <= 64)) || return 0
  for c in "$@"; do
    d="$(_config_distance "$key" "$c")"
    if ((min < 0 || d < min)); then min=$d best=$c; fi
  done
  ((min >= 0 && min <= limit)) && printf '%s\n' "$best"
  return 0
}

config_unknown_keys() {
  [[ -n "${CFG_FILE-}" ]] || return 0
  local line prefix key suggestion msg
  local -a known
  # one line per unknown key: <prefix> TAB <key as JSON, without the quotes> (no raw control characters)
  while IFS= read -r line; do
    prefix="${line%%$'\t'*}" key="${line#*$'\t'}"
    if [[ "$prefix" == limits. ]]; then known=("${CONFIG_LIMIT_KEYS[@]}"); else known=("${CONFIG_KEYS[@]}"); fi
    suggestion="$(_config_suggest "$key" "${known[@]}")"
    msg="\"$prefix$key\" is not a setting and is ignored"
    [[ -z "$suggestion" ]] || msg+=" (did you mean \"$prefix$suggestion\"?)"
    printf '%s\n' "$msg"
  done < <(jq -r --argjson n "${#CONFIG_KEYS[@]}" --args '
    def unknown($known):
      keys_unsorted[] | select(. as $k | any($known[]; . == $k) | not) | tojson | .[1:-1] | gsub("[[:cntrl:]]"; "?");
    ("\t" + unknown($ARGS.positional[:$n])),
    (if (.limits | type) == "object" then .limits | "limits.\t" + unknown($ARGS.positional[$n:]) else empty end)
  ' "${CONFIG_KEYS[@]}" "${CONFIG_LIMIT_KEYS[@]}" <"$CFG_FILE")
  return 0
}

config_account_home() {
  local account="${1-}" entry home
  require_match "account name" "$FNKC_ACCOUNT_RE" "$account" 32
  entry="$(getent passwd -- "$account")" || die "no such account: $account"
  IFS=: read -r _ _ _ _ _ home _ <<<"$entry"
  is_match '/.*' "$home" 4096 || die "account $account has no absolute home directory"
  printf '%s\n' "$home"
}
