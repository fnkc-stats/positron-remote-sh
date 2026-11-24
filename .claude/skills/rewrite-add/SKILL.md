---
name: rewrite-add
description: Add one or more tasks to the rewrite queue (docs/queue/rewrite.md), with ID, branch and dependencies, so /rewrite and the night runs pick them up. Use when the user types /rewrite-add or asks to queue, add, split or reorder a rewrite task.
argument-hint: "<task text> [--after R2,R4] [--group <name>] [--user]"
---

# /rewrite-add — queue a task

1. Queue: `$main/docs/queue/rewrite.md` in the main checkout
   (`main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`). Format and Status values:
   `.claude/skills/rewrite/SKILL.md` «Queue format». If the file is missing, create it from `docs/plan.md`: a short
   header (source plan and commit, rules line pointing to the rewrite skill), one group per phase, one task per
   phase with `After` from the phase order, and «Needs the user» for steps that need a host or a decision.
2. Write the task so a builder can run it cold: what to build, the plan phase and spec rows it covers, the files or
   directories it touches, the tests that prove it, and which review checklist applies. One PR's worth (under about
   800 changed lines); split anything bigger into several tasks chained by `After`. If the request is too vague to
   do that, ask one AskUserQuestion with concrete options instead of guessing.
3. `--after` sets dependencies; without it, infer them from the plan's phase order and file overlap, and say which
   you chose. `--group` picks the table (default: the phase the task belongs to). `--user` puts it under «Needs the
   user» (host steps, decisions).
4. Under the queue lock (`.claude/skills/rewrite/SKILL.md` «Claims»; `mkdir "$main/docs/queue/.queue.lock"`, re-read,
   edit, `rmdir`): next free ID `R<n>` (sub-tasks of an existing one: `R3a`, `R3b`), branch
   `feat|build|ci|docs/<short-name>` unique in the queue, Status `open`. Splitting an open task: replace it by its
   parts and point dependents' `After` at the last part. Never edit tasks that are `in progress` or have a PR.
5. Reply with one line per added task: `R<n> <name> · after … · <branch>`, and whether it is ready now.
