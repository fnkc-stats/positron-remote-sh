---
name: audit-ux
description: Audit the end-user experience of an app, extension, CLI or feature — main user journeys, first run, feedback for every async action (loading / success / empty / error / cancel), stale or misleading state, error messages, defaults, destructive actions, discoverability, consistent wording, keyboard access and accessibility, CLI ergonomics — and propose user features that save time.
---

# UX audit

Judge the product from the user's chair: how many steps, how much waiting, guesswork and risk each task
takes. Find what confuses, misleads or slows users down, say exactly how to fix it, and propose what would
save them time. No praise, no tour of the code.

## Common rules
- Target = the user’s requested target (path, feature, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise every user-facing
  surface: UI views and panels, commands, notifications, messages and strings, settings, CLI help and
  output, user docs.
- Read applicable AGENTS.md instructions, README and design notes first; judge against who the users actually are (skill level,
  language, daily tasks). A documented trade-off is not a finding.
- Never connect to servers, registries or deployments. You may run the app locally
  to see it, if that does not touch servers; otherwise work from the code and give the user the steps to
  check live.
- Every finding cites `file:line` and a concrete user scenario: what the user is trying to do → what they
  see → why it is a problem. Re-read before reporting; mark anything not confirmed as *unverified*.
- Read-only: no edits during the audit. At the end offer to implement selected fixes or features; if
  accepted, implement, run the project's tests/linters, report results faithfully.

## FNKC Projects

Walk an analyst from Check Setup to first open in docs/manual.md and docs/workflow.md. Compare the command palette, sidebar and CLI during image transfer, a missing Positron build and a pending environment update. Check whether the user can identify the host and checkout, recover after cancellation, and predict the effect of stop, snapshot or removal.

## 1. Map first
Briefly, for yourself: who the users are; the 3–5 main journeys (from docs, commands, UI entry points),
step by step as the user experiences them; every place the UI shows state and where that state comes from.

## 2. What to hunt
- **Journeys:** steps that could be removed or merged, dead ends, tasks that need the terminal or docs
  although the UI could do them, first run and onboarding (what does a new user see and do first?).
- **Async feedback:** every action has loading, success, empty, error and cancel states; feedback within
  ~100 ms; long operations show progress and can be cancelled; no double-submit.
- **State shown:** stale, missing or misleading state (UI says running when it is not, refresh needed to
  see a change); state changes made elsewhere reflected without user action.
- **Errors:** say what happened, why, and what to do next, in the user's terms; no raw stack traces or
  codes without explanation; details available for the admin (log, "copy details").
- **Defaults and safety:** sensible defaults; destructive actions confirmed with what will be lost, and
  undoable where possible; no surprising side effects.
- **Discoverability:** features findable where users look; names that say what they do; settings
  described.
- **Consistency:** wording, terminology from the user's domain, icons, ordering, capitalisation; the same
  thing called the same everywhere; translations complete when the product is multilingual.
- **Accessibility:** keyboard access to everything, focus order, contrast in light and dark themes,
  screen-reader labels, not relying on colour alone.
- **CLI (when present):** `--help` useful with examples, consistent flags, meaningful exit codes, output
  readable for humans and parseable for scripts (`--json`), progress on stderr, no prompts in
  non-interactive runs.

### Surface specifics (apply what is present)
- **VS Code / Positron extension:** native UI used appropriately (tree views, QuickPick, status bar,
  webviews only when needed); notifications not spammy, progress via `withProgress`; commands in the
  palette with a category and `when` clauses; settings with descriptions and correct scope; follows the
  editor theme; works in remote and multi-root windows if they are supported.

## 3. Suggest user features
After defects, propose features and optimizations that would save users time, cut clicks or prevent
mistakes. Ground each in this project's actual journeys; one-line rationale and rough cost (S/M/L).

## 4. Report (in the user's language)
1. **Verdict** — 2–4 sentences: how it feels to use today; top 3 fixes.
2. **Journey table** — journey · steps today · friction points · steps after fixes.
3. **Findings**, most severe first, grouped by the categories above:
   - **[Critical | High | Medium | Low] Title** — `file:line`
   - *Scenario:* what the user tries → what they see.  *Fix:* specific change: exact new wording for
     messages and labels, or a small ASCII mockup for layout changes.
4. **Suggested user features** — table: idea · why · cost.
5. **Open questions** — intent you could not infer.

No vague advice ("improve feedback"): name the screen or message and give the new version. Don't pad.
