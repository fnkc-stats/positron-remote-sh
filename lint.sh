#!/usr/bin/env bash
# Checks before a commit (and in CI): shell scripts, GitHub Actions workflows, Dockerfiles, committed secrets,
# bats unit tests and English-only text outside Markdown. Every static check CI runs is here, so a commit
# that passes the hook passes CI's lint as well; CI adds only what needs the network or built images.
#
#   ./lint.sh                  check the whole repository
#   ./lint.sh --install-hook   run it before every commit (git config core.hooksPath .githooks)
#
# Tools: shellcheck, actionlint, hadolint, gitleaks, bats-core (brew install shellcheck actionlint hadolint gitleaks bats-core).
# If a tool is not installed, it runs from a Docker image with a pinned version.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

if [ "${1:-}" = --install-hook ]; then
  git config core.hooksPath .githooks && echo "pre-commit enabled: .githooks/pre-commit -> ./lint.sh"
  exit $?
fi

SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0
ACTIONLINT_IMAGE=rhysd/actionlint:1.7.12
HADOLINT_IMAGE=hadolint/hadolint:v2.14.0
GITLEAKS_IMAGE=zricethezav/gitleaks:v8.21.2

# tool <name> <image> <args>: the local binary, or the same tool in Docker
tool() {
  local name="$1" image="$2"; shift 2
  if command -v "$name" >/dev/null 2>&1; then
    "$name" "$@"
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker run --rm -i -v "$PWD:/repo:ro" -w /repo --entrypoint "$name" "$image" "$@"
  else
    echo "  $name is not installed and Docker is not running: brew install $name" >&2
    return 1
  fi
}

failed=""
check() {  # check <title> <command...>
  local title="$1"; shift
  printf '\033[1;34m==>\033[0m %s\n' "$title"
  if ! "$@"; then failed="$failed $title;"; fi
}

# Files known to git (tracked and new, minus ignored): exactly what ends up in the repository
files() { git ls-files --cached --others --exclude-standard "$@" | while read -r f; do [ -f "$f" ] && echo "$f"; done; }

# Shell scripts: *.sh, files with an sh/bash shebang, and files with a shellcheck shell= directive
SHELL_FILES=()
while read -r f; do
  case "$f" in
    *.sh) SHELL_FILES+=("$f") ;;
    *) head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*(/|env )(ba)?sh( |$)|^# shellcheck shell=' && SHELL_FILES+=("$f") ;;
  esac
done < <(files)
WORKFLOWS=(); while read -r f; do WORKFLOWS+=("$f"); done < <(files '.github/workflows/*.yml' '.github/workflows/*.yaml')
DOCKERFILES=(); while read -r f; do DOCKERFILES+=("$f"); done < <(files 'Dockerfile' '*/Dockerfile' '*.Dockerfile')
NON_MD=(); while read -r f; do case "$f" in *.md) ;; *) NON_MD+=("$f") ;; esac; done < <(files)

# Unit tests (bats-core): test/*.bats, with fakes for docker and ssh on PATH
unit_tests() {
  command -v bats >/dev/null 2>&1 || { echo "  bats is not installed: brew install bats-core" >&2; return 1; }
  local out
  out="$(bats test 2>&1)" || { printf "%s\n" "$out"; return 1; }
}

# Secrets: in the pre-commit hook the staged changes (FNKC_PRE_COMMIT=1), otherwise the whole history. In Docker the
# repository and git's common directory are mounted at their own paths, so worktrees resolve too.
secrets() {
  local args=(git --no-banner --redact --exit-code 1)
  [ -n "${FNKC_PRE_COMMIT:-}" ] && args+=(--pre-commit --staged)
  if command -v gitleaks >/dev/null 2>&1; then
    gitleaks "${args[@]}" .
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local common
    common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
    docker run --rm -v "$PWD:$PWD:ro" -v "$common:$common:ro" -w "$PWD" \
      -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
      "$GITLEAKS_IMAGE" "${args[@]}" "$PWD"
  else
    echo "  gitleaks is not installed and Docker is not running: brew install gitleaks" >&2
    return 1
  fi
}

syntax() {
  local f rc=0
  for f in "${SHELL_FILES[@]}"; do
    if head -n 1 "$f" | grep -qE 'bash|shell=bash'; then bash -n "$f" || rc=1; else sh -n "$f" || rc=1; fi
  done
  return $rc
}

# Code, configs and comments are English only; Markdown documents may be in any language.
# Binary files (images etc., as grep -I sees them) are skipped. END sets $? only when the
# scan found something, so a perl error (e.g. invalid UTF-8) still fails the check.
english_only() {
  local text=()
  while IFS= read -r f; do text+=("$f"); done < <(grep -Il '' "$@")
  [ ${#text[@]} -eq 0 ] && return 0
  perl -CSD -ne 'if (/\p{Cyrillic}/) { print "$ARGV:$.: $_"; $bad = 1 } close ARGV if eof; END { $? = 1 if $bad && !$? }' "${text[@]}"
}

[ ${#SHELL_FILES[@]} -eq 0 ] || check "shell syntax (${#SHELL_FILES[@]})" syntax
[ ${#SHELL_FILES[@]} -eq 0 ] || check "shellcheck" tool shellcheck "$SHELLCHECK_IMAGE" -x -S warning "${SHELL_FILES[@]}"
[ ${#WORKFLOWS[@]} -eq 0 ]   || check "actionlint (${#WORKFLOWS[@]})" tool actionlint "$ACTIONLINT_IMAGE" "${WORKFLOWS[@]}"
[ ${#DOCKERFILES[@]} -eq 0 ] || check "hadolint (${#DOCKERFILES[@]})" tool hadolint "$HADOLINT_IMAGE" "${DOCKERFILES[@]}"
[ ${#NON_MD[@]} -eq 0 ]      || check "English only outside *.md (${#NON_MD[@]})" english_only "${NON_MD[@]}"
check "secrets (gitleaks)" secrets
compgen -G "test/*.bats" >/dev/null && check "unit tests (bats)" unit_tests

if [ -n "$failed" ]; then
  printf '\033[1;31mFailed checks:\033[0m%s\n' "$failed" >&2
  echo "Fix the issues above (to skip once: git commit --no-verify)" >&2
  exit 1
fi
printf '\033[1;32mAll checks passed\033[0m\n'
