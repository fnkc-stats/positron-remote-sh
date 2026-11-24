#!/usr/bin/env bats
# server/lib/core.sh: strict mode, logging, die, validators.

setup() {
  load '../helpers/common'
  setup_fakes logger
  fake_reply -- logger
  SCRIPT="$BATS_TEST_TMPDIR/script.sh"
}

# script <body>: a small script that sources core.sh, then runs <body>.
script() {
  printf '#!/usr/bin/env bash\nsource %q\n%s\n' "$FNKC_LIB/core.sh" "$1" >"$SCRIPT"
  chmod +x "$SCRIPT"
}

@test "strict mode: a failing command in a command substitution stops the script" {
  script 'x="$(false; echo late)"; echo "not reached $x"'
  run "$SCRIPT"
  assert_status 1
  [[ "$output" != *"not reached"* ]]
}

@test "strict mode: an injected docker failure inside a pipeline is not lost" {
  fake_reply -s 3 -e 'Error: boom' -- docker ps
  script 'docker ps | cat; echo "not reached"'
  run "$SCRIPT"
  assert_status 3
  [[ "$output" != *"not reached"* ]]
  assert_called docker ps
}

@test "strict mode: unset variables are errors" {
  script 'echo "$NO_SUCH_VARIABLE"'
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "die: message on stderr with the tag, status 1, logged to the journal at err" {
  script 'die "project is busy"; echo "not reached"'
  FNKC_LOG=journal run "$SCRIPT"
  assert_status 1
  [ "$output" = "fnkc-ctl: project is busy" ]
  assert_called logger -t fnkc-ctl -p user.err -- "project is busy"
}

@test "die_status: explicit status; out-of-range status falls back to 1" {
  script 'die_status 7 "nope"'
  FNKC_LOG=stderr run "$SCRIPT"
  assert_status 7
  script 'die_status 300 "nope"'
  FNKC_LOG=stderr run "$SCRIPT"
  assert_status 1
  script 'die_status x "nope"'
  FNKC_LOG=stderr run "$SCRIPT"
  assert_status 1
}

@test "die inside a command substitution stops the caller too" {
  script 'v="$(die "inner")"; echo "not reached $v"'
  FNKC_LOG=stderr run "$SCRIPT"
  assert_status 1
  [[ "$output" != *"not reached"* ]]
}

@test "log: goes to logger with tag, priority and -- before the message" {
  script 'FNKC_LOG_TAG=fnkc-test; log info "-p user.crit spoof"'
  FNKC_LOG=journal run "$SCRIPT"
  assert_status 0
  [ -z "$output" ]
  assert_called logger -t fnkc-test -p user.info -- "-p user.crit spoof"
}

@test "log: an unknown priority becomes err" {
  script 'log bogus "x"'
  FNKC_LOG=journal run "$SCRIPT"
  assert_called logger -t fnkc-ctl -p user.err -- x
}

@test "log: newlines and control characters cannot forge extra lines" {
  script 'log warning "$(printf "a\nfnkc-ctl[crit]: forged\033[0m")"'
  FNKC_LOG=stderr run "$SCRIPT"
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "fnkc-ctl[warning]: a?fnkc-ctl[crit]: forged?[0m" ]
}

@test "log: falls back to stderr when logger fails" {
  fake_reply -s 1 -e 'logger: socket /dev/log: No such file' -- logger
  script 'log notice "hello"'
  FNKC_LOG=journal run "$SCRIPT"
  assert_status 0
  [ "$output" = "fnkc-ctl[notice]: hello" ]
}

@test "log: FNKC_LOG=stderr never calls logger" {
  script 'log info "hello"'
  FNKC_LOG=stderr run "$SCRIPT"
  [ "$output" = "fnkc-ctl[info]: hello" ]
  refute_called logger
}

@test "core.sh can be sourced twice" {
  script "source $(printf '%q' "$FNKC_LIB/core.sh"); echo ok"
  run "$SCRIPT"
  assert_status 0
  [ "$output" = ok ]
}

# Validators run in this shell: source core.sh into a subshell per check so its strict mode does not leak into bats.
matches() { (source "$FNKC_LIB/core.sh" && is_match "$@"); }

@test "is_match: anchored, whole value only" {
  matches '[a-z]+' abc
  refute matches '[a-z]+' 'abc;rm'
  refute matches '[a-z]+' 'x abc'
  refute matches 'a|b' 'ab'
}

@test "is_match: hostile values are refused even when the pattern would allow them" {
  local any='.*'
  refute matches "$any" ''
  refute matches "$any" '-rf'
  refute matches "$any" '--help'
  refute matches "$any" "$(printf 'a\nb')"
  refute matches "$any" "$(printf 'a\tb')"
  refute matches "$any" "$(printf 'a\033b')"
  refute matches "$any" "$(printf 'a\rb')"
  matches "$any" 'a b'
}

@test "is_match: shell metacharacters and traversal are refused by a name pattern" {
  local name='[a-z0-9][a-z0-9._-]*'
  local bad
  for bad in 'a;b' 'a|b' 'a&b' 'a$(id)' 'a`id`' "a'b" 'a"b' 'a b' 'a/b' '../a' 'a*' 'a>b' 'a\b'; do
    refute matches "$name" "$bad"
  done
  matches "$name" 'my-project.v2'
}

@test "is_match: Unicode look-alikes do not match ASCII ranges" {
  refute matches '[a-z]+' "$(printf '\xd0\xb0bc')" # Cyrillic a
  refute matches '[a-z]+' "$(printf 'ab\xd1\x81')" # Cyrillic s
  refute matches '[a-z]+' "$(printf 'ab\xc3\xa9')"
  refute matches '[a-z]+' "$(printf 'a\xef\xbc\x8fb')"
}

@test "is_match: length cap in bytes, default 256" {
  local long
  long="$(printf 'a%.0s' {1..256})"
  matches '[a-z]+' "$long"
  refute matches '[a-z]+' "${long}a"
  matches '[a-z]+' abcd 4
  refute matches '[a-z]+' abcde 4
  refute matches '[a-z]+' "$(printf '\xc3\xa9\xc3\xa9\xc3\xa9')" 5
}

@test "is_match: a bad pattern or limit is an error (2), not a match" {
  run matches '' abc
  assert_status 2
  run matches '[a-z]+' abc 0
  assert_status 2
  run matches '[a-z]+' abc x
  assert_status 2
}

@test "require_match: dies with 'invalid <what>' and does not echo the value" {
  script 'require_match project "[a-z]+" "$1"; echo "ok $1"'
  FNKC_LOG=stderr run "$SCRIPT" abc
  assert_status 0
  [ "$output" = "ok abc" ]
  FNKC_LOG=stderr run "$SCRIPT" 'x;id'
  assert_status 1
  [ "$output" = "fnkc-ctl: invalid project" ]
}

@test "require_match: refused before any docker call" {
  script 'require_match project "[a-z]+" "$1"; docker rm -f -- "$1"'
  FNKC_LOG=stderr run "$SCRIPT" '-f'
  assert_status 1
  refute_called docker
}

@test "is_uint: decimal, no sign, no leading zeros, at most 19 digits" {
  (
    source "$FNKC_LIB/core.sh"
    is_uint 0
    is_uint 42
    refute is_uint 042
    refute is_uint -1
    refute is_uint +1
    refute is_uint 1.5
    refute is_uint ''
    is_uint 1234567890123456789
    refute is_uint 12345678901234567890
  )
}
