---
name: audit-queue
description: Brief list of the audit fix plan's items that are still to do and NOT running right now, each with an effort estimate (low / medium / high). Use when the user types /audit-queue or asks "what's left in the audit plan", "what's next", "which fixes are open".
argument-hint: "[--plan path]"
---

# /audit-queue — what's left, quickly

Read-only and fast: no agents, no code reading, no git/gh beyond what's below. Answer from the plan text.

1. Plan: `--plan` or the newest `docs/audits/*-fix-plan.md` in the **main checkout**
   (`main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`; the plan is git-excluded).
   Read it once.
2. Keep items that are **open**: Status not merged / done / complete, and not taken. Taken = Status `in progress`
   with a time less than 6 hours ago (no time → taken), or `PR #N open`. An `in progress` claim older than 6 hours
   counts as open — mark it `(stale claim)`.
   Items under "Needs the user's decision" that have no ANSWERED note go in one separate line, numbers only.
3. Effort, from the plan's wording (open a cited audit report only if it exists and the plan line says too little to judge):
   - **low**: docs only, one message/text, one small file, a check or flag in one place.
   - **medium**: one module's logic + tests, or one workflow/script + its fixture.
   - **high**: wire protocol / capability, server-first rollout, several modules, trust boundary (gateway, helpers,
     image verification), or anything that rebuilds images.
4. Reply in this shape, nothing more (no preamble, no closing advice):

```
Open, not running (N):
- O4 restore runbook — low · after O2
- Q9c retry Open after cancelled transfer — medium · after Q9b
...
Running: C4, O2, Q9b · PR open: B5
Waiting on you: Q1, Q4–Q8
```

   One line per item: plan ID + few-word name — effort, then `· after X` if the plan names a dependency that is not
   done yet. Omit the Running / Waiting lines if empty. If nothing is open, say so in one line.
