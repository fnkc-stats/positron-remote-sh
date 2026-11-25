# shellcheck shell=bash
# Gateway test setup: runs server/fnkc-ctl serve as sshd would, with the fakes reachable although serve replaces the
# environment. In a .bats file:
#
#   setup() {
#     load '../helpers/common'
#     load '../helpers/gateway'
#     setup_gateway          # a copy of server/ in $GW, user alice with a key, agent.json in $GW_CONFIG
#   }
#   run gateway 'agent ping'                       # SSH_ORIGINAL_COMMAND; stdin passes through
#   stub_request busy 'docker ps; echo "[]"'       # a request file in the copy (body after request.sh)
#   journal_lines                                  # what went to logger: "<tag> <priority> <line>" per call
#
# serve keeps no variable from its caller, so the fakes get FAKE_DIR from wrappers that have it written in, and PATH
# comes from serve's --path option (which a client cannot set: it is in the authorized_keys command line).

setup_gateway() {
  setup_fakes logger "$@"
  GW="$BATS_TEST_TMPDIR/server"
  cp -R -- "$REPO_ROOT/server" "$GW"
  GW_KEYS="$BATS_TEST_TMPDIR/keys"
  GW_CONFIG="$BATS_TEST_TMPDIR/agent.json"
  GW_ROOT_FILE="$BATS_TEST_TMPDIR/trusted-root.jsonl"
  mkdir -p -- "$GW_KEYS"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOfakeKeyForTestsOnly alice@laptop\n' >"$GW_KEYS/alice.pub"
  : >"$GW_ROOT_FILE"
  jq -n --arg k "$GW_KEYS" --arg t "$GW_ROOT_FILE" '{keysDir: $k, trustedRootFile: $t}' >"$GW_CONFIG"
  local bin="$BATS_TEST_TMPDIR/gw-bin" cmd
  mkdir -p -- "$bin"
  for cmd in "$FAKE_BIN"/*; do
    printf '#!/bin/bash\nexport FAKE_DIR=%q\nexec %q "$@"\n' "$FAKE_DIR" "$cmd" >"$bin/${cmd##*/}"
    chmod +x -- "$bin/${cmd##*/}"
  done
  GW_PATH="$bin:/usr/local/bin:/usr/bin:/bin"
  # logger: keep "<tag> <priority> <line>" (argv: -t tag -p prio -- line)
  local d
  d="$(fake_dir logger)"
  printf '#!/bin/bash\nprintf "%%s %%s %%s\\n" "$2" "$4" "$6" >>"$FAKE_DIR/journal"\n' >"$d/run"
  chmod +x -- "$d/run"
  : >"$FAKE_DIR/journal"
  export GW GW_KEYS GW_CONFIG GW_ROOT_FILE GW_PATH
}

# gateway <ssh command> [serve option...]: one request as user alice from 203.0.113.5.
gateway() {
  local cmd="$1"
  shift
  env -i SSH_ORIGINAL_COMMAND="$cmd" SSH_CONNECTION='203.0.113.5 50022 198.51.100.7 22' \
    "$GW/fnkc-ctl" serve --user alice --agent-config "$GW_CONFIG" --path "$GW_PATH" "$@"
}

# stub_request <request> <body>: server/requests/<request>.sh in the copy, sourcing request.sh first.
stub_request() {
  printf '#!/usr/bin/env bash\nsource "$FNKC_LIB/request.sh"\n%s\n' "$2" >"$GW/requests/$1.sh"
}

journal_lines() {
  cat -- "$FAKE_DIR/journal"
}

# reply_field <jq filter>: a field of the reply in $output (bats run), as compact JSON.
# shellcheck disable=SC2154 # output is set by bats' run
reply_field() {
  jq -c "$1" <<<"$output"
}
