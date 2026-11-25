#!/usr/bin/env bats
# server/lib/lock.sh: flock locks, busy after the timeout, lock order, release when the holder ends.

setup() {
  load '../helpers/common'
  setup_fakes
  export FNKC_LOG=stderr
  export FNKC_LOCK_DIR="$BATS_TEST_TMPDIR/locks"
  HOLDER=""
}

teardown() {
  [[ -z "$HOLDER" ]] || {
    kill -9 "$HOLDER" 2>/dev/null
    wait "$HOLDER" 2>/dev/null
  } || true
}

# run_lock <script> [arg...]: the script in a fresh strict-mode bash that sourced lock.sh, as a server script would.
run_lock() {
  bash -c 'source "$FNKC_LIB/lock.sh"; '"$1" lock "${@:2}"
}

# hold <name>: a background process takes the lock and keeps it until release_holder or a kill. It waits with the
# read builtin, so it has no child process that could inherit the lock.
hold() {
  local ready="$BATS_TEST_TMPDIR/ready" fifo="$BATS_TEST_TMPDIR/fifo"
  rm -f -- "$ready" "$fifo"
  mkfifo -- "$fifo"
  # bash itself is the background job (not a function's subshell around it), so $! is the holder's pid.
  bash -c 'source "$FNKC_LIB/lock.sh"; lock_acquire "$1"; : >"$2"; read -r -t 30 _ <>"$3" || true' \
    hold "$1" "$ready" "$fifo" >"$BATS_TEST_TMPDIR/holder.log" 2>&1 3>&- &
  HOLDER=$!
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -e "$ready" ]] && return 0
    sleep 0.1
  done
  cat -- "$BATS_TEST_TMPDIR/holder.log" >&2
  return 1
}

release_holder() {
  printf 'go\n' >"$BATS_TEST_TMPDIR/fifo"
  wait "$HOLDER"
  HOLDER=""
}

@test "project_lock names the lock after the user and project and validates both" {
  run run_lock 'project_lock alice my-proj.1'
  assert_status 0
  [[ "$output" == project-alice-my-proj.1 ]]
  run run_lock 'project_lock Alice p'
  assert_status 1
  assert_output_contains 'invalid user'
  run run_lock 'project_lock alice ../x'
  assert_status 1
}

@test "a lock is the file <name>.kernel, private, and stays after release" {
  run run_lock 'lock_acquire host; is_lock_held host; lock_release host; refute_held() { ! is_lock_held host; }; refute_held'
  assert_status 0
  [[ -f "$FNKC_LOCK_DIR/host.kernel" ]]
  [[ "$(stat -c %a -- "$FNKC_LOCK_DIR/host.kernel")" == 600 ]]
  [[ "$(stat -c %a -- "$FNKC_LOCK_DIR")" == 700 ]]
}

@test "names that are not locks are refused before any file is made" {
  local bad
  for bad in '' foo ../host 'host/../x' project-Alice-p project-alice- 'project-alice-a b' "host
" -host project-alice-../x; do
    run run_lock 'lock_acquire "$1"' "$bad"
    assert_status 1
    assert_output_contains 'invalid lock name'
  done
  [[ ! -e "$FNKC_LOCK_DIR" ]]
}

@test "a bad timeout or a relative lock directory is refused" {
  run run_lock 'lock_acquire host -1'
  assert_status 1
  assert_output_contains 'invalid timeout'
  run run_lock 'lock_acquire host "1;x"'
  assert_status 1
  FNKC_LOCK_DIR=locks run run_lock 'lock_acquire host'
  assert_status 1
  assert_output_contains 'absolute path'
}

@test "a lock file that is a symlink is refused" {
  mkdir -p -- "$FNKC_LOCK_DIR"
  ln -s -- "$BATS_TEST_TMPDIR/elsewhere" "$FNKC_LOCK_DIR/host.kernel"
  run run_lock 'lock_acquire host'
  assert_status 1
  assert_output_contains 'symlink'
  [[ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]]
}

@test "a lock not free within the timeout ends with the busy status and message" {
  hold project-alice-p
  run run_lock 'lock_acquire "$(project_lock alice p)" 0.3; echo SHOULD-NOT-RUN'
  assert_status 75
  assert_output_contains "fnkc-ctl: operation is busy; timed out waiting for $FNKC_LOCK_DIR/project-alice-p.kernel"
  [[ "$output" != *SHOULD-NOT-RUN* ]]
  # Other locks stay free
  run run_lock 'lock_acquire project-alice-q 0.3; lock_acquire host 0.3; echo ok'
  assert_status 0
  assert_output_contains ok
}

@test "a waiter says once that it waits, then gets the lock when the holder lets go" {
  hold image-upload
  (
    sleep 0.5
    printf 'go\n' >"$BATS_TEST_TMPDIR/fifo"
  ) 3>&- &
  local releaser=$!
  # Also when log lines go to the journal: the user must see why nothing happens
  setup_fakes logger
  FNKC_LOG=journal run run_lock 'lock_acquire -m "Waiting for another image upload to this host to finish" image-upload 10; echo got'
  wait "$releaser"
  wait "$HOLDER"
  HOLDER=""
  assert_status 0
  assert_output_contains 'fnkc-ctl: Waiting for another image upload to this host to finish'
  assert_output_contains got
  [[ "$(grep -c Waiting <<<"$output")" == 1 ]]
}

@test "no wait message when the lock is free" {
  run run_lock 'lock_acquire -m "Waiting" image-upload; echo got'
  assert_status 0
  [[ "$output" == got ]]
}

@test "a holder killed with SIGKILL releases its lock" {
  hold host
  run run_lock 'lock_acquire host 0.2'
  assert_status 75
  kill -9 "$HOLDER"
  wait "$HOLDER" 2>/dev/null || true
  HOLDER=""
  run run_lock 'lock_acquire host 5; echo got'
  assert_status 0
  assert_output_contains got
}

@test "a holder that dies (die, errexit) releases its lock" {
  run run_lock 'lock_acquire host; die "boom"'
  assert_status 1
  run run_lock 'lock_acquire host; false; echo not-here'
  assert_status 1
  [[ "$output" != *not-here* ]]
  run run_lock 'lock_acquire host 0.5; echo got'
  assert_status 0
  assert_output_contains got
}

@test "the lock order is project, image-upload, image-store, host" {
  run run_lock 'lock_acquire project-alice-p; lock_acquire image-store; lock_acquire host; echo ok'
  assert_status 0
  assert_output_contains ok
  run run_lock 'lock_acquire image-upload; lock_acquire image-store; echo ok'
  assert_status 0
  assert_output_contains ok
  run run_lock 'lock_acquire project-alice-p; lock_release project-alice-p; lock_acquire host; lock_release host; lock_acquire project-alice-p; echo ok'
  assert_status 0
  assert_output_contains ok
}

@test "out-of-order or repeated locks die before waiting" {
  run run_lock 'lock_acquire host; lock_acquire project-alice-p; echo not-here'
  assert_status 1
  assert_output_contains 'lock order violation: project-alice-p while holding host'
  [[ "$output" != *not-here* ]]
  run run_lock 'lock_acquire image-store; lock_acquire image-upload'
  assert_status 1
  assert_output_contains 'lock order violation'
  run run_lock 'lock_acquire image-upload; lock_acquire project-alice-p'
  assert_status 1
  assert_output_contains 'lock order violation'
  # Two project locks, or the same lock twice, would wait for this very process
  run run_lock 'lock_acquire project-alice-p; lock_acquire project-alice-q'
  assert_status 1
  assert_output_contains 'lock order violation'
  run run_lock 'lock_acquire host; lock_acquire host 5'
  assert_status 1
  assert_output_contains 'lock order violation'
}

@test "lock_release of a lock not held dies" {
  run run_lock 'lock_release host'
  assert_status 1
  assert_output_contains 'host is not held'
}

@test "with_lock runs the command under the lock and releases it" {
  run run_lock 'f() { is_lock_held host && echo "inside $1"; }; with_lock host 5 -- f arg; is_lock_held host || echo released'
  assert_status 0
  assert_output_contains 'inside arg'
  assert_output_contains released
}

@test "with_lock keeps the command's status and releases when errexit is off" {
  run run_lock 'f() { return 3; }; rc=0; with_lock host 5 -- f || rc=$?; echo "rc=$rc"; is_lock_held host || echo released'
  assert_status 0
  assert_output_contains 'rc=3'
  assert_output_contains released
}

@test "with_lock under errexit: a failing command ends the process and the lock is free again" {
  run run_lock 'f() { false; echo not-here; }; with_lock host 5 -- f; echo not-here-either'
  assert_status 1
  [[ "$output" != *not-here* ]]
  run run_lock 'lock_acquire host 0.5; echo got'
  assert_status 0
  assert_output_contains got
}

@test "with_lock busy ends with the busy status without running the command" {
  hold project-alice-p
  run run_lock 'with_lock project-alice-p 0.2 -- echo ran'
  assert_status 75
  [[ "$output" != *ran* ]]
}

@test "with_lock needs -- and a command" {
  run run_lock 'with_lock host 5 echo x'
  assert_status 1
  assert_output_contains usage
  run run_lock 'with_lock host 5 --'
  assert_status 1
  assert_output_contains usage
}
