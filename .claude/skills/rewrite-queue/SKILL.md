---
name: rewrite-queue
description: Brief list of the rewrite queue's tasks that are still to do and NOT running right now, each with an effort estimate and whether it is ready or waiting on a dependency. Use when the user types /rewrite-queue or asks "what's left in the rewrite", "what's next", "which tasks are open", "where are we in the plan".
argument-hint: ""
---

# /rewrite-queue — what's left, quickly

Read-only and fast: no agents, no code reading, no git/gh. Answer from the queue text.

1. Queue: `$main/docs/queue/rewrite.md` in the **main checkout**
   (`main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`). Read it once. Missing → one
   line saying so and that `/rewrite-add` creates it.
2. Keep tasks that are **open**: Status not merged / done, and not taken. Taken = `in progress` with a time less
   than 6 hours ago (no time → taken), or `PR #N open`. An older `in progress` claim counts as open — mark it
   `(stale claim)`. A task is **ready** when every ID in `After` is merged; otherwise it waits on the first
   unmerged one.
3. Effort, from the task wording:
   - **low**: docs only, one script or check, a flag in one place.
   - **medium**: one module with its bats tests, or one workflow/script + its fixture.
   - **high**: gateway grammar or trust boundary (gateway, ownership, images, uploads, keys, install), several
     modules, concurrency/locking, or the Windows client path.
4. Reply in this shape, nothing more:

```
Ready (N):
- R2 gateway core — high
Waiting (N):
- R3 container lifecycle — high · after R2
Running: R0, R1 · PR open: —
Waiting on you: R11
```

   One line per task: ID + few-word name — effort, then `· after X` for the first unmerged dependency. Omit empty
   sections. If nothing is open, say so in one line.
