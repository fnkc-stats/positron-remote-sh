---
name: audit-ci
description: Audit the test suite and CI/CD pipelines — whether checks catch the regressions that matter, tests that cannot fail or test the impossible, flaky and slow tests, pipeline caching, path filters, job graph, concurrency, action pinning and token permissions, release gating and rollback.
---

# CI and tests audit

Judge whether the tests and pipelines are relevant, sufficient and efficient: what regressions slip
through, what is checked for nothing, and what wastes time. No praise, no tour of the workflows.

## Common rules
- Target = the user’s requested target (workflow file, test directory, or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise
  all of: `.github/workflows`, `.gitea/workflows`, other CI configs, test directories, test configs,
  release scripts, and the scripts they call.
- Read applicable AGENTS.md instructions, README and design notes first; judge against the project's stated goals, the platforms
  it actually ships, and its release process. A documented trade-off is not a finding.
- Never connect to servers, CI services or registries, and never trigger pipelines. Run the local test
  suite only if it is documented, offline and does not touch servers; otherwise give the user the exact
  command (e.g. to time a job or list flaky runs).
- Every finding cites `file:line` and a concrete consequence: a named regression that reaches main
  undetected, minutes wasted per run, a secret a fork could read. Re-read before reporting; mark anything
  not confirmed as *unverified*.
- Read-only: no edits during the audit. At the end offer to fix selected findings; if accepted, fix, run
  what can be run locally (linters for workflows, the test suite), report results faithfully.

## FNKC Projects

Walk a checks-only change, an environment change and a reused-image build through the workflow conditions. Trace each tested digest to its published manifest and attestation. Compare ci-local.sh with the workflow scripts. Identify which checks exercise native Windows, WSL, an actual SSH connection or an extension mock, and what assertion would fail on a regression.

## 1. Map first
Briefly, for yourself: every shipped artifact and platform; every workflow, its triggers, jobs and what
each job proves; the test suite's layers (unit / integration / end-to-end / smoke) and what each covers;
the release path from commit to a user's machine.

## 2. What to hunt

### Coverage of what matters
- For each shipped artifact and platform: is it linted, type-checked, built, tested and smoke-run before
  merge? Docker images built and started, not just linted.
- Name each important regression class that would currently reach main undetected — take risky paths
  from the code (boundaries, state transitions, upgrades, error paths), not a coverage percentage.
- Security checks present where they pay off: dependency audit, image scan, secret scan.

### Tests that prove nothing
- Tests that cannot fail, assert nothing meaningful, or mock the very thing they claim to test.
- Assertions on implementation details that break on every refactor but miss behaviour changes.
- Duplicate coverage across jobs or layers; platforms or configurations tested but never shipped.
- Flakiness sources: network, real time and sleeps, test order, shared state, ports, randomness without
  a seed.

### Efficiency
- Dependency and Docker layer caching (`cache-from` / `cache-to`), artifacts reused instead of rebuilt.
- Path filters so docs-only or unrelated changes skip heavy jobs.
- Job graph and parallelism; slowest job on the critical path and how to cut it.
- Concurrency groups cancelling superseded runs; timeouts on every job; matrix size justified.

### Safety and release
- Actions pinned by SHA; least-privilege `permissions:`; secrets not exposed to forks or
  `pull_request_target`; no untrusted input interpolated into `run:` scripts.
- Release built reproducibly from a tag; release job gated on tests; versions consistent across tag,
  manifests and artifacts; a documented rollback path.

### Platform specifics (apply what is present)
- **Gitea Actions:** features that differ from GitHub (cache action, `GITHUB_*` vars, runner labels,
  service containers); workflows written for GitHub that silently do nothing on Gitea.
- **VS Code extension:** tests run in an Extension Host (`@vscode/test-electron` / `test-cli`), packaged
  `.vsix` built and checked, minimum `engines.vscode` version tested.
- **R:** `R CMD check` or testthat run against the pinned R version and `renv.lock`.

## 3. Report (in the user's language)
1. **Verdict** — 2–4 sentences, top 3 fixes.
2. **Coverage table** — artifact/platform · lint · build · test · smoke · notes (OK / missing / n/a).
3. **Findings**, most severe first, grouped by the sections above:
   - **[Critical | High | Medium | Low] Title** — `file:line`
   - *Consequence:* …  *Fix:* specific change (YAML sketch when it helps), expected time saved if
     measurable.
4. **Missing tests worth writing** — table: what it would catch · layer · rough cost (S/M/L).
5. **Commands to verify live** — for unverified items.
6. **Open questions** — intent you could not infer.

No vague advice ("add more tests"): name the regression, the test and where it goes. Don't pad.
