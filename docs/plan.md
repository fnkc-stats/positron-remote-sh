# Plan: positron-remote on plain SSH, bash and Docker

Goal: the same service as `fnkc-stats/positron-remote` (each project in its own container on a team server, opened
from Positron over SSH), with **no Node.js to install anywhere**: not on servers, not on analysts' or developers'
computers. The server side is bash + Docker + OpenSSH. The client is positron-remote's Positron extension, kept in
TypeScript (decision 7): it runs inside Positron's own bundled Node, and CI builds and tests it.

Source of truth for behaviour: `positron-remote` @ 9ff6fca, frozen copies of its docs in [reference/](../reference/).
Everything there that is not explicitly dropped below must keep working the same way.

## What stays the same

- Environment images: built, attested and published by `positron-remote` (`env/`, `image.yml`, `positron.yml`,
  `r-env`). This repo **consumes** them by digest and does not build images.
- Project layout: `container.json` pin in the repo root, project name = Gitea repo name, clone only inside the
  container, CRAN mirror `https://mirror.truenetwork.ru/CRAN/` in containers.
- Trust model: one SSH gateway account with a forced command; no Docker access for users; per-user ownership of every
  container, volume, network and lock; container hardening flags; read-only Positron server; host keys pinned over the
  control channel.
- Ops: releases under `/opt/fnkc-ctl-sh/releases/<version>-<checksum>` with `MANIFEST`, one `current` switch, rollback;
  backups (`volume-backup.sh`), `render-reviewed.py`; server-first upgrades.
- Process: one branch per change, `./lint.sh`, PRs merged after green CI, audit plans, the review checklists in
  `.claude/agents/`.

## What changes

| Area | positron-remote | here |
| --- | --- | --- |
| Server program | `fnkc-ctl.cjs` on Node | bash scripts under `/opt/fnkc-ctl-sh/current/` |
| Wire protocol | `fnkc-ctl agent <request> <args>` in, JSON on stdin for `start`, one JSON reply line out | the same protocol, versions and capabilities (decision 7); argv validated by anchored regexes, JSON read and written only with `jq` |
| Container SSH path | agent pipes to the container's port | `docker exec -i <container> /usr/sbin/sshd -i` (inetd mode: no port, no network piping), to be confirmed in phase 2 |
| Client | Positron extension (sidebar, buttons, self-update) + Node CLI `fnkc-ctl.cjs` | the same extension under its own id (coexists with positron-remote's), without the Node CLI and the in-process agent; a small bash `fnkc` (list, stop, doctor) for the terminal |
| Local Docker mode | in-process agent | dropped in v1 (server is priority 1); the TypeScript agent is not imported |
| Tests | node:test, in-process | server: bats-core with a fake `docker` on PATH, integration in a disposable server container; extension: its node:test suite in CI (or `docker run node`), never a local Node install; parity: the extension's transport against the bash server |

Server needs: bash ≥ 5, Docker, OpenSSH, util-linux (`flock`), coreutils, GNU tar, `jq`, `git` (removal preview reads
volumes inside a helper container, so git on the host is optional). Client needs: bash, OpenSSH, git, GnuPG (for
git-crypt projects), Positron.

## Decisions (user, 2026-11-24)

1. **Windows clients:** Git Bash (comes with Git for Windows). `fnkc` must run under Git Bash's bash and MSYS paths;
   CI runs the client tests on a Windows runner with Git Bash. Positron's Remote SSH works on Windows as is.
2. **Image provenance on the host:** the `gh` CLI, offline (`gh attestation verify --bundle … --custom-trusted-root`),
   as positron-remote does today. `gh` becomes a host dependency checked by `install.sh`; the trust root is refreshed
   by `refresh-trust-root.sh` as now.
3. **Images for offline hosts:** upload from the laptop as now (`docker save | ssh gateway upload`, verified manifest
   by manifest and layer by layer before `docker load`); `pullImages: false` stays the default.
4. **Existing hosts:** clean start. No migration from positron-remote's containers, volumes, labels or installs; names
   may change where that makes the bash code simpler, but stay distinct from positron-remote's so both can coexist on
   one host during the pilot.
5. **Repository:** `fnkc-stats/positron-remote-sh`, public like the original.
6. **Command names:** `fnkc-ctl` on the server (as now), `fnkc` on the client.
7. **Client and protocol (user, 2026-11-24):** TypeScript may stay where nobody installs Node: keep positron-remote's
   Positron extension as the client, and have the bash server speak positron-remote's existing protocol (requests,
   JSON replies, error codes, protocol version, capabilities), so the extension needs only small changes and its
   transport doubles as the parity test. The extension gets its own id, `~/.ssh` entry directory and release URLs so
   it coexists with positron-remote's (decision 4). Local Docker mode is dropped in v1. Decision 1 (Git Bash) now
   covers only the small bash `fnkc`; the extension's Windows path is positron-remote's, unchanged.
8. **Host names (user, 2026-11-24, Q-S1 / R35):** own account and paths, so both tools share one pilot host (decision 4):
   account `fnkcsh`, `/opt/fnkc-ctl-sh` (releases, `current`), `/etc/fnkc-ctl-sh` (`agent.json`, `keys/`,
   `trusted-root.jsonl`), journal tag and `authorized_keys` marker `fnkc-ctl-sh`. The program keeps the name `fnkc-ctl`
   (decision 6).

## Parallel work rules

Several builders work at once (queue: `docs/queue/rewrite.md`, local). They never edit the same file, because the
shared parts are created once, complete, by one early task, and later tasks only add files:

- Gateway requests: `server/lib/grammar.sh` lists every request and its argument regexes (written once, from
  `docs/spec.md`); each request is `server/requests/<request>.sh`, and a missing file answers `unknown-command`.
  Each request file declares its own capabilities; `ping` collects them.
- Admin commands: the same pattern under `server/admin/<command>.sh`.
- Error codes, reply envelope, `agent.json` keys: `server/lib/reply.sh` and `server/lib/config.sh`, complete from the
  spec. A new code or key is its own small task, serialized.
- Tests: one `test/<area>/<topic>.bats` per task; the fake `docker` answers from per-test scenario files, so tasks
  add scenarios and never edit the fake. CI discovers `test/**/*.bats` and `test/integration/*.sh`, so tasks never
  edit the workflow.
- Spec: `docs/spec.md` rows; each task marks only its own rows.

## Phases (one PR each unless noted; each PR runs `./lint.sh` and adds its tests)

0. **Spec.** From `reference/`: list every gateway request, admin command, refusal, error code, label, name and limit
   (`docs/spec.md`). Mark each kept / dropped / changed. This is the checklist for every later phase.
1. **Foundations.** Layout (`server/`, `client/`, `container/`, `test/`), `lib/` conventions (strict mode, `die`,
   logging to journald via `logger`, input validation helpers), `lint.sh` (shellcheck, shfmt check, actionlint,
   gitleaks, English-only), bats test harness with fake `docker`/`ssh`, CI workflow, `.github/scripts`.
2. **Gateway core.** Forced command entry (`authorized_keys` `command="/opt/fnkc-ctl-sh/fnkc-ctl serve --user U"`),
   `SSH_ORIGINAL_COMMAND` parsing with a fixed grammar and regex-validated arguments, request size cap, per-project
   and host locks (`flock`, with timeouts), naming and labels, `list`, `connect` (`sshd -i` path), audit journal.
3. **Container lifecycle.** Open (create with all hardening flags, volumes, network, limits), stop, idle watch,
   readiness, recovery container, update pending (never replace a running container), git-crypt key pipe.
4. **Images.** `allowedImages`, digest pins, verified image IDs, upload verification (manifest, layers, architecture,
   tar bounds), staging records, provenance per decision 2. Trust boundary: gateway-security-reviewer on every PR.
5. **Delete and offboarding.** Removal preview reusing positron-remote's in-container `REMOVAL_SCRIPT`; fingerprint
   over a canonical `jq -S` document; refuse restored archives, running projects, recovery containers;
   `admin remove-user` with the unpushed-work check.
6. **Admin and install.** `install.sh` (port from positron-remote, minus Node), `add-user`/`remove-user`,
   `check-config`, `status`, `record-image`, `resolve-image`, backups, `render-reviewed.py`, release switch recovery.
7. **Client.** Import positron-remote's extension (client side only) under its own id and paths, built and tested in
   CI; a small bash `fnkc list|stop|doctor` (Git Bash on Windows, decision 1).
8. **Release and CI.** Release workflow (server tarball + `.vsix` + `fnkc`, checksums, attestation), compatibility
   file for server-first upgrades, scheduled checks.
9. **Docs.** Russian user docs (README, manual, workflow), admin docs (admin-setup, operations, reference), adapted
   from `reference/`.
10. **Audit and pilot.** Full audit (`.agents/skills/audit`), fix plan, then a pilot host. Host steps go to the user
    as commands; we never connect to hosts.

## Tests to write early (beyond each phase's own tests)

- Hostile input to the gateway: shell metacharacters, leading `-`, newlines, NUL, Unicode look-alikes, overlong
  arguments, path traversal in every argument; each must be refused before any `docker`/`git` call.
- Ownership: user A cannot list, open, stop, delete, connect to or lock user B's objects, including by label spoofing
  and name collisions (`a.b` vs `a`).
- Concurrency: two opens, open vs delete, open vs offboard, killed gateway mid-operation; locks are released and
  helper containers are cleaned up.
- File names with spaces, quotes and newlines in removal previews and backups.
- `set -e` pitfalls: failures inside subshells, pipelines and command substitutions are not lost (`shellcheck` plus
  explicit tests that inject failures through the fake `docker`).
- Environment: the forced command ignores the caller's environment (PATH, LANG, BASH_ENV, IFS) except what sshd
  accepts.
- Parity: for each request in `docs/spec.md`, the same outcome as positron-remote on the same fixture.

## Policies carried over

`CLAUDE.md` and `AGENTS.md` (inline-first, standing rules), `.claude/agents/` checklists, `.claude/skills/audit-fix`
and `audit-queue`, the night runs (`.claude/night/`, moved here from positron-remote on 2026-11-24 and adapted to
the rewrite queue: `/rewrite`, `/rewrite-queue`, `/rewrite-add`, `/tonight`, worker `rewrite-builder`), `.agents/skills/audit*` (Codex), `.codex/agents/`, `.githooks/pre-commit`, `.shellcheckrc`,
`.hadolint.yaml`. `r-env-curator` stays in positron-remote, which owns the images. `reference/` holds frozen copies of
positron-remote's docs: policies, lifecycle, data execution, operations, admin setup, reference, manual, workflow.
