# Spec: the contract of positron-remote-sh

The contract every rewrite task builds against. Source of behaviour: positron-remote @ 9ff6fca (`src/` below means
its `ctl/src/`, `ctl/` its `ctl/`) and the frozen docs in [reference/](../reference/). Decisions in
[plan.md](plan.md#decisions-user-2026-11-24) are final; this file only fills in what they leave open.

Rules for this file:

- Messages are not repeated here: port the wording from the cited source line. What clients act on is the `code`,
  never the text ([errors](#error-codes)).
- Each task marks only its own rows: change `Status` from `todo` to `done (#PR)`, or to `changed (#PR): why`.
- A row marked **open** is a question for the user; its task must not guess the answer
  ([open questions](#open-questions)).

## Open questions

None in this list; a few rows below are still marked **open** in their own tables.

Answered:

- **Q-S1** (host paths and account; user, 2026-11-24, option a): own names, distinct from positron-remote's
  (`fnkc`, `/opt/fnkc-ctl`, `/etc/fnkc-ctl`, tag and marker `fnkc-ctl`) so both run on one pilot host (Decision 4):
  account `fnkcsh`, install prefix `/opt/fnkc-ctl-sh`, configuration `/etc/fnkc-ctl-sh`, journal tag `fnkc-ctl-sh`,
  `authorized_keys` marker `fnkc-ctl-sh:<user>`. The program is still `fnkc-ctl` (Decision 6), inside that prefix.
  See [plan.md](plan.md#decisions-user-2026-11-24), decision 8.

## Wire contract

Source: `src/cli.ts` (`serve`), `src/serve.ts`, `src/protocol.ts`, `src/errors.ts`, `src/validate.ts`,
`src/repository.ts`, `src/image-store.ts`. The extension's `SshTransport` is the client, unchanged except for its
identity (R24), so every shape below is exact.

### Entry

`authorized_keys` (written by `admin add-user`, R18), one line per user:

```
command="/opt/fnkc-ctl-sh/fnkc-ctl serve --user <user>",restrict <key type> <key data> fnkc-ctl-sh:<user>
```

`fnkc-ctl serve --user <user> [--agent-config <file>]`:

1. Clears the environment (keeps nothing it did not set itself: `PATH`, `LANG`, `IFS`, `BASH_ENV`, `ENV` are reset
   before any other code runs; it reads only `SSH_ORIGINAL_COMMAND` and `SSH_CONNECTION`). *Changed:* new hardening.
   `$FNKC_CTL_AGENT_CONFIG` is *dropped*; `--agent-config` stays for admins and tests.
2. Reads the config (`agent.json`); `keysDir` unset → stderr `server mode requires keysDir`, exit 1.
3. Parses `SSH_ORIGINAL_COMMAND` as `parseCommand`: split on whitespace, drop a leading `fnkc-ctl`, the next word
   must be `agent`, the rest are the request words. Otherwise stderr `Error: unsupported command: …`, exit 1, no
   JSON reply (as positron-remote: the failure happens before a request exists).
4. Rechecks the user's key on every request (`<keysDir>/<user>.pub` exists and is a valid key, `authorized()` in
   `src/agent.ts`): a revoked user's open SSH transport gets nothing more.
5. Runs the request, writes one [reply](#reply-envelope) line to stdout, one [journal line](#journal), exits 0 (ok)
   or 1 (error). Progress messages go to stderr.

Errors outside a request (bad `serve` arguments, unreadable config) print `Error: <message>` on stderr, exit 1.

### Requests

Words after `agent`; arguments are validated by the regexes in [arguments](#argument-rules) before any Docker call.
A word count other than the one listed → error `too many arguments` or `<request>: …` (wording from
`src/serve.ts`), without a code. An unknown first word → code `unknown-command`.

| Request | argv | stdin | Result (`result` field) | Codes | Source | Task |
| --- | --- | --- | --- | --- | --- | --- |
| `ping` | none | ignored | [`PingResult`](#protocol-and-capabilities) | — | `agent.ts` `ping` | R3 |
| `list` | none | ignored | `ContainerInfo[]` | — | `agent.ts` `list`, `idleState` | R8 |
| `images` | none | ignored | `HostImage[]` | — | `agent.ts` `images` | R14 |
| `start` | none | JSON [`StartRequest`](#startrequest), ≤ 2 MiB, read within 10 s | `StartResult` | image-missing, checkout-pins, quota, capacity, busy, provenance-refused, replacement-not-ready | `agent.ts` `startLocked` | R11, R12 |
| `stop` | `<project>` | ignored | `StopResult` | busy | `agent.ts` `stop` | R13 |
| `stop` | `<project> <repository>` (qualified-stop-v1) | ignored | `StopResult`, `outcome: other-repository` when the container belongs to another repository | busy | `agent.ts` `stop` | R13 |
| `busy` | `<project>` | ignored | `BusyProcess[]` (`[]` if not running) | — | `agent.ts` `busy`, `parseBusy` | R13 |
| `keep` | `<project>` | ignored | `{ "until": "<ISO time>" }` (now + 3 days); not running → error | busy | `agent.ts` `keep` | R13 |
| `checkout` | `<project>` | ignored | `CheckoutState` | — | `agent.ts` `checkout` | R13 |
| `remove-check` | `<project>` | ignored | `RemovalCheck` | busy | `agent.ts` `removalCheck`, `removal-inspection.ts` | R17 |
| `remove` | `<project> <fingerprint>` | ignored | `{ "removed": ["<name>", …] }` | busy | `agent.ts` `remove` | R17 |
| `install-image` | `<image>` | [upload stream](#install-image-stream) | `{ "installed": true }` | image-rejected, busy | `agent.ts` `installImage`, `image-store.ts` | R15 |
| `connect` | `<project>` | raw SSH stream | none: [raw stream](#connect) | — | `cli.ts` `serve`, `agent.ts` `connectProject` | R7 |

Result types are the TypeScript interfaces in `src/protocol.ts`, field for field (names, optionality, types);
optional fields are left out, never `null`. R3's tests check the envelope; each request's task checks its result
against the interface.

### Argument rules

Anchored regexes, from `src/validate.ts` and `src/repository.ts`. In bash: `[[ $v =~ $re ]]` with the regex in a
variable, after checking the value has no newline or NUL.

| Value | Regex | Extra rule |
| --- | --- | --- |
| project | `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` | — |
| user (`--user`, admin) | `^[a-z][a-z0-9]{0,31}$` | letters and digits only, so `<prefix>-<user>-` never overlaps another user |
| fingerprint | `^[0-9a-f]{64}$` | — |
| image | `^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$` | its repository (before `@`, minus a `:tag`) must be in `allowedImages` |
| repository | `^(ssh://([A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+(:[0-9]+)?/\|https://[A-Za-z0-9.-]+(:[0-9]+)?/\|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)[A-Za-z0-9_./-]+$` | no `..` path segment; trailing `/` removed |
| Positron version | `^[0-9]{4}\.[0-9]{2}\.[0-9]+-[0-9]+$` | — |
| commit (revision, Positron commit) | `^[0-9a-f]{40}$` | — |
| SSH public key | `^(ssh-ed25519\|ssh-rsa\|ecdsa-sha2-nistp(256\|384\|521)\|sk-ssh-ed25519@openssh\.com\|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$` | trimmed first |

(`\|` above is a table escape for `|`.)

### StartRequest

One JSON object on stdin (`src/protocol.ts` `StartRequest`), checked with `jq` (types first, then the regexes):
`project`, `repository`, `revision` (commit), `image` (pinned image), `positron.version`, `positron.commit` required;
`sshPublicKey` ignored on a server; `positronImage.image` (pinned image), `provenanceBundle`, `provenanceSubject`
(base64), `client` (journal only), `discardReplacement` (boolean) optional; unknown fields ignored (newer clients).
The project must equal the repository's name (`repositoryName`: last path part without `.git`).

### Reply envelope

One line of JSON on stdout, written with `jq -n --arg`/`--argjson` (`src/serve.ts` `answer`):

```
{"ok":true,"result":<result>}
{"ok":false,"error":"<message>","code":"<code>","imageMissing":{"image":"<image>","arch":"x64|arm64"},"checkoutPins":"<image>"}
```

`code`, `imageMissing` and `checkoutPins` appear only where they apply: `imageMissing` with code `image-missing`,
`checkoutPins` with code `checkout-pins`. Exit status 0 for ok, 1 for an error.

### Error codes

From `src/errors.ts`; the complete list (a new one is its own task).

| Code | When | Task |
| --- | --- | --- |
| `image-missing` | start: the pinned image is not on the host (or its upload tag cannot be trusted); reply carries `imageMissing` | R11, R14 |
| `checkout-pins` | start: the existing checkout pins another image; reply carries `checkoutPins` | R11 |
| `quota` | start: the user's own limits (`maxProjectsPerUser`, `maxMemoryPerUser`) | R10 |
| `capacity` | start: the host's limits (`reserveMemory`, `maxProjectsPerUser: 0`) | R10 |
| `busy` | a lock was not free in time | R6 |
| `incompatible` | client and host cannot work together (client side only; the server never sends it) | R23 |
| `unknown-command` | first request word unknown, or its request file missing | R3 |
| `image-rejected` | install-image: content does not match digest, size, architecture or bounds | R15 |
| `provenance-refused` | start: the image's attestation did not verify | R16 |
| `replacement-not-ready` | start: a replacement container runs but fails readiness (discard-replacement-v1) | R12 |

### Protocol and capabilities

`ping` answers `PingResult`: `version` (this release), `protocol: 1`, `minProtocol: 1`, `capabilities`, `user`,
`requiresProvenance`, and `trustRootRefreshed` (mtime of `trustedRootFile`, ISO) when provenance is required.

| Capability | Required by the extension | Behaviour | Task |
| --- | --- | --- | --- |
| `content-removal-v1` | yes | remove-check / remove with fingerprint | R17 |
| `explicit-snapshot-v1` | yes | container scripts: renv snapshot only when asked (`snapshot.R`) | R9, R11 |
| `project-locks-v1` | yes | per-project locks, `busy` code | R6, R11 |
| `resumable-init-v1` | yes | start resumes an interrupted clone/init | R11 |
| `image-provenance-v1` | yes | provenance on start, `requiresProvenance` in ping | R16 |
| `long-running-v1` | yes | `busy`, `keep`, idle notice fields in `list` | R13 |
| `checkout-query-v1` | no | `checkout` | R13 |
| `qualified-stop-v1` | no | `stop <project> <repository>` | R13 |
| `discard-replacement-v1` | no | `StartRequest.discardReplacement` | R12 |

The meanings of the first five are inferred from the behaviour (positron-remote names them only in
`src/protocol.ts`). `ping` advertises a capability only once its task has merged; the extension refuses a host
missing a required one, which is expected until all are in.

### install-image stream

Raw stdin (`src/image-store.ts` header): parts, each `<size in bytes>\n` then that many bytes, in order: the
manifest or index the pinned digest names; for an index, the manifest for the host's architecture; the config; each
distinct layer in manifest order. Each part is checked against its digest and size before the next is read. Bounds
(reference/lifecycle.md «Upload and storage bounds»): manifest ≤ 4 MiB, compressed image ≤ 32 GiB,
`maxUnpackedImage`, `maxImageStorage`, `imageReserve`; 60 s idle and 4 h overall read deadlines; one upload at a time
(lock `image-upload`, others wait up to 1 h and say so on stderr). An image already present answers
`{"installed":true}` without reading the stream.

### connect

`agent connect <project>`: no JSON reply. Refused (stderr message, exit 1) unless the user's own container of that
project runs and, with `requireProvenance`, carries the current verified-image mark (`fnkcsh.provenance` equal to
`<FNKC_IMAGE_DIGEST>|<provenanceRepository>|<provenanceWorkflow>`). Then stdin/stdout carry the container's sshd.
The user's key is rechecked every 5 s; when it is gone or changed, the stream ends.

*Changed* (plan «What changes», R7 confirms): `docker exec -i <container> /usr/sbin/sshd -i` instead of piping to
the published port. If R7 keeps that, containers publish no port and `StartResult.sshPort` / `ContainerInfo.sshPort`
are `22` (the extension writes it into its SSH entry, but the ProxyCommand carries the stream); otherwise they stay
the published port on `127.0.0.1`.

### Journal

One line per request and per admin command through `logger -t fnkc-ctl-sh -p user.info` (failures `user.warning`):
`key=value` pairs (`src/journal.ts` `formatLine`: values with spaces, quotes, `=` or non-printable characters are
JSON-quoted, at most 1000 characters). Fields: `user`, `from` (first word of `SSH_CONNECTION`), `command`,
`project` or `image`, for `start` also `revision`, `image`, `positron`, `client`, `running`, `created`,
`updatePending`; then `ms`, `result` (`ok`/`error`), `code`, `error`, `warnings` (joined by ` | `), `ctl` (version).
Admin lines: `command=admin-<sub>`, `by` (`$SUDO_USER`), and the fields `src/cli.ts` sets per command. A host
without `logger` loses the line, never the request. Task: R3 (requests), R18 (admin).

## Names

Decision 4: distinct from positron-remote's `fnkc` names so both run on one host. Prefix: **`fnkcsh`**. Every
positron-remote name starts `fnkc-` or `fnkc.`; `fnkcsh-` and `fnkcsh.` never equal one of them (the fifth character
differs), and positron-remote's exact label keys (`fnkc.user`, …) never match ours. Source: `src/layout.ts`.

| Object | Name | Source | Task |
| --- | --- | --- | --- |
| project container | `fnkcsh-<user>-<project>` | `projectNames` | R5 |
| project volumes | `fnkcsh-<user>-<project>-project`, `-data`, `-library` | `projectNames` | R5 |
| extensions volume | `fnkcsh-ext-<user>-<project>-<arch>-<commit[0:12]>` (`arch`: `x64`/`arm64`) | `extensionsVolume` | R5 |
| network | `fnkcsh-<user>-<project>-net` | `agent.ts` | R5 |
| recovery container | `fnkcsh.recovery.<user>.<project>` | `recoveryName` | R5 |
| helper container | `fnkcsh.<read\|ext>.<user>.<project>.<12 hex>`; matched only by the anchored pattern of `helperPattern` | `helperName` | R5 |
| labels on containers, volumes, network | `fnkcsh.managed=1`, `fnkcsh.user`, `fnkcsh.project`, `fnkcsh.repository`, `fnkcsh.revision`, `fnkcsh.setup`, `fnkcsh.provenance` | `LABEL` | R5 |
| restored-archive volume label | `fnkcsh.restore` (never read, mounted or deleted as a project's) | `LABEL.restore` | R5, R22 |
| helper labels | `fnkcsh.helper=<kind>`, `fnkcsh.helper.user`, `fnkcsh.helper.project` | `HELPER_LABEL` | R5 |
| locks (files in `lockDir`) | `host`, `project-<user>-<project>`, `image-upload`, `image-store` | `agent.ts`, `cli.ts` | R6 |
| upload tag | `<repository>:sha256-<hex>` (kept: content-addressed, so sharing it with positron-remote is harmless; the moved-tag check compares it with our own record) | `oci.ts` `uploadedTag` | R14, R15 |
| loaded-image record | `<imageStagingDir>/loaded/<digest hex>` holding `sha256:<64 hex>` | `image-store.ts` `loadedRecord` | R14, R15 |

Ownership (R5, done: `is_owned` in `server/lib/names.sh`, `own_object`/`find_owned` in `server/lib/docker.sh`): an object is the user's project object only when `fnkcsh.managed=1`, `fnkcsh.user=<user>`,
`fnkcsh.project=<project>` **and** its name is the one computed above (`isProjectContainer`, `own`). Anything else
under the name → refused (`refusing container not owned by this user/project`).

Kept unchanged, because they live inside a container or an image: container user `analyst`, `/home/analyst`,
`~/.positron-server`, `~/.fnkc-library`, `/run/fnkc-{keep,idle,sshd}`, `FNKC_*` environment variables, image labels
`positron.*` and `r-env.*` (set by positron-remote's image builds).

## agent.json

`/etc/fnkc-ctl-sh/agent.json`, a JSON object; read with `jq` (R4). Unknown keys are ignored by the gateway and warned about by
`admin check-config` with a suggestion (edit distance, `unknownConfigKeys`). Source: `src/agent-config.ts`.

| Key | Default | Validation | Status |
| --- | --- | --- | --- |
| `allowedImages` | `["ghcr.io/fnkc-stats/r-env"]` | non-empty list of exact repositories, each `^[a-z0-9][a-z0-9._/:-]*[a-z0-9]$` | kept |
| `keysDir` | none (required by `serve`) | absolute path | changed (R4): absolute path; recommended `/etc/fnkc-ctl-sh/keys` |
| `limits.memory` | `4g` | `^[0-9]+[bkmgBKMG]?$`, > 0 | kept |
| `limits.cpus` | `2` | number or string `^[0-9]+(\.[0-9]+)?$`, > 0 | kept |
| `limits.pids` | `512` | positive integer | kept |
| `idleMinutes` | `0` (never) | integer ≥ 0 | kept |
| `skipExtensions` | `["ms-toolsai.","ms-python.debugpy","meta.pyrefly","charliermarsh.ruff","github.vscode-pull-request-github"]` | list of `^[A-Za-z0-9._-]+$` | kept |
| `idleCheckSeconds` | unset (60) | integer ≥ 0; 0 = unset; tests only | kept |
| `pullImages` | `false` | boolean | kept |
| `imageStagingDir` | `~/.cache/fnkc-ctl/images` of the account | absolute path | changed: no per-`docker` namespace; absolute path |
| `docker` | — | — | dropped: a command prefix for local Docker (WSL); the server runs `docker` |
| `lockDir` | `~/.cache/fnkc-ctl/locks` | absolute path | changed: no namespace; absolute path |
| `maxProjectsPerUser` | `2` | integer ≥ 0; 0 admits no starts | kept |
| `imageReserve` | `2g` | memory size | kept |
| `maxUnpackedImage` | `64g` | memory size | kept |
| `maxImageStorage` | `128g` | memory size | kept |
| `maxMemoryPerUser` | `16g` | memory size | kept |
| `reserveMemory` | `2g` | memory size | kept |
| `extraHosts` | `{}` | object: name `^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$` → IP `^[0-9A-Fa-f.:]+$` | kept |
| `cranMirror` | `https://mirror.truenetwork.ru/CRAN/` | `^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/$` | kept |
| `requireProvenance` | `true` when `keysDir` is set | boolean | kept |
| `provenanceRepository` | `fnkc-stats/positron-remote` | text | kept (images are built there) |
| `provenanceWorkflow` | `.github/workflows/positron.yml` | text | kept |
| `trustedRootFile` | `/etc/fnkc-ctl-sh/trusted-root.jsonl` | absolute path | changed: own directory (Q-S1); absolute path |
| `verifiedDir` | `~/.cache/fnkc-ctl/verified` | absolute path | changed: no namespace; absolute path |

"Memory size" is `checkLimit('memory')`: `^[0-9]+[bkmgBKMG]?$` and greater than 0. A wrong type or value fails the
request with `agent config: "<key>" must …` (wording from source; the memory sizes and `limits.cpus` name their key
instead of `checkLimit`'s `invalid memory limit: '<value>'`, which echoed the value).

Implemented in `server/lib/config.sh` (R4), done (#10): `config_load [file] [home]` sets readonly `CFG_*` variables and
arrays (list in the file's header). Changed from `agent-config.ts`, all stricter:

- "Absolute path": a string starting with `/`. "Text": non-empty, not starting with `-`. Every string has a length
  cap and no string may contain a control character, so each value is safe on one line and as a command argument.
- JSON `null` is a wrong type for every key (the source fell back to the default for some); `limits` must be an
  object; whole numbers stay below 2^53 (bash arithmetic).
- `docker` is not a setting any more, so `check-config` warns about it as an unknown key.
- Defaults under `~`: the gateway uses `$HOME` of the account it runs as; admin commands running as root pass the
  home of `--account` (default `fnkcsh`) from `getent passwd`.
- The file: `--agent-config <file>`, else `/etc/fnkc-ctl-sh/agent.json` if it exists, else all defaults. There is no
  environment variable for it (positron-remote's `FNKC_CTL_AGENT_CONFIG` is not read).

## Admin commands

`fnkc-ctl admin <sub> …` (`src/cli.ts` `admin`, `src/admin.ts`). Options everywhere: `--account <name>` (default
`fnkcsh`), `--agent-config <file>`. Root required, except `check-config` and `resolve-image`. Each mutating
command writes a journal line. Each is `server/admin/<sub>.sh`; the dispatcher (R18) answers a missing file with a
clear error.

| Command | What | Source | Task |
| --- | --- | --- | --- |
| `check-config [file]` | prints the settings in force with defaults (JSON, pretty); warns about unknown keys | `cli.ts` | R4 |
| `resolve-image <image>` | prints the verified local image ID of an allowed image (provenance if required, moved-tag check) | `host-image.ts` | R14 |
| `record-image <image>` | records the image ID of an image loaded before upload records, under lock `image-store`, only when a project container runs exactly that image | `image-store.ts` `recordExistingImage` | R14 |
| `add-user <name> <key file \| "key">` | writes `<keysDir>/<name>.pub` and the `authorized_keys` line, atomically (temp file, owner `fnkcsh`, mode 600), under lock `host`; replaces an existing line of that user | `admin.ts` `addUser` | R18 |
| `remove-user <name> [--lose-work]` | unpushed-work check of every project (refuses and exits 1 if any), then removes the key under lock `host`, then stops the user's running projects; volumes kept; `--lose-work` skips the check | `cli.ts`, `offboard.ts` | R18 (revoke), R19 (check) |
| `list-users` | users with a marked line in `authorized_keys` | `admin.ts` `listUsers` | R18 |
| `status [--sizes] [--json]` | every user's projects, host memory against limits, installed releases, restore volumes | `admin-status.ts` | R21 |
| `projects <user> [--sizes] [--json]` | the same for one user, also after remove-user | `admin-status.ts` | R21 |
| `remove-project <user> <project> [--delete] [--lose-work]` | removal report; `--delete` deletes unless work is not on Gitea (`--lose-work` anyway) | `cli.ts` | R19 (gap, see below) |
| `stop-all <user> \| --all-users [--yes]` | lists running projects, asks (`--yes` for scripts), stops each under its project lock | `cli.ts`, `agent.ts` `stopAll` | R19 (gap) |
| `support-export [--since <time>] [--identifiers] [--json]` | journal summary for a support ticket, identifiers left out unless asked | `journal.ts` | gap (no task yet) |

## Behaviour by area

Status: **kept** (same behaviour), **changed** (said how), **dropped** (said why). `Done` is marked by the task.

### Lifecycle

| Behaviour | Status | Source | Task | Done |
| --- | --- | --- | --- | --- |
| Forced command, `parseCommand`, 2 MiB / 10 s stdin cap, reply envelope, journal | kept; environment cleared first (changed) | `cli.ts`, `serve.ts`, `journal.ts` | R3 | todo |
| Key recheck on every request and during `connect` | kept | `agent.ts` `authorized`, `connectProject` | R3, R7 | todo |
| `connect` to the container's sshd | changed: `docker exec -i … sshd -i` (R7 confirms) | `agent.ts` `connectProject` | R7 | todo |
| `list` with memory and idle fields (`/run/fnkc-idle`) | kept | `agent.ts` `list`, `idleState` | R8 | todo |
| Container scripts (entrypoint, idle watch, `fnkc-projects`, R profile, snapshot, environment) | kept, Bash rules | `ctl/container/*` | R9 | todo |
| Create with hardening: capabilities `AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER KILL NET_BIND_SERVICE SETGID SETUID SYS_CHROOT` only, limits, own network, log rotation 10m×3, `--restart no`, read-only Positron server, extensions helper with `ext-owner-seccomp.json` | kept | `agent.ts` `createArgs`, `docker.ts`, `positron-server.ts`, `ctl/server/ext-owner-seccomp.json` | R10 | todo |
| Admission: `quota`, `capacity` under lock `host` | kept | `capacity.ts` | R10 | todo |
| Removal of the legacy `-ext` volume | dropped: clean start (Decision 4) | `layout.ts` | R10 | todo |
| Start: validate, create or start, readiness (30 checks, log tail 20 lines / 4000 chars) | kept | `agent.ts` `startLocked`, `ready` | R11 | todo |
| Update pending: never replace a running container (`updatePending: true`) | kept | `agent.ts` `connectPending` | R12 | todo |
| Recovery container, `replacement-not-ready`, `discardReplacement` | kept | `agent.ts` `startLocked` | R12 | todo |
| Rename of legacy `<container>-previous` | dropped: clean start | `agent.ts` `startLocked` | R12 | todo |
| Stop (90 s), qualified stop and outcomes, `busy`, `keep` (3 days), `checkout` | kept | `agent.ts` | R13 | todo |
| Locks with timeouts, lock order (reference/lifecycle.md «Lock ordering and availability») | changed: `flock` instead of Python `fcntl` | `lock.ts` | R6 | todo |

### Images

| Behaviour | Status | Source | Task | Done |
| --- | --- | --- | --- | --- |
| `allowedImages` exact repositories, digest pins | kept | `validate.ts` `checkImage`, `agent-config.ts` | R4, R14 | todo |
| Verified image IDs on classic and containerd stores, moved-tag refusal, loaded records | kept | `host-image.ts`, `image-store.ts` | R14 | todo |
| `images` request (other users' containers only counted) | kept | `agent.ts` `images` | R14 | todo |
| `pullImages` | kept, default `false` | `agent.ts` `environment` | R14 | todo |
| Upload verification (manifest, layers, architecture, tar bounds, staging cleanup) before `docker load` | kept | `image-store.ts`, `oci.ts`, `tar.ts` | R15 | todo |
| Provenance: offline `gh attestation verify --bundle … --custom-trusted-root`, `verifiedDir`, weekly trust-root refresh | kept (Decision 2) | `provenance.ts`, `ctl/server/refresh-trust-root.sh` | R16 | todo |
| `removeImage` (local Images panel) | dropped: local mode (never on the gateway) | `agent.ts` `removeImage` | — | — |

### Removal

| Behaviour | Status | Source | Task | Done |
| --- | --- | --- | --- | --- |
| `remove-check` report via the unchanged `REMOVAL_SCRIPT` in a `read` helper container | kept | `removal-inspection.ts` | R17 | todo |
| Fingerprint, recomputed under the project lock by `remove` | changed: sha256 of a canonical `jq -S` document (opaque 64 hex to the client, as before) | `agent.ts` `inspectRemoval`, `remove` | R17 | todo |
| Refuse restored-archive volumes, running projects, recovery containers; delete without `-f` | kept | `agent.ts` `refuseRestored`, `remove` | R17 | todo |
| Offboarding check before revocation, `--lose-work` | kept | `offboard.ts`, `cli.ts` | R19 | todo |

### Admin and install

| Behaviour | Status | Source | Task | Done |
| --- | --- | --- | --- | --- |
| `check-config` | kept; also `--account` for the defaults under `~` | `cli.ts`, `agent-config.ts` | R4 | done (#10) |
| `add-user`, `remove-user` (revoke and stop), `list-users` | kept; command line in `authorized_keys` without Node | `admin.ts`, `cli.ts` | R18 | todo |
| `status`, `projects` | kept | `admin-status.ts` | R21 | todo |
| `remove-project`, `stop-all`, `support-export` | kept | `cli.ts`, `journal.ts` | gap | todo |
| `install.sh`: releases with `MANIFEST`, one `current` link, rollback, switch recovery, installer lock | kept; checks bash ≥ 5, docker, OpenSSH, flock, GNU tar, jq, gh instead of Node | `ctl/server/install.sh` | R20 | todo |
| `volume-backup.sh`, `render-reviewed.py` | kept | `ctl/server/` | R22 | todo |
| Node runtime on the host | dropped (plan) | — | R20 | todo |

### Extension and client

| Behaviour | Status | Source | Task | Done |
| --- | --- | --- | --- | --- |
| Positron extension (sidebar, Images panel, Open/Stop/Delete, self-update) with `SshTransport` | kept | `extension.ts`, `sidebar.ts`, `images-view.ts`, `client/*` | R23 | todo |
| Gateway words `fnkc-ctl agent <request>` and the ProxyCommand `… fnkc-ctl agent connect <project>` | kept | `client/transport.ts`, `client/ssh.ts` | R23 | todo |
| `LocalTransport`, in-process `Agent`, local Docker mode | dropped in v1 (Decision 7) | `client/*`, `agent.ts` | R23 | todo |
| Node CLI `fnkc-ctl` on the client (`open`, `build`, `remove`, `images --cleanup`, `ssh-config`, …) | dropped; `list`, `stop`, `doctor` move to bash `fnkc` (Decision 6) | `cli.ts` | R25 | todo |
| Extension id, display name, `~/.ssh/fnkc` entry directory and Include marker, release and update URLs | changed: own values so it coexists with positron-remote's (Decisions 4, 7) | `package.json`, `client/ssh.ts`, `client/update.ts` | R24 | todo |
| Client locks through `python3` (`fcntl`) on macOS/Linux, PowerShell on Windows | **open**: the plan's client needs list no Python (see follow-up) | `lock.ts` | R23 | todo |
| Compatibility file (protocol and capabilities) for server-first upgrades | kept, published by the release | `cli.ts` `--version --json`, `client/update.ts` | R28 | todo |
