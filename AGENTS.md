# Codex in positron-remote-sh

Use the routing table and inline-first review rules in `CLAUDE.md`. Apply the matching
Codex role in `.codex/agents/` directly in the target checkout for routine reviews.
When delegating, pass the target range, relevant paths and review question. For repeat
reviews, include the reviewed base, head and findings. Review the delta and affected
findings when the base matches and the new head descends from the reviewed head.
Review the full target if the scope or history changed or earlier assumptions no longer hold.

Use `$audit-one` for plan-driven audit fixes alongside Claude. Both tools share the
plan, branch names, review requirements and status cells.

Apply the repository's standing rules to Codex jobs. For the usage gate use Codex's current
five-hour and weekly limits, with the thresholds and stale-data policy in the audit-fix skill.
Claude's usage file measures a separate account budget. If Codex usage is unavailable, ask before
launching. At a hard limit release unlaunched claims and report the reset time. Schedule a
one-shot resume only when the client supports it.

For edits, create a job branch and worktree from fresh `origin/main`. Run `./lint.sh` before
commit, push the job branch, and return to the main checkout. Remove only your own clean
worktree after handoff or merge. Preserve other sessions' worktrees, branches and pending edits.

Codex configuration lives only in `AGENTS.md`, `.codex/` and `.agents/`. Do not edit
`CLAUDE.md` or `.claude/` to suit Codex: those files are the shared source of truth, and the
Codex roles point to them.
