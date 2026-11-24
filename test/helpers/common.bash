# shellcheck shell=bash
# Shared bats setup. In a .bats file:
#
#   setup() {
#     load '../helpers/common'
#     setup_fakes            # docker, ssh and gh are fakes; add more names to fake them too (e.g. logger)
#   }
#
# Fakes (test/helpers/fake-command, which documents the scenario layout) answer from scenario directories under
# $FAKE_DIR, one per test, and log every call to $FAKE_DIR/calls.log. Tests add scenarios with fake_reply or by
# writing files under "$(fake_dir docker image inspect)"; the fake itself is never edited.

# Repository root and the server library, for `source "$FNKC_LIB/core.sh"`.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FNKC_LIB="$REPO_ROOT/server/lib"
export REPO_ROOT FNKC_LIB

# setup_fakes [name...]: fresh $FAKE_DIR, and a bin directory first on PATH with fakes for docker, ssh, gh and the
# given names. The real docker/ssh/gh can never run from a test.
setup_fakes() {
  FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  FAKE_BIN="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p -- "$FAKE_DIR" "$FAKE_BIN"
  : >"$FAKE_DIR/calls.log"
  local cmd
  for cmd in docker ssh gh "$@"; do
    [[ "$cmd" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
      echo "setup_fakes: bad command name: $cmd" >&2
      return 1
    }
    printf '#!/usr/bin/env bash\nexec bash %q %q "$@"\n' "$REPO_ROOT/test/helpers/fake-command" "$cmd" >"$FAKE_BIN/$cmd"
    chmod +x -- "$FAKE_BIN/$cmd"
  done
  PATH="$FAKE_BIN:$PATH"
  export FAKE_DIR FAKE_BIN PATH
}

# fake_dir <name> [word...]: create and print the scenario directory for this argv prefix.
fake_dir() {
  local d="$FAKE_DIR" w
  for w in "$@"; do
    [[ "$w" =~ ^[A-Za-z0-9_.:@=+,-]+$ && "$w" != . && "$w" != .. ]] || {
      echo "fake_dir: word cannot be a scenario path component: $w" >&2
      return 1
    }
    d="$d/$w"
  done
  mkdir -p -- "$d"
  printf '%s\n' "$d"
}

# fake_reply [-o stdout] [-e stderr] [-s status] [-n call] -- <name> [word...]
# Answer for calls whose argv starts with <name> <word...>. -o/-e text gets a trailing newline. With -n N the answer
# replaces the plain answer for the Nth call of this scenario only (other calls use the plain answer, if any).
fake_reply() {
  local out="" err="" status="" n="" has_out=0 has_err=0
  while (($#)); do
    case "$1" in
      -o) out="$2" has_out=1 && shift 2 ;;
      -e) err="$2" has_err=1 && shift 2 ;;
      -s) status="$2" && shift 2 ;;
      -n) n="$2" && shift 2 ;;
      --) shift && break ;;
      *)
        echo "fake_reply: unknown option $1 (missing --?)" >&2
        return 1
        ;;
    esac
  done
  local d sfx=""
  d="$(fake_dir "$@")"
  [[ -z "$n" ]] || sfx=".$n"
  ((has_out)) && printf '%s\n' "$out" >"$d/stdout$sfx"
  ((has_err)) && printf '%s\n' "$err" >"$d/stderr$sfx"
  [[ -n "$status" ]] && printf '%s\n' "$status" >"$d/status$sfx"
  [[ -n "$status" ]] || ((has_out || has_err)) || printf '0\n' >"$d/status$sfx"
  return 0
}

# fake_calls [name]: the call log, optionally only the calls of one command.
fake_calls() {
  if (($#)); then
    grep -E "^$1( |\$)" -- "$FAKE_DIR/calls.log" || true
  else
    cat -- "$FAKE_DIR/calls.log"
  fi
}

# _fake_line <name> [arg...]: the log line a call with this argv produces.
_fake_line() {
  local line a
  line="$(printf '%q' "$1")"
  shift
  for a in "$@"; do line+=" $(printf '%q' "$a")"; done
  printf '%s\n' "$line"
}

# assert_called <name> [arg...]: a call with exactly this argv was made.
assert_called() {
  local want
  want="$(_fake_line "$@")"
  grep -qxF -- "$want" "$FAKE_DIR/calls.log" || {
    printf 'expected call: %s\nactual calls:\n' "$want" >&2
    cat -- "$FAKE_DIR/calls.log" >&2
    return 1
  }
}

# refute_called <name>: the command was never run.
refute_called() {
  [[ -z "$(fake_calls "$1")" ]] || {
    printf 'unexpected calls of %s:\n' "$1" >&2
    fake_calls "$1" >&2
    return 1
  }
}

# refute <command...>: the command must fail. Use it instead of `! command`, which fails a bats test only when it is
# the test's last command.
refute() {
  if "$@"; then
    printf 'expected failure: %s\n' "$*" >&2
    return 1
  fi
}

# assert_status <n> / assert_output_contains <text>: checks on bats' $status and $output after `run`.
# shellcheck disable=SC2154 # status and output are set by bats' run
assert_status() {
  [[ "$status" -eq "$1" ]] || {
    printf 'expected status %s, got %s; output:\n%s\n' "$1" "$status" "$output" >&2
    return 1
  }
}

assert_output_contains() {
  [[ "$output" == *"$1"* ]] || {
    printf 'expected output to contain: %s\nactual output:\n%s\n' "$1" "$output" >&2
    return 1
  }
}
