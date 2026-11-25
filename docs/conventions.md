# Conventions

How the code is laid out and how to add a gateway request, an admin command or a test. The rules behind it:
[CLAUDE.md](../CLAUDE.md) «Bash rules» and [plan.md](plan.md) «Parallel work rules». The behaviour contract is
[spec.md](spec.md).

## Layout

| Path | What |
| --- | --- |
| `server/fnkc-ctl` | entry point on the host (`serve --user U` forced command, `admin …`) |
| `server/lib/` | sourced libraries: `core.sh` (below), then `grammar.sh`, `reply.sh`, `config.sh`, `names.sh`, `docker.sh`, `lock.sh`, … |
| `server/requests/<request>.sh` | one file per gateway request |
| `server/admin/<command>.sh` | one file per admin command |
| `container/` | scripts copied into project containers (entrypoint, idle watch, R profile) |
| `client/` | the bash `fnkc` (list, stop, doctor); runs on macOS, Linux and Git Bash |
| `extension/` | positron-remote's Positron extension under this repo's id (TypeScript, built in CI) |
| `test/helpers/` | bats setup, fake commands, the Linux test image |
| `test/server/`, `test/client/` | bats unit tests, `<topic>.bats` |
| `test/integration/` | `*.sh` fixtures against a disposable server container (CI only) |

## Every script

```bash
#!/usr/bin/env bash
source "$FNKC_LIB/core.sh" # strict mode: set -euo pipefail, inherit_errexit
```

`server/lib/core.sh` provides:

- `log <priority> <message>`: one line to journald through `logger -t fnkc-ctl` (stderr if there is no `/dev/log`,
  `logger` fails or `FNKC_LOG=stderr`); priorities `debug info notice warning err crit`. Control characters in the
  message become `?`, so input cannot forge log lines.
- `die <message>` / `die_status <n> <message>`: `fnkc-ctl: <message>` on stderr, logged at `err`, exit 1 or `n`.
  Gateway requests answer with the JSON error envelope from `reply.sh` instead; `die` is for internal failures and
  admin commands.
- `is_match <pattern> <value> [max]`, `require_match <what> <pattern> <value> [max]`, `is_uint <value>`. The pattern
  is anchored for you (`^(pattern)$`) and matched with `LC_ALL=C`. Whatever the pattern, a value is refused if it is
  empty, starts with `-`, contains a control character or is longer than `max` bytes (default 256).
  `require_match` dies with `invalid <what>` and never echoes the value.

Untrusted input (gateway arguments, file names, Docker output) passes a validator before any use, stays in quoted
variables and arrays, and goes after `--` (or as an explicit option value) to every command: `docker … -- "$name"`,
`git … -- "$path"`, `jq --arg v "$value"`. No `eval`, no `bash -c` or `jq` programs built from input.

## Adding a gateway request

`server/fnkc-ctl serve` (forced command) runs under a clean environment it builds itself, parses
`SSH_ORIGINAL_COMMAND`, checks the words against `server/lib/grammar.sh`, rechecks the user's key, reads a bounded
JSON stdin where the grammar says so, then runs `server/requests/<request>.sh` as its own bash process and writes the
reply (`server/lib/reply.sh`) and the journal line (`server/lib/journal.sh`). A request file only does its own work:

1. Its row in `docs/spec.md` (argv, stdin, reply, errors) must exist. `grammar.sh` already lists every request with
   its argument kinds, stdin mode and value patterns; if yours is missing, that is a separate small task.
2. Create `server/requests/<request>.sh` starting with `source "$FNKC_LIB/request.sh"` (its header lists the
   variables you get: `FNKC_USER`, `FNKC_KEYS_DIR`, `FNKC_STDIN_FILE`, …). `"$@"` are the validated words
   (a repository without its trailing `/`); validate anything else you read (stdin JSON via `jq`, Docker output,
   with `grammar_value <kind> <value>` for the spec's patterns).
3. Result: one JSON value on stdout, written with `jq`, exit 0. Refusal: `fail <message>`, `fail_code <code>
   <message>`, `fail_image_missing <message> <image> <arch>` or `fail_checkout_pins <message> <image>`; they work
   inside subshells too. Any other failure answers `internal error`. `info`/`warn` write progress to stderr;
   `journal_set <key> <value>` adds fields to the journal line.
4. Capabilities the request adds: one line `# fnkc-capabilities: <name> …` in the file; `ping` collects them, so
   a host advertises a capability only when its file is installed.
5. Add `test/server/<request>.bats` (below) and mark the spec rows done.

## Adding an admin command

Same pattern: `server/admin/<command>.sh`, run by `fnkc-ctl admin <command>` (the admin dispatcher comes in R18;
until then test the file directly). Admin commands run as root on the host: validate arguments with `require_match`,
use `die` for refusals, `log` for what changed.

## Adding a test

One file per task: `test/<area>/<topic>.bats`. CI and `lint.sh` discover `test/**/*.bats` and
`test/integration/*.sh`; nothing is listed anywhere.

```bash
setup() {
  load '../helpers/common'
  setup_fakes # fake docker, ssh, gh first on PATH; add names to fake more (e.g. logger)
}

@test "start refuses a container that is not the user's" {
  fake_reply -o '[{"Config":{"Labels":{}}}]' -- docker container inspect
  fake_reply -s 1 -e 'Error: No such container' -- docker container inspect missing
  run "$REPO_ROOT/server/requests/start.sh" …
  assert_status 1
  refute_called docker rm
}
```

- A fake answers from the deepest scenario directory `$FAKE_DIR/<cmd>/<word>/<word>…` matching its argv: files
  `stdout`, `stderr`, `status`, an executable `run`, and `.N` variants for the Nth call (polling, retries). Calls with
  no scenario exit 99, so unexpected commands fail the test. Details: the header of `test/helpers/fake-command`.
- Every call is logged to `$FAKE_DIR/calls.log`, one shell-quoted line each: `assert_called docker rm -f -- name`,
  `refute_called docker`, `fake_calls ssh`.
- Use `refute cmd` instead of `! cmd` (bats ignores `!` except on a test's last line); `assert_status`,
  `assert_output_contains` after `run`.
- Inject failures through the fakes (`fake_reply -s 1 …`) and check they surface; refuse hostile input before any
  `docker` call (`refute_called docker`).
- Tests add scenarios; they never edit the fakes or `test/helpers/`.
- Through the gateway: `load '../helpers/gateway'`, `setup_gateway` (a copy of `server/` in `$GW`, user `alice`
  with a key), `run --separate-stderr gateway 'agent <request> …'`, `stub_request <request> <body>` for a request
  file in the copy, `journal_lines` for what went to `logger`. serve drops the caller's environment, so the fakes
  reach it through `serve --path` (an admin/test option a client cannot set), never through `PATH`.

`./lint.sh` runs the server tests in a pinned Linux container (`test/helpers/Dockerfile`: bash 5, flock, GNU tar,
jq, git, bats), natively on a Linux machine with bats and flock; client tests run natively when bats is installed.
One file while iterating: `bats test/server/core.bats` on Linux, or
`docker run --rm -v "$PWD:/repo:ro" fnkc-sh-test:<tag> test/server/core.bats` after a first `./lint.sh`.

## CI

`.github/workflows/ci.yml` runs on every PR and push to main and finds its work in the tree, so tasks never edit it:

- `lint`: `./lint.sh` on Ubuntu with bats (pinned) and flock installed, so the server tests run natively.
- `integration (<script>)`: one job per tracked `test/integration/*.sh`, run as `bash <script>` from the repository
  root on the runner's Docker. The script starts and removes its own disposable containers and exits non-zero on
  failure.
- `extension`: only when `extension/package.json` is tracked. It needs `extension/.nvmrc` (the exact Node version),
  `extension/package-lock.json` and the npm scripts `typecheck`, `test` and `package`; `package` writes
  `extension/dist/*.vsix`, kept as the `vsix` artifact.
- `client-windows`: when `test/client/*.bats` exist, runs them with bats under Git Bash on Windows (LF checkout).
