# Claude Code instructions for this repo

positron-remote-sh: the positron-remote service rebuilt on plain SSH, bash and Docker, with no Node.js. The plan is
[docs/plan.md](docs/plan.md); the behaviour to keep is in [reference/](reference/) (frozen copies of positron-remote's
docs @ 9ff6fca, never edited). Environment images are built and published by positron-remote; this repo only
consumes them by digest.

## Project agents and skills: inline first

Subagents start cold and re-read everything the main session already has, so they cost several times more than
doing the work here. Default: **work inline**. For a matching request, read the agent's file in `.claude/agents/`
and apply its checklist and output format yourself, on the diff you already have.

Spawn a subagent only when:
- the user asks for one, or for `/audit-fix` (one `audit-fixer` per independent item; follow
  `.claude/skills/audit-fix/SKILL.md`, including claims and status updates), or for `/rewrite` (one
  `rewrite-builder` per ready task; follow `.claude/skills/rewrite/SKILL.md`);
- the user wants a fully independent review of a large diff (more than about 400 changed lines in `server/` or
  `client/`). Then use one reviewer, the most relevant one, not several in parallel.

| Request or change | Checklist (`.claude/agents/`) |
| --- | --- |
| Failed or flaky GitHub Actions check | `ci-triage.md` |
| Release safety, client/server compatibility, running containers, install/rollback, image pins, release workflows | `rollout-guard.md` |
| Docs drift after changes to commands, settings, messages, scripts, workflows | `docs-sync.md` |
| Gateway, ownership, uploads, image verification, container isolation, keys, secrets, backups, install.sh | `gateway-security-reviewer.md` |
| Audit a repo, module or diff | `.agents/skills/audit/SKILL.md` or `audit-<area>/SKILL.md` |
| Build one rewrite queue task inline (when not using `/rewrite`) | `rewrite-builder.md` |

Team R image packages are positron-remote's business (its `r-env-curator`), not this repo's.

Apply only the checklist sections that the diff touches. Read the docs they cite one section at a time (`grep -n` for
the heading, then read that range), never whole files. For a repeat review with the same base and a
new head that descends from the reviewed head, review only the commits since the reviewed head and the earlier
findings they affect; otherwise (base changed, history rewritten, scope unclear) review the full target.

Token hygiene for long commands: redirect `./lint.sh`, test runs and `gh pr checks --watch` to a log file and show
only the result or `tail -40` on failure; use `gh run view --job <id> --log-failed | tail -80`, never full logs.

Agent definitions live in `.claude/agents/`. When adding one, add its row here.

## Rewrite queue and night runs
The rewrite is worked through as a task queue, `docs/queue/rewrite.md` (local, git-excluded, like audit plans; one
task per PR, with dependencies). `/rewrite` coordinates builders, `/rewrite-queue` lists what is left,
`/rewrite-add` adds or splits tasks. `.claude/night/night.py` (launchd, installed from the main checkout) runs
`/rewrite` and later `/audit-fix` unattended at night within half of the weekly limit; `/tonight` says what it
will do, `/tonight last` what it did. After a night, glance at `.claude/night/last.md`.

## Bash rules (all scripts)
- `#!/usr/bin/env bash`, `set -euo pipefail`, `shopt -s inherit_errexit`; shellcheck clean at warning level.
- Untrusted input (gateway arguments, file names, Docker output) is validated by an anchored regex before use, kept
  in quoted variables and arrays, passed after `--`; never `eval`, never `bash -c` or `jq` programs built from input
  (`jq --arg`). JSON is read and written only with `jq`.
- No Node.js, Python or other runtimes in the server or client paths, except the existing `render-reviewed.py`.
  New host or client dependencies need a line in `docs/plan.md` and a check in `install.sh` / `fnkc doctor`.
- Every behaviour change gets a bats test; failures injected through the fake `docker` must surface.

## Standing rules (also in each agent)
- Never ssh to or probe the servers or Gitea; give the user the commands to run.
- One branch per change off fresh `origin/main`; run `./lint.sh` before committing.
- **Usage gate for any agent launch** (from this file's table, `/audit-fix` or `/rewrite`): read
  `~/.claude/mods/glance/usage.json` first. At 80 % of either limit, ask the user whether to continue before
  launching (once per limit window); at 95 %, launch nothing, let running agents finish their item, and schedule a
  one-shot resume at the reset time. Details in `.claude/skills/audit-fix/SKILL.md` «Usage gate».
- Agents that edit files (audit-fixer, rewrite-builder, docs-sync when applying) always work in their own worktree, so any number of
  them can run alongside each other and the user's own work.
- If the main checkout is not on `main` or is dirty, another session may be using it: do your work in a separate
  worktree (`git worktree add ../positron-remote-sh-wt-<name> -b <branch> origin/main`) instead of switching branches.
- Real hostnames never go into committed files.
