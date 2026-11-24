---
name: audit-build
description: Audit how a project is built and packaged — Dockerfiles and compose files, dependency manifests and lockfiles, version pinning, reproducibility from a clean clone, image and package size, build speed and caching, multi-arch.
---

# Build audit

Assert explicitly that the build has no weak or uncovered cases and is optimised: for every item say OK,
give the finding, or n/a. No praise, no tour of the files.

## Common rules
- Target = the user’s requested target (path or `diff` = changes since the merge base with main, including staged, unstaged and relevant untracked files); otherwise every build-related file in
  the repo: Dockerfile*, compose files, .dockerignore, lockfiles and manifests, build scripts, Makefiles,
  toolchain version files, packaging configs.
- Read applicable AGENTS.md instructions, README and design notes first; judge against the project's stated goals and constraints.
  A deliberate, documented trade-off is not a finding.
- Never connect to servers, registries or deployments, and do not pull images or query package indexes.
  If something can only be verified live (image size, CVEs, latest versions, digest of a tag), give the
  user the exact command to run.
- Every finding cites `file:line` and a concrete consequence (cache busted on every commit, secret baked
  into a layer, build differs between two machines, image +800 MB). Re-read before reporting; mark
  anything not confirmed as *unverified*.
- Read-only: no edits during the audit. At the end offer to fix selected findings; if accepted, fix,
  run the build/tests where possible locally, report results faithfully.

## FNKC Projects

Compare env/inputs.sh with the files actually consumed by each Dockerfile. Trace an R lockfile change and a Positron-only update separately. Follow each native architecture from the pinned base through the runnable server layer, digest and provenance. Check which inputs go into the VSIX and server bundle as well as the images.

## 1. Map the build first
Briefly, for yourself: every artifact the project ships (images, packages, extensions, binaries), the
command that builds each one, its inputs (sources, base images, dependency sets, toolchains), and where
the same dependency is declared more than once.

## 2. Checklist

### Docker (when present)
- **Base image:** pinned by tag and ideally digest, minimal, maintained; no `latest`.
- **Cache order:** dependency manifests copied and installed before sources; `.dockerignore` excludes
  `.git`, node_modules, build output, local env files and secrets.
- **Stages:** multi-stage build; build tools absent from the runtime image; BuildKit cache mounts
  (`--mount=type=cache`) for package managers; `apt-get` with `--no-install-recommends` and list cleanup in
  the same layer.
- **Secrets:** none in layers, `ARG`s or `ENV`; use `--mount=type=secret`.
- **Runtime user:** non-root, correct ownership, read-only filesystem possible, no extra capabilities.
- **Process:** exec-form `CMD`/`ENTRYPOINT`, proper PID 1 / signal handling (`tini` / `--init`),
  `STOPSIGNAL`, `HEALTHCHECK` or equivalent.
- **Metadata:** OCI labels (version, revision, source); SBOM/provenance if the project uses them.
- **Multi-arch:** `TARGETARCH` handled, no amd64-only binaries on arm64, emulation pitfalls.
- **Compose / run flags:** restart policy, resource limits, log rotation, volumes for data that must
  persist, only needed ports exposed.

### Dependencies
- **Lockfiles** exist, are committed, are used by the build (`npm ci`, `renv::restore()`, `--frozen`),
  and agree with manifests.
- **Pinning:** toolchain versions pinned (Node, R, Python…) in one place; no floating ranges in what ships.
- **Hygiene:** unused, duplicated or dev-only dependencies in the runtime; heavy dependencies for trivial
  use; suspiciously old pins (*unverified* — give the command to check).
- **Sources:** package repositories/mirrors declared explicitly and consistently across Docker, lockfile
  and docs.

### Reproducibility and speed
- A clean clone builds with the documented commands only; no reliance on files or tools that exist only
  on the author's machine.
- Generated files: either always committed and checked, or never committed.
- Build scripts are portable across the platforms the project supports (macOS/Linux shells, BSD vs GNU
  tools).
- Biggest contributors to build time and artifact size, with the change that cuts each.

### Stack specifics (apply what is present)
- **R / renv:** `renv.lock` R version matches the image; repos snapshot pinned; binary packages used
  where available; system libraries for packages installed in the same stage; `renv` cache not baked into
  the image by accident.
- **Node / VS Code extension:** `package-lock.json` used; bundled (esbuild/webpack) rather than shipping
  node_modules; `.vscodeignore` excludes sources, tests, maps; `engines.vscode` matches APIs used.

## 3. Report (in the user's language)
1. **Verdict** — 2–4 sentences, top 3 fixes.
2. **Checklist tables** — one per section above: item · OK / issue / n/a · one-line note.
3. **Findings** for every "issue", most severe first:
   - **[Critical | High | Medium | Low] Title** — `file:line`
   - *Consequence:* …  *Fix:* specific change (diff sketch for Dockerfiles), expected gain if measurable.
4. **Commands to verify live** — what the user should run to confirm unverified items.
5. **Open questions** — intent you could not infer.

No vague advice ("optimise layers"): name the line and the change. Don't pad.
