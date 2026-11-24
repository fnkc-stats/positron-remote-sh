# Night runs

Unattended Claude Code runs at night that work through this repository's queues while the user sleeps.
`night.py` lives here and keeps its runtime files here too (git-ignored): `state.json`, `last.md`, `history.md`,
`logs/`, `skip`, `only`. Install it from the **main checkout** (launchd points at this file's path), from a shell
whose PATH finds `claude`:

    .claude/night/night.py install     # write ~/Library/LaunchAgents/local.claude-night.positron-remote-sh.plist, load it
    .claude/night/night.py uninstall   # pause (install re-reads config.json)

launchd runs `night.py run` at the slots in `config.json` (00:00 and 04:30). Each slot:

1. Skip flag `.claude/night/skip` set → skip (it cancels one night; the last slot removes it).
   `.claude/night/only` holds one command that replaces the sources for one night (e.g. `/rewrite R3 --max 1`);
   the last slot removes it, and it does not mark a source as empty.
2. Sources (`config.json` → `sources`), in order: the rewrite queue `docs/queue/rewrite.md` (`/rewrite`), then the
   newest audit fix plan (`/audit-fix`; none exists until phase 10). If the last run said NOTHING_OPEN and the file
   has not changed since, skip it without starting Claude.
3. A tiny haiku call reads the limits. Night runs stop the week at `weekCap` (50 %) **in total**: day + night usage
   together. Week already at 40 % → the night may add 10 %; at 50 % or more → no night run. (`"pacing": "even"`
   splits the room left evenly over the slots left.) The 5-hour window stops a run at `fiveHourCap`.
4. Runs `claude -p "<command>" --permission-mode auto` in the repository with night rules (never ask, stop launching
   at the cap, no new work after 3 h, hard stop at 4 h or cap + 5 %).
5. Measures the spend, writes `last.md` (this night) and `history.md` (all nights).

Commands (also `/tonight` in Claude):

    .claude/night/night.py tonight       # one line: what tonight will do (no tokens)
    .claude/night/night.py status
    .claude/night/night.py run --dry-run # check a slot without starting Claude for the work
    touch .claude/night/skip             # skip the coming night
    echo '/rewrite R3 --max 1' > .claude/night/only   # run only this tonight

Optional keys in `config.json`: `"claude"` (path to the binary; default: `claude` on PATH) and `"env"` (extra
variables for launchd). Keep personal paths out of the committed file.
