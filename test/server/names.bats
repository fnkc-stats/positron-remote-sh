#!/usr/bin/env bats
# server/lib/names.sh: names, labels, user/project validation, the ownership predicate.

setup() {
  load '../helpers/common'
  setup_fakes
  export FNKC_LOG=stderr
}

# call <function> [arg...]: run a names.sh function in a fresh strict-mode bash, as a server script would.
call() {
  bash -c 'source "$FNKC_LIB/names.sh"; "$@"' call "$@"
}

C=0123456789abcdef0123456789abcdef01234567

# obj <kind> <name> <labels-json>: inspect output (array of one) for a container, volume or network.
obj() {
  if [[ "$1" == container ]]; then
    jq -cn --arg n "/$2" --argjson l "$3" '[{Name: $n, Config: {Labels: $l}}]'
  else
    jq -cn --arg n "$2" --argjson l "$3" '[{Name: $n, Labels: $l}]'
  fi
}

labels() { # labels <user> <project> [extra-json]
  jq -cn --arg u "$1" --arg p "$2" --argjson x "${3:-{\}}" \
    '{"fnkcsh.managed": "1", "fnkcsh.user": $u, "fnkcsh.project": $p} + $x'
}

@test "names follow docs/spec.md" {
  [ "$(call project_container alice thesis)" = fnkcsh-alice-thesis ]
  [ "$(call project_volume alice thesis project)" = fnkcsh-alice-thesis-project ]
  [ "$(call project_volume alice thesis data)" = fnkcsh-alice-thesis-data ]
  [ "$(call project_volume alice thesis library)" = fnkcsh-alice-thesis-library ]
  [ "$(call project_network alice thesis)" = fnkcsh-alice-thesis-net ]
  [ "$(call extensions_volume alice thesis arm64 "$C")" = fnkcsh-ext-alice-thesis-arm64-0123456789ab ]
  [ "$(call recovery_container alice a.b)" = fnkcsh.recovery.alice.a.b ]
  [ "$(call helper_container read alice a.b 0123456789ab)" = fnkcsh.read.alice.a.b.0123456789ab ]
  # shellcheck disable=SC2016 # expanded by the inner bash
  [ "$(bash -c 'source "$FNKC_LIB/names.sh"; echo "$LABEL_MANAGED $LABEL_USER $LABEL_PROJECT $LABEL_RESTORE $HELPER_LABEL_KIND"')" = \
    "fnkcsh.managed fnkcsh.user fnkcsh.project fnkcsh.restore fnkcsh.helper" ]
}

@test "user and project validation as validate.ts" {
  call is_user a
  call is_user a1234567890123456789012345678901
  refute call is_user a12345678901234567890123456789012
  local bad
  for bad in '' A 1a a-b a.b a_b 'a b' -a $'a\n' "$(printf '\xd0\xb0')" fnkc-x; do refute call is_user "$bad"; done
  call is_project a
  call is_project 9.x_y-z
  call is_project "a$(printf 'b%.0s' {1..62})"
  refute call is_project "a$(printf 'b%.0s' {1..63})"
  for bad in '' .a -a _a 'a b' 'a/b' '../x' 'a;b' '$(id)' $'a\nb' "$(printf 'th\xd0\xb5sis')"; do refute call is_project "$bad"; done
}

@test "check_user and check_project die with validate.ts wording" {
  run call check_user 'Bob'
  assert_status 1
  assert_output_contains "invalid user name: 'Bob' (lowercase letters and digits, starting with a letter)"
  run call check_project '../x'
  assert_status 1
  assert_output_contains "invalid project name: '../x'"
}

@test "name functions refuse bad input instead of building a name" {
  run call project_container alice '../x'
  assert_status 1
  run call project_container 'a-b' x
  assert_status 1
  run call project_volume alice x ext
  assert_status 1
  run call extensions_volume alice x amd64 "$C"
  assert_status 1
  run call extensions_volume alice x x64 0123
  assert_status 1
  run call helper_container write alice x 0123456789ab
  assert_status 1
  run call helper_container read alice x 0123456789AB
  assert_status 1
  # a die inside "$(...)" stops the caller
  run bash -c 'source "$FNKC_LIB/names.sh"; n="$(project_container alice ../x)"; echo "reached $n"'
  assert_status 1
  [[ "$output" != *reached* ]]
}

@test "names never collide with positron-remote's" {
  local n
  for n in "$(call project_container alice x)" "$(call project_volume alice x data)" "$(call project_network alice x)" \
    "$(call extensions_volume alice x x64 "$C")"; do
    [[ "$n" == fnkcsh-* && "$n" != fnkc-* ]]
  done
  for n in "$(call recovery_container alice x)" "$(call helper_container ext alice x 0123456789ab)"; do
    [[ "$n" == fnkcsh.* && "$n" != fnkc.* ]]
  done
  # positron-remote's objects for the same user and project are not ours
  refute call is_project_object_name container alice x fnkc-alice-x
  refute call is_project_object_name container alice x fnkc.recovery.alice.x
  refute call is_project_object_name volume alice x fnkc-alice-x-project
  refute call is_project_object_name volume alice x "fnkc-ext-alice-x-x64-0123456789ab"
  refute call is_helper_of alice x fnkc.read.alice.x.0123456789ab
}

@test "is_helper_of: exact user and project, a.b never matches a" {
  call is_helper_of alice a fnkcsh.read.alice.a.0123456789ab
  call is_helper_of alice a fnkcsh.ext.alice.a.0123456789ab
  call is_helper_of alice a.b fnkcsh.read.alice.a.b.0123456789ab
  refute call is_helper_of alice a fnkcsh.read.alice.a.b.0123456789ab
  refute call is_helper_of alice a.b fnkcsh.read.alice.a.0123456789ab
  refute call is_helper_of alice a fnkcsh.read.alice.ab.0123456789ab
  refute call is_helper_of alice a fnkcsh.read.alicex.a.0123456789ab
  refute call is_helper_of ali ce.a fnkcsh.read.alice.a.0123456789ab
  refute call is_helper_of alice a fnkcsh.read.alice.a.0123456789a
  refute call is_helper_of alice a fnkcsh.read.alice.a.0123456789abc
  refute call is_helper_of alice a fnkcsh.write.alice.a.0123456789ab
  refute call is_helper_of alice a fnkcsh.recovery.alice.a
  refute call is_helper_of alice a fnkcsh-alice-a
  # regex metacharacters in the project are literal: "a.b" does not match "aXb"
  refute call is_helper_of alice a.b fnkcsh.read.alice.aXb.0123456789ab
}

@test "is_project_object_name: only the computed names, per kind" {
  call is_project_object_name container alice a fnkcsh-alice-a
  call is_project_object_name container alice a fnkcsh.recovery.alice.a
  call is_project_object_name network alice a fnkcsh-alice-a-net
  call is_project_object_name volume alice a fnkcsh-alice-a-data
  call is_project_object_name volume alice a fnkcsh-ext-alice-a-arm64-0123456789ab
  refute call is_project_object_name container alice a fnkcsh-alice-a-net
  refute call is_project_object_name volume alice a fnkcsh-alice-a
  refute call is_project_object_name network alice a fnkcsh-alice-a
  refute call is_project_object_name volume alice a fnkcsh-alice-a.b-data
  refute call is_project_object_name volume alice a fnkcsh-ext-alice-a.b-x64-0123456789ab
  refute call is_project_object_name volume alice a fnkcsh-ext-alice-a-x64-0123456789ab-x64-0123456789ab
  refute call is_project_object_name volume alice a fnkcsh-ext-alice-a-x86-0123456789ab
  refute call is_project_object_name volume alice a.b fnkcsh-alice-aXb-data
  refute call is_project_object_name image alice a fnkcsh-alice-a
}

@test "is_owned: labels and name must both match" {
  call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels alice a)")"
  call is_owned volume alice a "$(obj volume fnkcsh-alice-a-project "$(labels alice a)")"
  call is_owned network alice a "$(obj network fnkcsh-alice-a-net "$(labels alice a)")"
  # one object rather than an array of one is fine too
  call is_owned volume alice a "$(obj volume fnkcsh-alice-a-data "$(labels alice a)" | jq -c '.[0]')"
}

@test "is_owned: label spoofing and name collisions are refused" {
  # B's labels on A's name, and A's labels on B's name
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels bob a)")"
  refute call is_owned container alice a "$(obj container fnkcsh-bob-a "$(labels alice a)")"
  # project a vs a.b, both ways
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a.b "$(labels alice a)")"
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels alice a.b)")"
  refute call is_owned volume alice a "$(obj volume fnkcsh-alice-a.b-data "$(labels alice a.b)")"
  # not managed, managed by another value, missing labels, labels of the wrong type
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a '{"fnkcsh.user":"alice","fnkcsh.project":"a"}')"
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels alice a '{"fnkcsh.managed":"true"}')")"
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a null)"
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a '{"fnkcsh.managed":1,"fnkcsh.user":"alice","fnkcsh.project":"a"}')"
  # labels with a trailing newline or quotes are not the user
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels $'alice\n' a)")"
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a "$(labels 'alice"' a)")"
  # positron-remote's labels and names
  refute call is_owned container alice a "$(obj container fnkcsh-alice-a '{"fnkc.managed":"1","fnkc.user":"alice","fnkc.project":"a"}')"
  refute call is_owned container alice a "$(obj container fnkc-alice-a "$(labels alice a)")"
  # a restored archive is never the project's volume, whatever its name and labels
  refute call is_owned volume alice a "$(obj volume fnkcsh-alice-a-data "$(labels alice a '{"fnkcsh.restore":""}')")"
  # labels in the wrong place for the kind: a container's top-level Labels are not read
  refute call is_owned container alice a "$(jq -cn --argjson l "$(labels alice a)" '[{Name: "/fnkcsh-alice-a", Labels: $l}]')"
  # garbage and empty input
  refute call is_owned container alice a 'not json'
  refute call is_owned container alice a '[]'
  refute call is_owned container alice a ''
  refute call is_owned container 'Alice' a "$(obj container fnkcsh-Alice-a "$(labels Alice a)")"
}
