#!/usr/bin/env bats
# server/lib/journal.sh: formatLine (src/journal.ts) and the logger call.

setup() {
  load '../helpers/common'
  setup_fakes logger
  source "$FNKC_LIB/core.sh"
  source "$FNKC_LIB/journal.sh"
}

@test "journal_format: plain values bare, others JSON-quoted, empty ones left out" {
  run journal_format user alice empty '' error 'no such project' eq 'a=b' q 'say "hi"' bs 'a\b' nl $'a\nb' \
    u $'\xc3\xa9t\xc3\xa9' dash '-n' opt '--arg'
  [[ "$status" -eq 0 ]]
  [[ "$output" == 'user=alice error="no such project" eq="a=b" q="say \"hi\"" bs="a\\b" nl="a\nb" u="été" dash=-n opt=--arg' ]]
}

@test "journal_format: values over 1000 characters are cut with an ellipsis" {
  local long
  long="$(printf 'x%.0s' {1..1500})"
  run journal_format v "$long"
  [[ "$output" == "v=\"$(printf 'x%.0s' {1..1000})"$'\xe2\x80\xa6"' ]]
}

@test "journal_end: logger -t fnkc-ctl-sh, warning priority on failure; a failing logger loses only the line" {
  local d
  d="$(fake_dir logger)"
  printf '#!/bin/bash\nprintf "%%s|%%s|%%s|%%s\\n" "$2" "$4" "$5" "$6" >>"$FAKE_DIR/journal"\nexit 1\n' >"$d/run"
  chmod +x "$d/run"
  # shellcheck disable=SC2034 # read by journal_end
  FNKC_VERSION=1.2.3
  journal_begin "$BATS_TEST_TMPDIR"
  journal_set user alice command ping user bob
  journal_end error busy 'project p is busy'
  [[ "$(<"$FAKE_DIR/journal")" =~ ^'fnkc-ctl-sh|user.warning|--|user=bob command=ping ms='[0-9]+' result=error code=busy error="project p is busy" ctl=1.2.3'$ ]]
  # only the first journal_end writes
  journal_end ok
  [[ "$(fake_calls logger | wc -l)" -eq 1 ]]
}
