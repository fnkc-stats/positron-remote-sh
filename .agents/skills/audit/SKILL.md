---
name: audit
description: Full audit of a codebase, module, feature or diff as a top-tier programmer, architect and UI/UX expert — picks the relevant focused audits (audit-robustness, audit-architecture, audit-build, audit-ci, audit-ops, audit-ux), runs them in parallel, merges and ranks the findings into one report with fixes and proposed user/admin features.
---

# Full audit (coordinator)

You coordinate focused audits; you do not redo their work. Your value is choosing the right ones,
running them together, removing duplicates, linking related findings, and ranking everything into one
plan.

## 1. Scope and selection
- Target = the user’s requested target minus flags (path, feature, branch, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files);
  otherwise the whole repo.
- Read applicable AGENTS.md instructions, README and design notes, and list the repo's top-level structure, so you know what
  exists (Docker? CI? UI? CLI? admin scripts?).
- Pick the audits:
  - `--only` / `--skip` from the arguments win.
  - Otherwise include each audit whose subject exists in the target: robustness and architecture for
    any code; build if there are Dockerfiles, lockfiles or build scripts; ci if there are workflows or
    tests; ops if something is deployed or administered; ux if there is any user-facing surface (UI,
    CLI, messages).
  - For a small `diff`, skip audits whose files it does not touch.
- Tell the user in one line which audits will run and why any are skipped; then start without waiting.

## 2. Run in parallel
Assign independent reviews to available subagents in parallel. Batch them within the session limit. Each subagent prompt contains:
- "Read `.agents/skills/audit-<name>/SKILL.md` (relative to the repo root) and follow it exactly, for target: <target>."
- The project facts you already gathered (purpose, stack, constraints from applicable AGENTS.md instructions), so it does not
  re-derive them.
- "Do not edit files and do not offer to implement fixes; the coordinator does that. Return the full
  report, keeping every finding's severity, `file:line`, scenario/cost/consequence and fix."

If subagents are unavailable, run the audits yourself one after another, in the same order, with the
same rules.

## 3. Merge
- **Dedupe:** the same root cause reported by several audits becomes one finding, listing every area it
  affects; keep the strongest scenario and the most specific fix.
- **Link:** connect related findings across areas (an edge case from robustness + the missing test from
  ci + the misleading message from ux) into one item with one combined fix.
- **Verify:** re-read the code yourself for every Critical and High finding before it goes into the
  report; downgrade or drop what does not hold, and mark the rest as verified.
- **Rank** globally by severity × how many users/admins it affects × cost to fix; cheap high-impact fixes
  first within a severity.

## 4. Report (in the user's language)
1. **Verdict** — 3–5 sentences: overall state and the top 3–5 fixes.
2. **Fix plan** — numbered list of the top ~10 items across all areas: title · areas · severity · cost
   (S/M/L).
3. **Findings by area** — Robustness · Architecture · Build · CI · Ops · UX, most severe first, in the
   focused audits' format; cross-area items appear once, under their main area, with links from the others.
4. **Checklists** — the build checklist, CI coverage table, ops lifecycle table and UX journey table, in
   compact form.
5. **Suggested features** — one table merging user and admin features: idea · who benefits · why · cost.
6. **Commands to verify live** — merged from all audits.
7. **Open questions** — merged and deduplicated.
8. **Not covered** — audits skipped and why; recommend a dedicated code or security review if the target
   warrants it.

Keep the report proportional to the requested scope.

## 5. After the report
Offer to implement selected items. If the user agrees: follow the project's branching and commit
conventions, implement, run the project's tests/linters, and report results faithfully, item by item.
