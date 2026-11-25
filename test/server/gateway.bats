#!/usr/bin/env bats
# server/fnkc-ctl serve: environment, command parsing, grammar, key recheck, stdin cap, dispatch, envelope, journal.

bats_require_minimum_version 1.5.0

setup() {
  load '../helpers/common'
  load '../helpers/gateway'
  setup_gateway
  # A request that would reach Docker: every refusal below must come before it.
  stub_request busy 'docker ps >/dev/null; jq -n --args "\$ARGS.positional" -- "$@"'
  stub_request stop 'jq -n --args "\$ARGS.positional" -- "$@"'
}

ISO='^"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z"$'

@test "ping: PingResult in the ok envelope, exit 0, one journal line" {
  run --separate-stderr gateway 'agent ping'
  assert_status 0
  [[ "$(reply_field 'keys_unsorted')" == '["ok","result"]' ]]
  [[ "$(reply_field '.result | del(.trustRootRefreshed)')" == '{"version":"0.1.0-dev","protocol":1,"minProtocol":1,"capabilities":[],"user":"alice","requiresProvenance":true}' ]]
  [[ "$(reply_field .result.trustRootRefreshed)" =~ $ISO ]]
  [[ "$(journal_lines)" =~ ^fnkc-ctl-sh\ user.info\ user=alice\ from=203.0.113.5\ command=ping\ ms=[0-9]+\ result=ok\ ctl=0.1.0-dev$ ]]
  refute_called docker
}

@test "ping: requireProvenance false leaves out trustRootRefreshed" {
  jq '.requireProvenance = false' "$GW_CONFIG" >"$GW_CONFIG.new" && mv "$GW_CONFIG.new" "$GW_CONFIG"
  run --separate-stderr gateway 'fnkc-ctl   agent	ping  '
  assert_status 0
  [[ "$(reply_field .result.requiresProvenance)" == false ]]
  [[ "$(reply_field '.result | has("trustRootRefreshed")')" == false ]]
}

@test "ping: capabilities are collected from the request files' declarations" {
  printf '# fnkc-capabilities: qualified-stop-v1\n' >>"$GW/requests/stop.sh"
  printf '# fnkc-capabilities: long-running-v1 checkout-query-v1\n' >>"$GW/requests/busy.sh"
  run --separate-stderr gateway 'agent ping'
  assert_status 0
  [[ "$(reply_field .result.capabilities)" == '["checkout-query-v1","long-running-v1","qualified-stop-v1"]' ]]
}

@test "not an agent command: Error on stderr, exit 1, no reply, journalled" {
  local cmd
  for cmd in '' 'ls -la' 'agentping' 'fnkc-ctl fnkc-ctl agent ping' 'sh -c id' "$(printf 'x%.0s' {1..5000})"; do
    run --separate-stderr gateway "$cmd"
    assert_status 1
    [[ -z "$output" && "$stderr" == "Error: unsupported command: "* ]]
  done
  [[ "$(journal_lines | grep -c 'user.warning user=alice from=203.0.113.5 ms=[0-9]* result=error error="unsupported command')" -eq 6 ]]
  refute_called docker
}

@test "unknown request word, or a request without its file: code unknown-command" {
  for cmd in 'agent' 'agent frobnicate' 'agent list' 'agent PING' 'agent ../ping' 'agent request'; do
    run --separate-stderr gateway "$cmd"
    assert_status 1
    [[ "$(reply_field '[.ok, .code]')" == '[false,"unknown-command"]' ]]
    [[ "$(reply_field .error)" == '"unknown agent command: '* ]]
  done
  journal_lines | grep -q 'command=frobnicate .*result=error code=unknown-command'
}

@test "wrong word counts: src/serve.ts messages without a code" {
  stub_request remove 'echo "{}"'
  stub_request install-image 'echo "{}"'
  local -A want=(
    ['agent ping x']='too many arguments'
    ['agent stop']='stop: project name required'
    ['agent busy']='busy: project name required'
    ['agent busy a b']='too many arguments'
    ['agent stop a ssh://h/r b']='too many arguments'
    ['agent remove a']='remove: expected <project> <fingerprint from remove-check>'
    ['agent remove a 1234']='remove: expected <project> <fingerprint from remove-check>'
    ['agent install-image']='install-image: expected <image>'
  )
  local cmd
  for cmd in "${!want[@]}"; do
    run --separate-stderr gateway "$cmd"
    assert_status 1
    [[ "$output" == "$(jq -cn --arg e "${want[$cmd]}" '{ok: false, error: $e}')" ]] || {
      echo "$cmd: $output" >&2
      return 1
    }
  done
  refute_called docker
}

@test "hostile values are refused before any docker call" {
  local -a bad=(
    'a;id' '$(id)' '`id`' 'a|b' 'a&b' '>x' '-rf' '--help' '-' '.' '..' '../x' 'a/../b' '/etc' 'a\b' "a'b" 'a"b'
    'a*' 'a?' '[a]' '~root' '$HOME' "$(printf 'a%.0s' {1..64})" "$(printf 'a%.0s' {1..2000})"
    $'\xd0\xb0lice' $'\xef\xbd\x81bc' $'a\xc2\xa0b' $'a\x01b' $'a\x1b[2Jb'
  )
  local v
  for v in "${bad[@]}"; do
    run --separate-stderr gateway "agent busy $v"
    assert_status 1
    [[ "$(reply_field .ok)" == false && "$(reply_field 'has("code")')" == false ]] || {
      echo "accepted: $v -> $output" >&2
      return 1
    }
  done
  run --separate-stderr gateway $'agent busy a\nb'
  [[ "$(reply_field .error)" == '"too many arguments"' ]]
  refute_called docker
}

@test "repository: URL rules, no .. segment, trailing / removed" {
  local r
  for r in 'file:///etc/passwd' 'ext::sh' 'https://u:p@h/r' 'http://h/r' 'ssh://h/a/../b' 'https://h/..' '-uhttps://h/r' \
    'git@h:r;id'; do
    run --separate-stderr gateway "agent stop p $r"
    assert_status 1
    [[ "$(reply_field .error)" == '"repository '* ]] || {
      echo "accepted: $r -> $output" >&2
      return 1
    }
  done
  run --separate-stderr gateway 'agent stop p https://gitea.example/org/p.git//'
  assert_status 0
  [[ "$output" == '{"ok":true,"result":["p","https://gitea.example/org/p.git"]}' ]]
}

@test "image and fingerprint values" {
  stub_request install-image 'jq -n --arg i "$1" "\$i"'
  run --separate-stderr gateway 'agent install-image ghcr.io/x/env:1.0'
  assert_status 1
  [[ "$(reply_field .error)" == '"image must be pinned as repository@sha256:<64 lowercase hex digits>: ghcr.io/x/env:1.0"' ]]
  local d
  d="$(printf 'a%.0s' {1..64})"
  run --separate-stderr gateway "agent install-image ghcr.io/x/env@sha256:$d"
  assert_status 0
  [[ "$(reply_field .result)" == "\"ghcr.io/x/env@sha256:$d\"" ]]
  journal_lines | grep -q "command=install-image image=ghcr.io/x/env@sha256:$d"
}

@test "the user's key is rechecked on every request" {
  rm -- "$GW_KEYS/alice.pub"
  run --separate-stderr gateway 'agent ping'
  assert_status 1
  [[ "$output" == '{"ok":false,"error":"no SSH key for user '\''alice'\'' on this host"}' ]]
  printf 'command="id" ssh-ed25519 AAAA\n' >"$GW_KEYS/alice.pub"
  run --separate-stderr gateway 'agent busy p'
  assert_status 1
  [[ "$(reply_field .error)" == '"not an SSH public key'* ]]
  refute_called docker
}

@test "serve arguments and config: Error on stderr, no reply" {
  run --separate-stderr env -i SSH_ORIGINAL_COMMAND='agent ping' "$GW/fnkc-ctl" serve --agent-config "$GW_CONFIG"
  [[ "$status" -eq 1 && -z "$output" && "$stderr" == 'Error: serve: --user is required' ]]
  local u
  for u in Alice a-b 1a 'a b' "$(printf 'a%.0s' {1..33})"; do
    run --separate-stderr env -i SSH_ORIGINAL_COMMAND='agent ping' "$GW/fnkc-ctl" serve --user "$u" \
      --agent-config "$GW_CONFIG" --path "$GW_PATH"
    [[ "$status" -eq 1 && -z "$output" && "$stderr" == "Error: invalid user name: "* ]]
  done
  echo '{}' >"$GW_CONFIG"
  run --separate-stderr gateway 'agent ping'
  [[ "$status" -eq 1 && -z "$output" && "$stderr" == 'Error: server mode requires keysDir' ]]
  echo '{"keysDir": 1}' >"$GW_CONFIG"
  run --separate-stderr gateway 'agent ping'
  [[ "$status" -eq 1 && "$stderr" == 'Error: agent config: "keysDir" must be a string' ]]
  run --separate-stderr gateway 'agent ping' --path 'relative:/bin'
  [[ "$status" -eq 1 && "$stderr" == 'Error: serve: --path must be'* ]]
}

@test "environment: nothing from the caller reaches serve or its requests" {
  local marker="$BATS_TEST_TMPDIR/marker"
  printf 'touch %q\n' "$marker" >"$BATS_TEST_TMPDIR/evil.sh"
  stub_request list 'env | cut -d= -f1 | sort | jq -R . | jq -sc .'
  run --separate-stderr env -i SSH_ORIGINAL_COMMAND='agent list' SSH_CONNECTION='203.0.113.5 1 2 3' \
    BASH_ENV="$BATS_TEST_TMPDIR/evil.sh" ENV="$BATS_TEST_TMPDIR/evil.sh" "BASH_FUNC_jq%%=() { touch $marker; }" \
    FNKC_CORE_LOADED=1 FNKC_LOG_TAG=evil FNKC_LOG=stderr FNKC_REQ_DIR=/ PATH="/nonexistent:$GW_PATH" IFS=/ \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 SHELLOPTS=xtrace CDPATH=/ GLOBIGNORE='*' TMPDIR=/nonexistent HOME=/ \
    "$GW/fnkc-ctl" serve --user alice --agent-config "$GW_CONFIG" --path "$GW_PATH"
  assert_status 0
  [[ ! -e "$marker" && -z "$stderr" ]]
  [[ "$(reply_field '.result - ["PWD", "SHLVL", "_"]')" == '["FNKC_AGENT_CONFIG","FNKC_KEYS_DIR","FNKC_LIB","FNKC_LOG","FNKC_LOG_TAG","FNKC_REQUEST","FNKC_REQUIRE_PROVENANCE","FNKC_REQ_DIR","FNKC_ROOT","FNKC_STDIN_FILE","FNKC_TRUSTED_ROOT_FILE","FNKC_USER","FNKC_VERSION","HOME","LANG","LC_ALL","PATH","TMPDIR"]' ]]
  [[ "$(journal_lines)" == 'fnkc-ctl-sh user.info user=alice from=203.0.113.5 command=list ms='* ]]
}

@test "json stdin: capped at 2 MiB, no NUL bytes, handed over as a file" {
  stub_request start 'jq -c . "$FNKC_STDIN_FILE"'
  run --separate-stderr gateway 'agent start' <<<'{"project":"p"}'
  assert_status 0
  [[ "$output" == '{"ok":true,"result":{"project":"p"}}' ]]
  head -c $((2 * 1024 * 1024 + 1)) /dev/zero | tr '\0' ' ' >"$BATS_TEST_TMPDIR/big"
  run --separate-stderr gateway 'agent start' <"$BATS_TEST_TMPDIR/big"
  [[ "$status" -eq 1 && "$output" == '{"ok":false,"error":"request too large"}' ]]
  printf '{"project":"p\0"}' >"$BATS_TEST_TMPDIR/nul"
  run --separate-stderr gateway 'agent start' <"$BATS_TEST_TMPDIR/nul"
  [[ "$status" -eq 1 && "$output" == '{"ok":false,"error":"start: expected a JSON request on stdin"}' ]]
}

@test "failures surface: an injected docker failure, a bad result, fail helpers in subshells" {
  fake_reply -s 1 -e 'Cannot connect to the Docker daemon' -- docker ps
  run --separate-stderr gateway 'agent busy p'
  assert_status 1
  [[ "$output" == '{"ok":false,"error":"internal error: busy failed (status 1)"}' ]]
  journal_lines | grep -q 'user.warning .*command=busy project=p .*result=error error="internal error: busy failed (status 1)"'

  stub_request keep 'echo "not json"'
  run --separate-stderr gateway 'agent keep p'
  [[ "$status" -eq 1 && "$output" == '{"ok":false,"error":"internal error: keep gave no valid result"}' ]]

  stub_request keep 'x="$(fail_code busy "project p is busy")"; echo "{}"'
  run --separate-stderr gateway 'agent keep p'
  [[ "$status" -eq 1 && "$output" == '{"ok":false,"error":"project p is busy","code":"busy"}' ]]
  journal_lines | tail -1 | grep -q 'result=error code=busy error="project p is busy"'

  stub_request keep 'fail_code nope "x"'
  run --separate-stderr gateway 'agent keep p'
  [[ "$status" -eq 1 && "$(reply_field .error)" == '"internal error: keep failed (status 1)"' ]]
}

@test "envelope shapes: imageMissing and checkoutPins only with their codes" {
  stub_request start 'fail_image_missing "image missing" "ghcr.io/x/env@sha256:ab" arm64'
  run --separate-stderr gateway 'agent start' <<<'{}'
  [[ "$output" == '{"ok":false,"error":"image missing","code":"image-missing","imageMissing":{"image":"ghcr.io/x/env@sha256:ab","arch":"arm64"}}' ]]
  stub_request start 'fail_checkout_pins "pins another" "ghcr.io/x/env@sha256:cd"'
  run --separate-stderr gateway 'agent start' <<<'{}'
  [[ "$output" == '{"ok":false,"error":"pins another","code":"checkout-pins","checkoutPins":"ghcr.io/x/env@sha256:cd"}' ]]
  stub_request start 'fail "plain"'
  run --separate-stderr gateway 'agent start' <<<'{}'
  [[ "$output" == '{"ok":false,"error":"plain"}' ]]
}

@test "connect: raw stdout, refusals on stderr without a reply" {
  stub_request connect 'printf "SSH-2.0-test\n"'
  run --separate-stderr gateway 'agent connect p'
  [[ "$status" -eq 0 && "$output" == 'SSH-2.0-test' ]]
  run --separate-stderr gateway 'agent connect ../p'
  [[ "$status" -eq 1 && -z "$output" && "$stderr" == "Error: invalid project name: '../p'" ]]
  run --separate-stderr gateway 'agent connect'
  [[ "$status" -eq 1 && -z "$output" && "$stderr" == 'Error: connect requires exactly one project' ]]
}

@test "journal: request fields and warnings join the line" {
  stub_request keep 'journal_set until "2026-11-28 10:00"; warn "first"; warn "second"; echo "{}"'
  run --separate-stderr gateway 'agent keep p'
  assert_status 0
  [[ "$stderr" == $'Warning: first\nWarning: second' ]]
  [[ "$(journal_lines)" =~ command=keep\ project=p\ until=\"2026-11-28\ 10:00\"\ ms=[0-9]+\ result=ok\ warnings=\"first\ \|\ second\" ]]
}
