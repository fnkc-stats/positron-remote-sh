#!/usr/bin/env bats
# The test harness itself: fake docker/ssh/gh, scenario lookup, call log.

setup() {
  load '../helpers/common'
  setup_fakes
}

@test "fakes shadow the real docker, ssh and gh" {
  [ "$(command -v docker)" = "$FAKE_BIN/docker" ]
  [ "$(command -v ssh)" = "$FAKE_BIN/ssh" ]
  [ "$(command -v gh)" = "$FAKE_BIN/gh" ]
}

@test "no scenario: exit 99 and a message, so unexpected calls fail" {
  run docker rm -f x
  assert_status 99
  assert_output_contains "fake docker: no scenario for: docker rm -f x"
}

@test "deepest matching scenario answers stdout, stderr and status" {
  fake_reply -o generic -- docker image
  fake_reply -o '[{"Id":"sha256:abc"}]' -e warn -s 0 -- docker image inspect
  fake_reply -s 1 -e 'No such image' -- docker image inspect missing
  run docker image inspect present
  assert_status 0
  [ "$output" = $'[{"Id":"sha256:abc"}]\nwarn' ]
  run docker image inspect missing
  assert_status 1
  [ "$output" = "No such image" ]
  run docker image ls
  [ "$output" = generic ]
}

@test "catch-all scenario for a whole command" {
  fake_reply -s 0 -- ssh
  run ssh -T host true
  assert_status 0
}

@test "the walk stops at the first word that is not a plain path component" {
  fake_reply -o top -- docker run
  mkdir -p "$FAKE_DIR/docker/run/x"
  printf 'deeper\n' >"$FAKE_DIR/docker/run/x/stdout"
  run docker run '../x'
  [ "$output" = top ]
  run docker run 'a/b' x
  [ "$output" = top ]
  run docker run x
  [ "$output" = deeper ]
}

@test "numbered answers apply to the Nth call of a scenario" {
  fake_reply -o starting -- docker inspect
  fake_reply -n 3 -o running -- docker inspect
  fake_reply -n 2 -s 1 -e 'not yet' -- docker inspect
  run docker inspect c
  [ "$output" = starting ]
  run docker inspect c
  assert_status 1
  [ "$output" = "not yet" ]
  run docker inspect c
  [ "$output" = running ]
  run docker inspect c
  [ "$output" = starting ]
}

@test "run script gets argv and stdin" {
  d="$(fake_dir gh attestation)"
  printf '#!/usr/bin/env bash\nprintf "args=%%s\\n" "$*"; cat\n' >"$d/run"
  chmod +x "$d/run"
  run bash -c 'echo payload | gh attestation verify --bundle b.json'
  assert_status 0
  [ "$output" = $'args=attestation verify --bundle b.json\npayload' ]
}

@test "capture-stdin saves stdin per call" {
  fake_reply -- docker load
  touch "$FAKE_DIR/docker/load/capture-stdin"
  printf 'tar bytes' | docker load
  [ "$(cat "$FAKE_DIR/stdin.1")" = "tar bytes" ]
}

@test "call log: one shell-quoted line per call, in order, across commands" {
  fake_reply -- docker
  fake_reply -- ssh
  docker exec -i "my container" sh -c 'echo $HOME'
  ssh -- host "$(printf 'two\nlines')"
  [ "$(wc -l <"$FAKE_DIR/calls.log")" -eq 2 ]
  assert_called docker exec -i "my container" sh -c 'echo $HOME'
  assert_called ssh -- host "$(printf 'two\nlines')"
  refute assert_called docker exec -i my container sh -c 'echo $HOME'
  [ "$(fake_calls ssh | wc -l)" -eq 1 ]
  refute refute_called docker
  refute_called gh
}

@test "bad status file is reported, not treated as success" {
  d="$(fake_dir docker ps)"
  printf 'zero\n' >"$d/status"
  run docker ps
  assert_status 98
}

@test "fake_dir refuses words that cannot be path components" {
  run fake_dir docker ../escape
  assert_status 1
  [ ! -e "$FAKE_DIR/escape" ]
}

@test "setup_fakes refuses odd command names" {
  run setup_fakes 'a/b'
  assert_status 1
}
