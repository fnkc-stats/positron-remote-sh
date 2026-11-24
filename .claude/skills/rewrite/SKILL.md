---
name: rewrite
description: Work through the rewrite queue (docs/queue/rewrite.md) — coordinate parallel rewrite-builder runs on tasks whose dependencies are merged, each in its own worktree, and record statuses and follow-ups in the queue. Use when the user types /rewrite or asks to work through / continue the rewrite, the queue, or the next phase.
argument-hint: "[task IDs, e.g. R2 R7] [--max N] [--refill] [--dry-run]"
---

# /rewrite — coordinate the rewrite queue

You are the coordinator. rewrite-builder runs implement; you choose, launch, track and record. Do not implement
tasks yourself.

## Arguments ($ARGUMENTS)
- Task IDs (e.g. `R2 R7`): only these. None: every open task that is ready (below).
- `--max N`: parallel runs (default 2, never more than 4). Prefer one chat with a higher `--max` over several chats.
- `--refill`: when a run reports, launch the next ready task into its slot (merged tasks make new ones ready).
  Without it, launch one wave only, track it to the end, then Finish.
- `--dry-run`: show the waves and stop, launch nothing.

Queue: `$main/docs/queue/rewrite.md` in the **main checkout**
(`main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`; the queue is git-excluded, so
worktrees don't have it). Missing → say so and suggest `/rewrite-add`; stop.

## Queue format
One table per group, columns `| ID | Branch | After | Task | Status |`. `After` lists task IDs that must be
**merged** first (`—` for none). Status: `open`, `in progress (<tag>, <ISO time>)`, `PR #N open: …`,
`PR #N merged (<date>)`, `blocked: …`, `user: …` (waits on the user). Tasks under «Needs the user» wait for an
answer recorded as `ANSWERED (<date>): …`.

## Usage gate (before every launch)
Exactly as `.claude/skills/audit-fix/SKILL.md` «Usage gate» (thresholds 80 % / 95 %, 30-minute freshness, one
question per limit window), except that the resume prompt is `/rewrite <the same arguments>`.

## Claims (several chats may coordinate the same queue)
As `.claude/skills/audit-fix/SKILL.md` «Claims», with the lock `lock="$main/docs/queue/.queue.lock"` and the 6-hour
claim rule. Lock every queue edit, re-read the queue under the lock, claim before launch, release (restore the
previous Status) for claimed tasks you do not launch.

## Steps
1. **Read the queue.** A task is **ready** when its Status is `open` (or a claim older than 6 hours with no branch
   and no PR), every ID in `After` is `merged`, and it is not under «Needs the user». List questions of tasks that
   wait on the user and ask them together in one AskUserQuestion (options from the task, recommended first); don't
   wait on the answers to start the rest. Record answers under the lock as `ANSWERED (<date>): …`.
2. **Usage.** Apply the Usage gate.
3. **Estimate scope.** For tasks you could launch in the next wave and tasks taken by other chats: list the files
   or directories each will likely touch, from the task text and `docs/plan.md`. Do not open code unless the task
   names nothing; then one `grep -rln`.
4. **Plan waves.** Independent = no shared source file and neither in the other's `After`. Always serialize tasks
   that change the gateway request grammar, the error code list or `docs/spec.md`'s tables (other than marking
   their own rows), `lib/` conventions, `lint.sh` or pinned tool versions, or the same workflow file. Docs-only
   overlap is fine. Show the user in a few lines: which run now, which wait and on what.
5. **Claim, then launch** up to `--max` rewrite-builder agents (Agent tool, `subagent_type: "rewrite-builder"`,
   `isolation: "worktree"`). Pass: the absolute queue path, task ID, the exact task text and any recorded answer,
   assigned branch (from the queue, or `feat|build|ci|docs/<short-name>`), its plan phase, and the likely files.
6. **Track.** Wait for task notifications; do not poll runs or read their output files. As each run reports, under
   the lock: replace your claim with its first line and today's date, and **add its `Follow-up:` lines as new
   tasks** (next free ID `R<n>`, `open`, `After` from the line, in the same group). With `--refill`, re-read the
   queue and launch the next ready task that is untaken and independent of everything still running (Usage gate
   first).
7. **Failures.** Use the builder's diagnosis. Launch `ci-triage` only for an unresolved cause, conflicting evidence,
   or a different failure in a newer attempt. If the task caused it, resume that build on its existing PR;
   otherwise report the blocker and leave the PR open. A run stopped on a merge conflict: re-launch it alone after
   the conflicting PR merged. Never weaken a guard to get green.
8. **Finish.** When all your runs have reported (with `--refill`: and nothing ready is left): short summary — merged
   PRs, PRs left open and why, follow-ups added, questions waiting for the user, and which tasks become ready next.

Never ssh to or probe servers or Gitea; host-side steps go to the user as commands.
