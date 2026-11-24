---
name: audit-robustness
description: Hunt edge cases and failure modes in a codebase, module, feature or diff — bad/empty/huge inputs, first run and upgrades, concurrency and races, network/disk/permission failures, platform differences, resource leaks, and whether errors reach the user in an actionable form.
---

# Robustness audit

Find what breaks under real conditions, prove it with a concrete scenario, and say exactly how to fix it.
No praise, no summary of what the code does.

## Common rules
- Target = the user’s requested target (path, feature, branch, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise the whole
  repo, starting with recently changed areas (`git log --stat -20`).
- Read applicable AGENTS.md instructions, README and design notes first; judge against the project's stated goals and constraints.
- Never connect to servers, registries or deployments. If something can only be verified live, give the
  user the exact command to run.
- Every finding cites `file:line` and a scenario: inputs/state → wrong outcome. No scenario → not a
  finding (at most an open question). Re-read the code before reporting; mark anything not confirmed as
  *unverified*.
- Read-only: no edits during the audit. At the end offer to fix selected findings; if accepted, fix,
  run the project's tests/linters, report results faithfully.

## FNKC Projects

Trace simultaneous opens, an interrupted image import and a failed replacement against docs/lifecycle.md. Identify the checkout, container and volumes that survive each failure and what the next open does. Cross-check ctl/test/recovery.test.ts and ctl/test/concurrency.test.ts. Verify that stop preserves the lockfile and snapshot changes it only on request.

## 1. Map the boundaries first
Briefly, for yourself: entry points, where state lives and who changes it, how it is persisted, process /
container / network boundaries, external dependencies, trust boundaries (user input, files, env, network).
Most robustness defects sit on a boundary or in a state transition.

## 2. What to hunt
- **Inputs:** empty, missing, null, huge, unicode, whitespace or special characters in paths, Windows
  paths and CRLF, hand-edited or corrupt config.
- **Lifecycle:** first run, upgrade from an old version, downgrade, partially migrated state, an
  interrupted previous run, leftovers from a crash.
- **Concurrency:** two instances, double click, re-entrancy, check-then-use races, stale caches, events
  that arrive out of order or are missed (watchers, subscriptions, reconnects).
- **Failure paths:** network down or slow, missing timeouts, partial writes (write-then-rename?),
  retries that are not idempotent, cancellation that leaves things half done.
- **Error model:** errors swallowed or logged and forgotten; can the caller tell retryable from fatal;
  does the user see what happened, why, and what to do next.
- **Platforms:** macOS / Linux / Windows, arm64 / amd64, shells, locales, time zones, clock skew.
- **Resources:** disk full, permissions, port in use, long-running sessions, memory growth, leaked
  processes, file handles, listeners, timers.
- **Trust boundaries (light):** shell/path injection, secrets in logs or arguments, missing validation of
  outside input. If you see deeper security problems, flag the need for a separate security review instead of covering them here.

## 3. Report (in the user's language)
1. **Verdict** — 2–4 sentences, top 3 fixes.
2. **Findings**, most severe first, grouped by the categories above:
   - **[Critical | High | Medium | Low] Title** — `file:line`
   - *Scenario:* …  *Fix:* specific change, code sketch if it helps, trade-offs.
3. **Clean areas** — one line each, so the reader knows they were checked.
4. **Open questions** — what depends on intent you could not infer.

No vague advice ("improve error handling"): name the place and the change. Don't pad.
