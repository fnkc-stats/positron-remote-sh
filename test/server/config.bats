#!/usr/bin/env bats
# server/lib/config.sh and server/admin/check-config.sh: agent.json keys, defaults, validation, unknown keys.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  setup_fakes getent
  export FNKC_LOG=stderr
  CONF="$BATS_TEST_TMPDIR/agent.json"
  fake_reply -o 'fnkcsh:x:999:999::/home/fnkcsh:/usr/sbin/nologin' -- getent passwd -- fnkcsh
}

# load_conf <json> [home]: write <json> to $CONF and run config_load on it; prints CONFIG_ERROR on failure.
load_conf() {
  printf '%s\n' "$1" >"$CONF"
  bash -c 'source "$FNKC_LIB/config.sh"; config_load "$1" "$2" || { printf "%s\n" "$CONFIG_ERROR"; exit 1; }
    shift 2; for v in "$@"; do declare -p "$v"; done' load "$CONF" "${2:-/home/fnkcsh}" "${@:3}"
}

# refused <json> <message>: config_load fails with exactly that message.
refused() {
  run load_conf "$1"
  assert_status 1
  [ "$output" = "$2" ] || {
    printf 'expected: %s\ngot: %s\n' "$2" "$output" >&2
    return 1
  }
}

check_config() {
  bash "$REPO_ROOT/server/admin/check-config.sh" "$@"
}

@test "an empty object gives every default, under the account's home" {
  run load_conf '{}'
  assert_status 0
  run bash -c 'source "$FNKC_LIB/config.sh"; config_load "$1" /home/fnkcsh/; printf "%s\n" "$CFG_JSON"' x "$CONF"
  assert_status 0
  expected='{"allowedImages":["ghcr.io/fnkc-stats/r-env"],"limits":{"memory":"4g","cpus":"2","pids":512},'
  expected+='"idleMinutes":0,"skipExtensions":["ms-toolsai.","ms-python.debugpy","meta.pyrefly","charliermarsh.ruff",'
  expected+='"github.vscode-pull-request-github"],"pullImages":false,'
  expected+='"imageStagingDir":"/home/fnkcsh/.cache/fnkc-ctl/images","lockDir":"/home/fnkcsh/.cache/fnkc-ctl/locks",'
  expected+='"imageReserve":"2g","maxUnpackedImage":"64g","maxImageStorage":"128g","maxProjectsPerUser":2,'
  expected+='"maxMemoryPerUser":"16g","reserveMemory":"2g","extraHosts":{},'
  expected+='"cranMirror":"https://mirror.truenetwork.ru/CRAN/","requireProvenance":false,'
  expected+='"provenanceRepository":"fnkc-stats/positron-remote","provenanceWorkflow":".github/workflows/positron.yml",'
  expected+='"trustedRootFile":"/etc/fnkc-ctl-sh/trusted-root.jsonl","verifiedDir":"/home/fnkcsh/.cache/fnkc-ctl/verified"}'
  [ "$output" = "$expected" ]
}

@test "defaults land in readonly variables and arrays" {
  run load_conf '{}' /home/fnkcsh CFG_ALLOWED_IMAGES CFG_KEYS_DIR CFG_LIMIT_PIDS CFG_IDLE_CHECK_SECONDS \
    CFG_PULL_IMAGES CFG_REQUIRE_PROVENANCE CFG_SKIP_EXTENSIONS CFG_EXTRA_HOST_NAMES CFG_LOCK_DIR
  assert_status 0
  assert_output_contains 'declare -ar CFG_ALLOWED_IMAGES=([0]="ghcr.io/fnkc-stats/r-env")'
  assert_output_contains 'declare -r CFG_KEYS_DIR=""'
  assert_output_contains 'declare -r CFG_LIMIT_PIDS="512"'
  assert_output_contains 'declare -r CFG_IDLE_CHECK_SECONDS=""'
  assert_output_contains 'declare -r CFG_PULL_IMAGES="false"'
  assert_output_contains 'declare -r CFG_REQUIRE_PROVENANCE="false"'
  assert_output_contains '[4]="github.vscode-pull-request-github")'
  assert_output_contains 'declare -ar CFG_EXTRA_HOST_NAMES=()'
  assert_output_contains 'declare -r CFG_LOCK_DIR="/home/fnkcsh/.cache/fnkc-ctl/locks"'
  # readonly: a later script cannot change a setting
  run bash -c 'source "$FNKC_LIB/config.sh"; config_load "$1" /h; CFG_LOCK_DIR=/tmp' x "$CONF"
  [ "$status" -ne 0 ]
}

@test "every key is read" {
  run load_conf '{"allowedImages":["ghcr.io/a/b","registry.example:5000/c"],"keysDir":"/etc/fnkc-ctl-sh/keys",
    "limits":{"memory":"8G","cpus":1.5,"pids":100},"idleMinutes":30,"skipExtensions":[],"idleCheckSeconds":5,
    "pullImages":true,"imageStagingDir":"/srv/stage","lockDir":"/run/locks","maxProjectsPerUser":0,
    "imageReserve":"1g","maxUnpackedImage":"10g","maxImageStorage":"20g","maxMemoryPerUser":"3g","reserveMemory":"512m",
    "extraHosts":{"git.example.org":"10.0.0.5","v6.example":"fd00::1"},"cranMirror":"https://cran.example.org:8443/cran/",
    "requireProvenance":false,"provenanceRepository":"o/r","provenanceWorkflow":"w.yml",
    "trustedRootFile":"/etc/x.jsonl","verifiedDir":"/srv/verified"}' /h \
    CFG_ALLOWED_IMAGES CFG_KEYS_DIR CFG_LIMIT_MEMORY CFG_LIMIT_CPUS CFG_LIMIT_PIDS CFG_IDLE_MINUTES CFG_SKIP_EXTENSIONS \
    CFG_IDLE_CHECK_SECONDS CFG_PULL_IMAGES CFG_IMAGE_STAGING_DIR CFG_LOCK_DIR CFG_MAX_PROJECTS_PER_USER \
    CFG_IMAGE_RESERVE CFG_MAX_UNPACKED_IMAGE CFG_MAX_IMAGE_STORAGE CFG_MAX_MEMORY_PER_USER CFG_RESERVE_MEMORY \
    CFG_EXTRA_HOST_NAMES CFG_EXTRA_HOST_IPS CFG_CRAN_MIRROR CFG_REQUIRE_PROVENANCE CFG_PROVENANCE_REPOSITORY \
    CFG_PROVENANCE_WORKFLOW CFG_TRUSTED_ROOT_FILE CFG_VERIFIED_DIR
  assert_status 0
  local want
  for want in 'CFG_ALLOWED_IMAGES=([0]="ghcr.io/a/b" [1]="registry.example:5000/c")' \
    'CFG_KEYS_DIR="/etc/fnkc-ctl-sh/keys"' 'CFG_LIMIT_MEMORY="8G"' 'CFG_LIMIT_CPUS="1.5"' 'CFG_LIMIT_PIDS="100"' \
    'CFG_IDLE_MINUTES="30"' 'CFG_SKIP_EXTENSIONS=()' 'CFG_IDLE_CHECK_SECONDS="5"' 'CFG_PULL_IMAGES="true"' \
    'CFG_IMAGE_STAGING_DIR="/srv/stage"' 'CFG_LOCK_DIR="/run/locks"' 'CFG_MAX_PROJECTS_PER_USER="0"' \
    'CFG_IMAGE_RESERVE="1g"' 'CFG_MAX_UNPACKED_IMAGE="10g"' 'CFG_MAX_IMAGE_STORAGE="20g"' \
    'CFG_MAX_MEMORY_PER_USER="3g"' 'CFG_RESERVE_MEMORY="512m"' \
    'CFG_EXTRA_HOST_NAMES=([0]="git.example.org" [1]="v6.example")' \
    'CFG_EXTRA_HOST_IPS=([0]="10.0.0.5" [1]="fd00::1")' 'CFG_CRAN_MIRROR="https://cran.example.org:8443/cran/"' \
    'CFG_REQUIRE_PROVENANCE="false"' 'CFG_PROVENANCE_REPOSITORY="o/r"' 'CFG_PROVENANCE_WORKFLOW="w.yml"' \
    'CFG_TRUSTED_ROOT_FILE="/etc/x.jsonl"' 'CFG_VERIFIED_DIR="/srv/verified"'; do
    assert_output_contains "$want"
  done
}

@test "requireProvenance defaults to true when keysDir is set; cpus as a string; idleCheckSeconds 0 is unset" {
  run load_conf '{"keysDir":"/k","limits":{"cpus":"0.5"},"idleCheckSeconds":0}' /h \
    CFG_REQUIRE_PROVENANCE CFG_LIMIT_CPUS CFG_IDLE_CHECK_SECONDS
  assert_status 0
  assert_output_contains 'CFG_REQUIRE_PROVENANCE="true"'
  assert_output_contains 'CFG_LIMIT_CPUS="0.5"'
  assert_output_contains 'CFG_IDLE_CHECK_SECONDS=""'
}

@test "whole numbers written as 2.0 are whole" {
  run load_conf '{"idleMinutes":2.0,"limits":{"pids":64.0}}' /h CFG_IDLE_MINUTES CFG_LIMIT_PIDS
  assert_status 0
  assert_output_contains 'CFG_IDLE_MINUTES="2"'
  assert_output_contains 'CFG_LIMIT_PIDS="64"'
}

@test "the file must be one JSON object" {
  refused '[]' "$CONF: expected a JSON object"
  refused '"x"' "$CONF: expected a JSON object"
  refused '{} {}' "$CONF: expected a JSON object"
  refused '' "$CONF: expected a JSON object"
  refused '{"a":' "$CONF: not valid JSON"
  run bash -c 'source "$FNKC_LIB/config.sh"; config_require "$1" /h' x "$BATS_TEST_TMPDIR/missing.json"
  assert_status 1
  assert_output_contains "cannot read $BATS_TEST_TMPDIR/missing.json"
}

@test "no file at the default path gives the defaults" {
  [ ! -e /etc/fnkc-ctl-sh/agent.json ] || skip "this machine has /etc/fnkc-ctl-sh/agent.json"
  run bash -c 'source "$FNKC_LIB/config.sh"; config_load "" /h && printf "%s|%s\n" "$CFG_FILE" "$CFG_LOCK_DIR"'
  assert_status 0
  [ "$output" = "|/h/.cache/fnkc-ctl/locks" ]
}

@test "allowedImages: list of exact repositories" {
  local exact='agent config: "allowedImages" must contain exact approved repository names (no prefixes or empty list)'
  refused '{"allowedImages":"ghcr.io/a/b"}' 'agent config: "allowedImages" must be a list of strings'
  refused '{"allowedImages":[1]}' 'agent config: "allowedImages" must be a list of strings'
  refused '{"allowedImages":null}' 'agent config: "allowedImages" must be a list of strings'
  refused '{"allowedImages":[]}' "$exact"
  refused '{"allowedImages":["ghcr.io/fnkc-stats/"]}' "$exact"
  refused '{"allowedImages":["GHCR.io/a"]}' "$exact"
  refused '{"allowedImages":["ghcr.io/a\nb"]}' "$exact"
  refused '{"allowedImages":["ghcr.io/a/b\n"]}' "$exact"
  refused '{"allowedImages":["-x/y"]}' "$exact"
}

@test "limits: sizes, cpus, pids" {
  refused '{"limits":5}' 'agent config: "limits" must be an object'
  refused '{"limits":null}' 'agent config: "limits" must be an object'
  local mem='agent config: "limits.memory" must be a size such as 4g, greater than 0'
  refused '{"limits":{"memory":4}}' "$mem"
  refused '{"limits":{"memory":"0g"}}' "$mem"
  refused '{"limits":{"memory":"4gb"}}' "$mem"
  refused '{"limits":{"memory":"4g\n"}}' "$mem"
  refused '{"limits":{"memory":"4g --privileged"}}' "$mem"
  local cpus='agent config: "limits.cpus" must be a number greater than 0, such as 2 or 0.5'
  refused '{"limits":{"cpus":0}}' "$cpus"
  refused '{"limits":{"cpus":"0.0"}}' "$cpus"
  refused '{"limits":{"cpus":-1}}' "$cpus"
  refused '{"limits":{"cpus":"1e3"}}' "$cpus"
  refused '{"limits":{"cpus":true}}' "$cpus"
  local pids='agent config: "limits.pids" must be a positive integer'
  refused '{"limits":{"pids":0}}' "$pids"
  refused '{"limits":{"pids":1.5}}' "$pids"
  refused '{"limits":{"pids":"512"}}' "$pids"
  refused '{"limits":{"pids":1e300}}' "$pids"
}

@test "whole numbers, booleans and sizes" {
  local k
  for k in idleMinutes idleCheckSeconds maxProjectsPerUser; do
    refused "{\"$k\":-1}" "agent config: \"$k\" must be a whole number, 0 or more"
    refused "{\"$k\":\"3\"}" "agent config: \"$k\" must be a whole number, 0 or more"
    refused "{\"$k\":0.5}" "agent config: \"$k\" must be a whole number, 0 or more"
    refused "{\"$k\":null}" "agent config: \"$k\" must be a whole number, 0 or more"
  done
  for k in pullImages requireProvenance; do
    refused "{\"$k\":\"true\"}" "agent config: \"$k\" must be true or false"
    refused "{\"$k\":1}" "agent config: \"$k\" must be true or false"
  done
  for k in imageReserve maxUnpackedImage maxImageStorage maxMemoryPerUser reserveMemory; do
    refused "{\"$k\":\"0\"}" "agent config: \"$k\" must be a size such as 4g, greater than 0"
    refused "{\"$k\":2}" "agent config: \"$k\" must be a size such as 4g, greater than 0"
  done
}

@test "paths must be absolute and free text must be clean" {
  local k
  for k in keysDir imageStagingDir lockDir trustedRootFile verifiedDir; do
    refused "{\"$k\":\"relative/dir\"}" "agent config: \"$k\" must be an absolute path"
    refused "{\"$k\":\"\"}" "agent config: \"$k\" must be an absolute path"
    refused "{\"$k\":\"/a\\nb\"}" "agent config: \"$k\" must be an absolute path"
    refused "{\"$k\":[\"/a\"]}" "agent config: \"$k\" must be an absolute path"
  done
  for k in provenanceRepository provenanceWorkflow; do
    refused "{\"$k\":\"\"}" "agent config: \"$k\" must be a non-empty string"
    refused "{\"$k\":\"--x\"}" "agent config: \"$k\" must be a non-empty string"
    refused "{\"$k\":\"a\\u001bb\"}" "agent config: \"$k\" must be a non-empty string"
    refused "{\"$k\":7}" "agent config: \"$k\" must be a non-empty string"
  done
}

@test "skipExtensions, extraHosts and cranMirror" {
  local skip='agent config: "skipExtensions" must be a list of extension ids or prefixes'
  refused '{"skipExtensions":"ms-python."}' "$skip"
  refused '{"skipExtensions":["a b"]}' "$skip"
  refused '{"skipExtensions":["a\n"]}' "$skip"
  local hosts='agent config: "extraHosts" must map host names to IP addresses'
  refused '{"extraHosts":[]}' "$hosts"
  refused '{"extraHosts":{"-bad.example":"10.0.0.1"}}' "$hosts"
  refused '{"extraHosts":{"a.example":"10.0.0.1 --privileged"}}' "$hosts"
  refused '{"extraHosts":{"a.example":"10.0.0.1\n"}}' "$hosts"
  refused '{"extraHosts":{"a.example\n":"10.0.0.1"}}' "$hosts"
  refused '{"extraHosts":{"a.example":1}}' "$hosts"
  local cran='agent config: "cranMirror" must be an https URL ending in "/", e.g. https://mirror.truenetwork.ru/CRAN/'
  refused '{"cranMirror":"http://cran.example.org/"}' "$cran"
  refused '{"cranMirror":"https://cran.example.org"}' "$cran"
  refused '{"cranMirror":"https://cran.example.org/\n"}' "$cran"
  refused "{\"cranMirror\":\"https://cran.example.org/a'b/\"}" "$cran"
  refused '{"cranMirror":"https://cran.example.org/$(id)/"}' "$cran"
}

@test "unknown keys are ignored by config_load" {
  run load_conf '{"idleMinute":5,"docker":["wsl","docker"],"limits":{"memroy":"1g"}}' /h CFG_IDLE_MINUTES CFG_LIMIT_MEMORY
  assert_status 0
  assert_output_contains 'CFG_IDLE_MINUTES="0"'
  assert_output_contains 'CFG_LIMIT_MEMORY="4g"'
}

@test "check-config prints the settings in force and warns about unknown keys" {
  printf '%s\n' '{"idleMinute":5,"docker":"docker","limits":{"memroy":"1g","pids":9},"maxProjectsPerUser":1,
    "x\u001b[2Jy":1,"c1\u009b\u007f":1}' >"$CONF"
  run --separate-stderr check_config "$CONF"
  assert_status 0
  [ "$(jq -r '.limits.pids, .maxProjectsPerUser, .idleMinutes, .lockDir' <<<"$output")" = \
    "$(printf '9\n1\n0\n/home/fnkcsh/.cache/fnkc-ctl/locks')" ]
  [ "$(jq -r 'has("docker")' <<<"$output")" = false ]
  # pretty-printed, as JSON.stringify(effective, null, 2)
  [ "$(head -2 <<<"$output")" = "$(printf '{\n  "allowedImages": [')" ]
  # shellcheck disable=SC2154 # set by bats run --separate-stderr
  local err="$stderr"
  [[ "$err" == *'fnkc-ctl: warning: "idleMinute" is not a setting and is ignored (did you mean "idleMinutes"?)'* ]]
  [[ "$err" == *'fnkc-ctl: warning: "docker" is not a setting and is ignored'$'\n'* ]]
  [[ "$err" == *'"limits.memroy" is not a setting and is ignored (did you mean "limits.memory"?)'* ]]
  # a hostile key is shown escaped, never as raw control characters
  [[ "$err" == *'"x\u001b[2Jy" is not a setting and is ignored'* ]]
  [[ "$err" != *$'\e'* && "$err" != *$'\u009b'* && "$err" != *$'\x7f'* ]]
  [[ "$err" == *'"c1'*'" is not a setting'* ]]
  assert_called getent passwd -- fnkcsh
}

@test "check-config: file from --agent-config, positional wins, home from --account" {
  printf '%s\n' '{"idleMinutes":7}' >"$CONF"
  printf '%s\n' '{"idleMinutes":8}' >"$BATS_TEST_TMPDIR/other.json"
  fake_reply -o 'svc:x:5:5::/srv/svc:/bin/false' -- getent passwd -- svc
  run --separate-stderr check_config --account svc --agent-config "$CONF"
  assert_status 0
  [ "$(jq -r '.idleMinutes, .verifiedDir' <<<"$output")" = "$(printf '7\n/srv/svc/.cache/fnkc-ctl/verified')" ]
  run --separate-stderr check_config --agent-config "$CONF" -- "$BATS_TEST_TMPDIR/other.json"
  assert_status 0
  [ "$(jq -r .idleMinutes <<<"$output")" = 8 ]
}

@test "check-config refuses bad arguments, bad files and unknown accounts" {
  printf '%s\n' '{"idleMinutes":-1}' >"$CONF"
  run check_config "$CONF"
  assert_status 1
  assert_output_contains 'fnkc-ctl: agent config: "idleMinutes" must be a whole number, 0 or more'
  run check_config a.json b.json
  assert_status 1
  assert_output_contains 'usage: fnkc-ctl admin check-config'
  run check_config --bogus
  assert_status 1
  assert_output_contains 'usage:'
  run check_config --account
  assert_status 1
  assert_output_contains 'usage:'
  run check_config ''
  assert_status 1
  assert_output_contains 'usage:'
  : >"$FAKE_DIR/calls.log"
  run check_config --account 'root;id' "$CONF"
  assert_status 1
  assert_output_contains 'invalid account name'
  refute_called getent
  fake_reply -s 2 -- getent passwd -- nobody2
  printf '%s\n' '{}' >"$CONF"
  run check_config --account nobody2 "$CONF"
  assert_status 1
  assert_output_contains 'no such account: nobody2'
}

@test "sourcing config.sh leaves serve's FNKC_AGENT_CONFIG alone" {
  printf '%s\n' '{"idleMinutes":4}' >"$CONF"
  run env FNKC_AGENT_CONFIG="$CONF" bash -c 'source "$FNKC_LIB/config.sh"; config_load "$FNKC_AGENT_CONFIG" /h
    echo "$FNKC_AGENT_CONFIG $CFG_IDLE_MINUTES"'
  assert_status 0
  [ "$output" = "$CONF 4" ]
}

@test "config_load runs once per process; a home that is not absolute is refused" {
  printf '%s\n' '{"idleMinutes":3}' >"$CONF"
  run bash -c 'source "$FNKC_LIB/config.sh"; config_load "$1" /h; config_load /nonexistent /h; echo "$CFG_IDLE_MINUTES"' \
    x "$CONF"
  assert_status 0
  [ "$output" = 3 ]
  run bash -c 'source "$FNKC_LIB/config.sh"; config_require "$1" relative' x "$CONF"
  assert_status 1
  assert_output_contains 'not an absolute path'
}
