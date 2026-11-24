---
name: audit-architecture
description: Judge the structure and design methodology of a codebase, module, feature or diff — responsibilities and layering, coupling, duplicated logic and sources of truth, abstractions, implicit state machines, config sprawl, cost of likely changes, testability, and design-level performance (polling vs events, repeated work).
---

# Architecture audit

Judge whether the structure fits the problem and will survive the next changes. Find what is misplaced,
duplicated, coupled or missing, and say exactly how to restructure it. No praise, no tour of the code.

## Common rules
- Target = the user’s requested target (path, feature, branch, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise the whole
  repo, starting with recently changed areas (`git log --stat -20`).
- Read applicable AGENTS.md instructions, README and design notes first; judge against the project's stated goals and constraints,
  not an imagined product. A deliberate trade-off written down in the docs is not a finding.
- Never connect to servers, registries or deployments. If something can only be verified live, give the
  user the exact command to run.
- Every finding cites `file:line` and a concrete cost: which change, bug or confusion this structure causes
  (e.g. "adding a new server type means editing these 5 files"). No concrete cost → not a finding.
  Re-read the code before reporting; mark anything not confirmed as *unverified*.
- Read-only: no edits during the audit. At the end offer to fix selected findings; if accepted, fix,
  run the project's tests/linters, report results faithfully.

## FNKC Projects

Trace an open request from the CLI and extension through the shared client, gateway protocol and host. Identify which component owns repository identity, the environment pin and runtime state. Follow a plausible change such as adding a lifecycle state through callers, cached views and tests.

## 1. Build the model first
Briefly, for yourself: components and their responsibilities, the direction of dependencies, data flow,
where each piece of state lives and who owns it, process / container boundaries, and the project's own
vocabulary (domain terms in the docs vs names in the code).

## 2. What to hunt
- **Responsibilities:** logic in the wrong layer (UI deciding business rules, transport knowing about
  storage), god objects or files, modules that do two unrelated jobs.
- **Sources of truth:** the same fact stored or computed in several places (config, constants, version
  numbers, lists of supported things, state cached in UI and backend) that can disagree.
- **Coupling:** hidden dependencies (shared globals, order of initialisation, file formats parsed in two
  places), dependency direction pointing the wrong way, leaky abstractions that force callers to know
  internals.
- **State:** implicit state machines (several booleans instead of one state), impossible states that are
  representable, transitions without a single owner.
- **Config:** settings spread across files, env vars and code defaults with unclear precedence.
- **Change cost:** pick 2–3 changes the project will plausibly need next (from docs, TODOs, git history)
  and trace how many places each one touches. Flag both over-engineering (abstractions with one user,
  extension points nobody needs) and the missing seam that will hurt next.
- **Testability:** what cannot be tested as written and why (hard-wired I/O, time, processes, singletons);
  which seam would make it testable.
- **Design-level performance:** polling where events exist, repeated or N+1 calls across a boundary,
  recomputing what could be cached or invalidated, work on the UI or main thread.
- **Drift:** dead code, abandoned paths, docs describing a design the code no longer follows.

## 3. Report (in the user's language)
1. **Verdict** — 2–4 sentences: does the structure fit the problem; top 3 changes.
2. **Findings**, most severe first, grouped by the categories above:
   - **[Critical | High | Medium | Low] Title** — `file:line`
   - *Cost:* which change, bug or confusion it causes.  *Fix:* the target structure, migration steps if the
     change is large, trade-offs. A small diagram (mermaid) when the structure is hard to describe in words.
3. **Clean areas** — one line each, so the reader knows they were checked.
4. **Open questions** — intent you could not infer.

No vague advice ("consider decoupling"): name the pieces, where they should go, and why. Don't pad.
