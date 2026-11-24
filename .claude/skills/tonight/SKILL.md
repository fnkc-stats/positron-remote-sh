---
name: tonight
description: Say in one or two lines what this repo's unattended night job (.claude/night) will do tonight, or what it did last night. Use when the user types /tonight or asks "what runs tonight", "what's planned for the night", "what happened overnight".
argument-hint: "[last | skip | unskip | only <command>]"
---

Work in the main checkout: `main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`;
`n="$main/.claude/night"`. Run one command, reply with its result in at most two short lines, nothing else:

- no argument: `/usr/bin/python3 "$n/night.py" tonight`
- `last`: summarize `$n/last.md` (what the last night did: PRs merged/open, follow-ups added, skipped and why)
- `skip`: `touch "$n/skip"`, then the `tonight` line
- `unskip`: `rm -f "$n/skip"`, then the `tonight` line
- `only <command>` (e.g. `only /rewrite R3 --max 1`): write the command to `$n/only`, then the `tonight` line
