---
name: audit-ops
description: Audit what it takes an admin to install, run, observe, upgrade and recover a project — setup and config, secrets, logs and diagnostics, health and status views, upgrades and rollbacks, version skew between client and server, backups and restore, cleanup of leftover resources, multi-user isolation, operator docs — and propose admin features that save time.
---

# Operations audit

Judge the project from the admin's chair: how much work, guesswork and risk it takes to keep it running for
its users. Find what is missing or risky, say exactly how to fix it, and propose what would save admins time.
No praise, no tour of the code.

## Common rules
- Target = the user’s requested target (path, feature, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise the whole repo:
  install and admin scripts, CLIs, service and compose files, config files and defaults, logging, release
  notes, operator docs.
- Read applicable AGENTS.md instructions, README and design notes first; judge against the deployment the project actually
  targets (number of servers, users, who the admin is). A documented trade-off is not a finding.
- Never connect to servers, registries or deployments. If something can only be verified live, give the
  user the exact command to run.
- Every finding cites `file:line` (or the missing doc/script) and a concrete operational scenario: what the
  admin is trying to do → where they get stuck or what breaks. Re-read before reporting; mark anything not
  confirmed as *unverified*.
- Read-only: no edits during the audit. At the end offer to implement selected fixes or features; if
  accepted, implement, run the project's tests/linters, report results faithfully.

## FNKC Projects

Trace an interrupted upgrade and a restore using docs/admin-setup.md and docs/operations.md. Compare the documented backup contents and restore guarantees with the backup integration test Check protocol skew, gateway host-key handling, offline image verification, the identity of restored volumes and redaction of diagnostics against docs/data-execution.md.

## 1. Map first
Briefly, for yourself: who the admin is and what they do day to day; every component they install or run
and where; the lifecycle of one deployment (install → configure → onboard users → run → upgrade → back up →
recover → uninstall); where state and user data live.

## 2. What to hunt
- **Install and setup:** steps that are manual, undocumented or order-dependent; prerequisites not
  checked up front; no idempotent re-run after a failed install.
- **Config:** validated at startup with a clear message, or fails later in an obscure place; defaults safe
  and documented; one place to look for the effective config.
- **Secrets:** where they live, file permissions, how they are rotated, whether they leak into logs,
  process arguments or status output.
- **Observability:** can the admin see what is running, for whom, since when, how healthy, and which
  version — without reading code or containers by hand? Logs: where, how rotated, with enough context
  (user, project, request) to debug.
- **Diagnostics:** a single command or bundle a user can send that contains what the admin needs and no
  secrets.
- **Upgrades and rollbacks:** documented order (server vs client), data or config migrations, behaviour
  with mixed versions (version skew, old clients against a new server), a tested way back.
- **Backups and restore:** what must be backed up, whether restore is documented and tested, what is lost
  between backups.
- **Cleanup:** leftover containers, images, volumes, ports, temp files, stale user state; does anything
  grow without bound?
- **Multi-user:** isolation between users, quotas or limits, what one user can do to another's work,
  onboarding and offboarding a user.
- **Bulk and routine work:** tasks the admin repeats per user or per server that should be one command.
- **Audit trail:** who did what and when, for actions that matter (create, delete, upgrade, access).
- **Operator docs:** a runbook for the common incidents; docs that match the current commands and flags.

## 3. Suggest admin features
After defects, propose features and optimizations that would save admin time, cut support questions or
make operations safer. Ground each in this project's actual workflows; one-line rationale and rough cost
(S/M/L).

## 4. Report (in the user's language)
1. **Verdict** — 2–4 sentences: how hard this is to operate today; top 3 fixes.
2. **Lifecycle table** — install · configure · onboard · observe · upgrade · back up · recover ·
   uninstall: OK / issue / missing / n/a, one-line note.
3. **Findings**, most severe first, grouped by the categories above:
   - **[Critical | High | Medium | Low] Title** — `file:line` or "missing"
   - *Scenario:* what the admin tries → what happens.  *Fix:* specific change (command, script, doc
     section, config check).
4. **Suggested admin features** — table: idea · why · cost.
5. **Commands to verify live** — for unverified items.
6. **Open questions** — intent you could not infer.

No vague advice ("improve logging"): name what is logged, where, and what the admin can then do. Don't pad.
