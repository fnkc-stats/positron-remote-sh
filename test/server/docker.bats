#!/usr/bin/env bats
# server/lib/docker.sh: docker wrappers with timeouts, ownership-checked lookups, helper containers.

setup() {
  load '../helpers/common'
  setup_fakes
  export FNKC_LOG=stderr
}

# call <function> [arg...]: run docker.sh functions in a fresh strict-mode bash, as a server script would.
call() {
  bash -c 'source "$FNKC_LIB/docker.sh"; "$@"' call "$@"
}

# script <body>: run <body> after sourcing docker.sh (fixed test code, never input).
script() {
  bash -c "source \"\$FNKC_LIB/docker.sh\"; $1"
}

L='{"fnkcsh.managed":"1","fnkcsh.user":"alice","fnkcsh.project":"a"}'

# cobj <name> <labels-json>: one container as docker inspect prints it.
cobj() { jq -cn --arg n "/$1" --argjson l "$2" '{Name: $n, Config: {Labels: $l}, State: {Running: true}}'; }

# sleeper <scenario words...>: a scenario that hangs until killed.
sleeper() {
  local d
  d="$(fake_dir "$@")"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$d/run"
  chmod +x "$d/run"
}

@test "docker_ok: arguments after --, stdout printed" {
  fake_reply -o 'id1' -- docker ps
  run call docker_ok -- ps -aq --filter 'label=x=$(id)'
  assert_status 0
  [ "$output" = id1 ]
  assert_called docker ps -aq --filter 'label=x=$(id)'
}

@test "docker_ok: an injected docker failure dies with its error, and stops a caller in \$(...)" {
  fake_reply -s 1 -e 'Cannot connect to the Docker daemon' -- docker ps
  run call docker_ok -- ps -aq
  assert_status 1
  [ "$output" = "fnkc-ctl: docker ps -aq: Cannot connect to the Docker daemon" ]
  run script 'x="$(docker_ok -- ps -aq)"; echo "not reached $x"'
  assert_status 1
  [[ "$output" != *"not reached"* ]]
}

@test "docker_ok: a docker call that hangs is cut off at its deadline" {
  sleeper docker info
  SECONDS=0
  run call docker_ok -t 1 -- info
  assert_status 1
  assert_output_contains "docker info: operation timed out"
  ((SECONDS < 10))
}

@test "docker_capture: status and stderr kept, returns 0 for the caller to decide" {
  fake_reply -s 3 -o out -e err -- docker volume
  run script 'docker_capture -- volume ls; echo "$DOCKER_STATUS|$DOCKER_OUT|$DOCKER_ERR"'
  assert_status 0
  [ "$output" = "3|out|err" ]
  : >"$FAKE_DIR/calls.log"
  run call docker_capture -t 0 -- volume ls
  assert_status 1
  run call docker_capture volume ls
  assert_status 1
  refute_called docker
}

@test "docker_inspect: missing object is empty, other errors die, bad names never reach docker" {
  fake_reply -s 1 -e 'Error: No such container: fnkcsh-alice-a' -- docker container inspect -- fnkcsh-alice-a
  run call docker_inspect container fnkcsh-alice-a
  assert_status 0
  [ -z "$output" ]
  fake_reply -s 1 -e 'permission denied' -- docker container inspect -- fnkcsh-alice-b
  run call docker_inspect container fnkcsh-alice-b
  assert_status 1
  assert_output_contains "cannot inspect container: permission denied"
  fake_reply -o '[]' -- docker container inspect -- fnkcsh-alice-c
  run call docker_inspect container fnkcsh-alice-c
  assert_status 1
  assert_output_contains "unexpected output from docker"
  : >"$FAKE_DIR/calls.log"
  run call docker_inspect container '-x'
  assert_status 1
  run call docker_inspect image fnkcsh-alice-a
  assert_status 1
  refute_called docker
}

@test "own_object: owned, absent, and anything else under the name refused" {
  fake_reply -o "[$(cobj fnkcsh-alice-a "$L")]" -- docker container inspect -- fnkcsh-alice-a
  run call own_object container alice a fnkcsh-alice-a
  assert_status 0
  [ "$(jq -r '.[0].Name' <<<"$output")" = /fnkcsh-alice-a ]

  fake_reply -s 1 -e 'Error: No such object: fnkcsh.recovery.alice.a' -- docker container inspect -- fnkcsh.recovery.alice.a
  run call own_object container alice a fnkcsh.recovery.alice.a
  assert_status 0
  [ -z "$output" ]

  # label spoofing: bob's labels, a.b's labels, positron-remote's labels on alice's name
  local l
  for l in '{"fnkcsh.managed":"1","fnkcsh.user":"bob","fnkcsh.project":"a"}' \
    '{"fnkcsh.managed":"1","fnkcsh.user":"alice","fnkcsh.project":"a.b"}' \
    '{"fnkc.managed":"1","fnkc.user":"alice","fnkc.project":"a"}'; do
    fake_reply -o "[$(cobj fnkcsh-alice-a "$l")]" -- docker container inspect -- fnkcsh-alice-a
    run call own_object container alice a fnkcsh-alice-a
    assert_status 1
    [ "$output" = "fnkc-ctl: refusing container not owned by this user/project: fnkcsh-alice-a" ]
  done
}

@test "own_object: inspect answering another object (ID prefix, renamed) is refused" {
  fake_reply -o "[$(cobj fnkcsh-alice-ab "$L")]" -- docker container inspect -- fnkcsh-alice-a
  run call own_object container alice a fnkcsh-alice-a
  assert_status 1
  assert_output_contains "refusing container not owned"
}

@test "own_object: only names computed for this user and project reach docker" {
  local n
  for n in fnkcsh-bob-a fnkcsh-alice-a.b fnkc-alice-a fnkcsh-alice-a-net fnkcsh.read.alice.a.0123456789ab; do
    run call own_object container alice a "$n"
    assert_status 1
  done
  run call own_object container bob.x a fnkcsh-bob.x-a
  assert_status 1
  refute_called docker
}

@test "own_object: a refusal inside \$(...) stops the caller" {
  fake_reply -o "[$(cobj fnkcsh-alice-a '{}')]" -- docker container inspect -- fnkcsh-alice-a
  run script 'c="$(own_object container alice a fnkcsh-alice-a)"; echo "not reached $c"'
  assert_status 1
  [[ "$output" != *"not reached"* ]]
}

@test "find_owned: label filters, then only objects whose labels and name match" {
  fake_reply -o $'id1\nid2\nid3\nid4\nid5\nid6' -- docker ps -aq --no-trunc
  jq -cn --argjson a "$(cobj fnkcsh-alice-a "$L")" \
    --argjson b "$(cobj fnkcsh-bob-a "$L")" \
    --argjson c "$(cobj fnkcsh-alice-a.b "$L")" \
    --argjson d "$(cobj fnkcsh-alice-x '{"fnkcsh.managed":"1","fnkcsh.user":"alice","fnkcsh.project":"x"}')" \
    --argjson e "$(cobj fnkc-alice-a '{"fnkc.managed":"1","fnkc.user":"alice","fnkc.project":"a"}')" \
    --argjson f "$(cobj fnkcsh.recovery.alice.x '{"fnkcsh.managed":"1","fnkcsh.user":"alice","fnkcsh.project":"x"}')" \
    '[$a, $b, $c, $d, $e, $f]' >"$(fake_dir docker container inspect)/stdout"
  run call find_owned container alice
  assert_status 0
  [ "$(jq -c 'map(.Name)' <<<"$output")" = '["/fnkcsh-alice-a","/fnkcsh-alice-x","/fnkcsh.recovery.alice.x"]' ]
  assert_called docker ps -aq --no-trunc --filter label=fnkcsh.managed=1 --filter label=fnkcsh.user=alice
  assert_called docker container inspect -- id1 id2 id3 id4 id5 id6

  run call find_owned container alice a
  assert_status 0
  [ "$(jq -c 'map(.Name)' <<<"$output")" = '["/fnkcsh-alice-a"]' ]
  assert_called docker ps -aq --no-trunc --filter label=fnkcsh.managed=1 --filter label=fnkcsh.user=alice \
    --filter label=fnkcsh.project=a
}

@test "find_owned: volumes; restored archives and other projects' volumes are left out" {
  fake_reply -o $'v1\nv2\nv3' -- docker volume ls
  jq -cn --argjson l "$L" '[
    {Name: "fnkcsh-alice-a-data", Labels: $l},
    {Name: "fnkcsh-alice-a-project", Labels: ($l + {"fnkcsh.restore": "snap"})},
    {Name: "fnkcsh-ext-alice-a-x64-0123456789ab", Labels: $l}]' >"$(fake_dir docker volume inspect)/stdout"
  run call find_owned volume alice a
  assert_status 0
  [ "$(jq -c 'map(.Name)' <<<"$output")" = '["fnkcsh-alice-a-data","fnkcsh-ext-alice-a-x64-0123456789ab"]' ]
  assert_called docker volume ls -q --filter label=fnkcsh.managed=1 --filter label=fnkcsh.user=alice \
    --filter label=fnkcsh.project=a
}

@test "find_owned: nothing listed is an empty array without inspecting" {
  fake_reply -o '' -- docker network ls
  run call find_owned network alice
  assert_status 0
  [ "$output" = '[]' ]
  [ -z "$(fake_calls docker | grep inspect)" ]
}

@test "find_owned: objects gone since the listing are skipped; other failures surface" {
  fake_reply -o $'id1\nid2' -- docker ps -aq --no-trunc
  fake_reply -o "[$(cobj fnkcsh-alice-a "$L")]" -e 'Error: No such object: id2' -s 1 -- docker container inspect
  run call find_owned container alice
  assert_status 0
  [ "$(jq -c 'map(.Name)' <<<"$output")" = '["/fnkcsh-alice-a"]' ]

  fake_reply -o '' -e $'Error: No such object: id2\nerror during connect' -s 1 -- docker container inspect
  run call find_owned container alice
  assert_status 1
  assert_output_contains "cannot inspect containers"

  fake_reply -s 1 -e 'Cannot connect to the Docker daemon' -- docker ps -aq --no-trunc
  run call find_owned container alice
  assert_status 1
  assert_output_contains "Cannot connect to the Docker daemon"
}

@test "find_owned: hostile ids from docker and bad users never reach inspect" {
  fake_reply -o $'id1\n--format={{json .}}' -- docker ps -aq --no-trunc
  run call find_owned container alice
  assert_status 1
  run call find_owned container 'alice;x'
  assert_status 1
  [ -z "$(fake_calls docker | grep inspect)" ]
}

@test "remove_helpers: only this project's helpers, by exact name" {
  fake_reply -o "$(printf '%s\n' fnkcsh.read.alice.a.0123456789ab fnkcsh.ext.alice.a.aaaaaaaaaaaa \
    fnkcsh.read.alice.a.b.0123456789ab fnkcsh.read.bob.a.0123456789ab fnkc.read.alice.a.0123456789ab \
    fnkcsh-alice-a fnkcsh.recovery.alice.a fnkcsh.read.alice.a.0123456789abc)" -- docker ps -a --format
  fake_reply -s 0 -- docker rm
  run call remove_helpers alice a
  assert_status 0
  [ "$(fake_calls docker | grep -c '^docker rm')" -eq 2 ]
  assert_called docker rm -f -- fnkcsh.read.alice.a.0123456789ab
  assert_called docker rm -f -- fnkcsh.ext.alice.a.aaaaaaaaaaaa
}

@test "remove_helpers: a listing failure is a warning; a removal failure too, unless it is already gone" {
  fake_reply -s 1 -e 'daemon down' -- docker ps -a --format
  run call remove_helpers alice a
  assert_status 0
  assert_output_contains "could not list leftover helper containers: daemon down"
  [ -z "$(fake_calls docker | grep '^docker rm')" ]

  fake_reply -s 0 -o 'fnkcsh.read.alice.a.0123456789ab' -- docker ps -a --format
  fake_reply -s 1 -e 'Error: No such container: fnkcsh.read.alice.a.0123456789ab' -- docker rm
  run call remove_helpers alice a
  assert_status 0
  [ -z "$output" ]
  fake_reply -s 1 -e 'Error: device busy' -- docker rm
  run call remove_helpers alice a
  assert_status 0
  assert_output_contains "could not remove the helper container fnkcsh.read.alice.a.0123456789ab: Error: device busy"
}

# helper_run_line: the docker run call of run_helper, as logged.
helper_run_line() { fake_calls docker | grep '^docker run --rm --name '; }

@test "run_helper: name, labels and hardening options; clean exit leaves removal to --rm" {
  fake_reply -o '' -- docker ps -a --format
  fake_reply -o 'checkout ok' -- docker run
  run script 'run_helper read alice a.b 30 "0 3" -- --user 1000 img@sha256:x cat /x; echo "status=$HELPER_STATUS"'
  assert_status 0
  [ "$output" = $'checkout ok\nstatus=0' ]
  local line
  line="$(helper_run_line)"
  [[ "$line" =~ ^docker\ run\ --rm\ --name\ fnkcsh\.read\.alice\.a\.b\.[0-9a-f]{12}\ --label\ fnkcsh\.helper=read\ --label\ fnkcsh\.helper\.user=alice\ --label\ fnkcsh\.helper\.project=a\.b\ --init\ --log-driver\ none\ --read-only\ --stop-timeout\ 1\ --network\ none\ --security-opt\ no-new-privileges\ --cap-drop\ ALL\ --cpus\ 1\ --user\ 1000\ img@sha256:x\ cat\ /x$ ]]
  [ -z "$(fake_calls docker | grep '^docker rm')" ]
}

@test "run_helper: an exit code outside <exited> removes the container by name" {
  fake_reply -o '' -- docker ps -a --format
  fake_reply -s 125 -e 'docker: Error response from daemon' -- docker run
  fake_reply -s 0 -- docker rm
  run script 'run_helper -e /dev/null ext alice a 30 0 -- img; echo "status=$HELPER_STATUS"'
  assert_status 0
  [ "$output" = status=125 ]
  local name
  name="$(helper_run_line | awk '{print $5}')"
  [[ "$name" =~ ^fnkcsh\.ext\.alice\.a\.[0-9a-f]{12}$ ]]
  assert_called docker rm -f -- "$name"
}

@test "run_helper: a helper that never finishes is cut off and removed" {
  fake_reply -o '' -- docker ps -a --format
  sleeper docker run
  fake_reply -s 0 -- docker rm
  SECONDS=0
  run script 'run_helper read alice a 1 0 -- img; echo "status=$HELPER_STATUS"'
  assert_status 0
  [ "$output" = status=124 ]
  ((SECONDS < 15))
  [ "$(fake_calls docker | grep -c '^docker rm -f -- fnkcsh.read.alice.a.')" -eq 1 ]
}

@test "run_helper: leftovers removed first; output to files; bad arguments refused before docker" {
  fake_reply -o 'fnkcsh.read.alice.a.0123456789ab' -- docker ps -a --format
  fake_reply -s 0 -- docker rm
  fake_reply -o 'data' -e 'note' -- docker run
  run script "run_helper -o '$BATS_TEST_TMPDIR/out' -e '$BATS_TEST_TMPDIR/err' read alice a 30 0 -- img"
  assert_status 0
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = data ]
  [ "$(cat "$BATS_TEST_TMPDIR/err")" = note ]
  [ "$(fake_calls docker | head -2 | tail -1)" = 'docker rm -f -- fnkcsh.read.alice.a.0123456789ab' ]

  : >"$FAKE_DIR/calls.log"
  run call run_helper write alice a 30 0 -- img
  assert_status 1
  run call run_helper read alice '../a' 30 0 -- img
  assert_status 1
  run call run_helper read alice a 0 0 -- img
  assert_status 1
  run call run_helper read alice a 30 'x' -- img
  assert_status 1
  run call run_helper read alice a 30 0 img
  assert_status 1
  [ -z "$(fake_calls docker | grep '^docker run')" ]
}
