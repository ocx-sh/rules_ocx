# rules_ocx docs: use cases, comparable sites, page inventory

Plan D10 of [phase-3 pilots](https://github.com/ocx-sh/website/blob/main/.agents/plans/plan_phase3-pilots.md).
Date: 2026-10-07. Product shape: `library` (Bazel module extension; wrapper over the `ocx` CLI, so a
precondition sentence is required above the first fence). Ranking signal: `friction-log-severity`
(no issue-frequency or telemetry data exists; no friction log was run, so rankings below are
inferred from README caveats and e2e coverage and are a proposal, not a measurement).
Method: docs-plan procedure steps 1-3, 6-9; step 4 (friction log by a blind subagent) is open work
for the rewrite step.

## 1. Comparable sites

| Site | What it does well | Take for rules_ocx |
|---|---|---|
| [rules_python docs](https://rules-python.readthedocs.io/en/latest/) | Landing lists areas; migration guides ("from bundled rules", "to bzlmod") are first-class pages | Add a migration how-to (host tools / genrule to `@tools//`) |
| [rules_python getting started](https://rules-python.readthedocs.io/en/latest/getting-started.html) | One page: MODULE.bazel snippet, then a minimal target, then "next steps" links | Tutorial = MODULE.bazel + one `sh_test`, ends on a visible result |
| [rules_go](https://github.com/bazel-contrib/rules_go/blob/master/docs/go/core/rules.md) | Reference per rule with load statement, attribute table, providers; supplementary topic docs (cross-compilation) linked from it | Keep Stardoc reference as is; split topic prose out into explanation/how-to pages |
| [Aspect docs](https://aspect.build/docs/) | Three entry points by goal (cache, platform, CLI) rather than by rule | Landing offers entry points by goal, not by rule name |
| [Bazel hermeticity](https://bazel.build/basics/hermeticity) | Names the benefit (cache hits, coexisting tool versions) and how to detect host leakage (`/usr/bin`, Docker-isolated rebuild) | Basis for the "why" explanation and the "prove it is hermetic" check |
| [Bazelisk README](https://github.com/bazelbuild/bazelisk) | Version selection order, `BAZELISK_BASE_URL` mirror override, `tools/bazel` wrapper | Same audience, same mirror question: mirrors page must be task-first, env-var table second |
| [mise getting started](https://mise.jdx.dev/getting-started.html) | Linear flow: install, one-off `exec`, project pin, optional activation; links CI and troubleshooting out | First-steps ends on a verified result; optional steps marked optional |
| [asdf guide](https://asdf-vm.com/guide/getting-started.html) | Guide / Manage (reference) / Plugins split; `.tool-versions` as the single pin file | Explain `ocx.toml` + `ocx.lock` as the single pin pair |
| [devenv](https://devenv.sh/) | Problem, code, outcome pattern; real stacks as examples; CI page | Use-case pages follow problem, snippet, observable outcome |

Gaps seen: rules_python's landing shows no hermetic-toolchain or offline task page in the fetched
excerpt; asdf documents CI only by pointer. A task-first CI and air-gapped page is an opening.

## 2. Problems rules_ocx solves (from repo evidence)

| Problem | Evidence in repo |
|---|---|
| Hermetic tools without host install: `genrule`/`sh_test` use `jq`, `shellcheck` | `README.md` Quick start; `examples/package`, `e2e/package/jq_test.sh` |
| One pinned toolchain shared by Bazel and developers | `ocx.project(ocx_toml, ocx_lock)`; `e2e/project/{ocx.toml,ocx.lock,tools_test.sh}`; root `ocx.toml` dogfoods it |
| Reproducible CI: stale lock fails the fetch; no writes into checkout | README "Reproducibility"; `ocx lock --check` gate |
| Reproducible ad-hoc packages (`index`, `pins`, `@sha256:`) | README "Reproducibility", `examples/package` |
| Cross-platform binaries and exec/target transitions | `examples/cross_platform` (`transition.bzl`, `abi_test.sh`), `ocx_platform_constraints` in `docs/defs.md` |
| Air-gapped and corporate mirrors, proxy CA | README "Corporate mirrors"; `OCX_MIRRORS`, `OCX_INSTALL_MIRROR_URL`, `OCX_EXTRA_CA_CERTS`; `.claude/rules/mirror-auth.md` (mirror must allow anonymous read) |
| Remote-cache builds without downloading tools | README "Lazy provisioning" (`bins = [...]`); caveat: cold-machine race ocx-sh/ocx#179 |
| Locked-down trust posture and site config | README "Weakening posture", "Managed config & patches" (`ocx.policy`, `config`, `no_config`, `patch_snapshot`) |
| Silent traps: missing target raises no error; PATH scan exposes private binaries | README "Quick start" caveats; `OCX_SCANNED_PACKAGES` |

## 3. User needs (As a X, I need to Y, so that Z)

| ID | Need | Tier | Signal (inferred) |
|---|---|---|---|
| N1 | As a Bazel maintainer, I need to run `shellcheck` or `jq` in a rule without installing it on the host, so that every machine builds the same | first-steps | entry task; most README space |
| N2 | As a repo owner, I need one pin file for tools used by Bazel and by developers, so that versions cannot drift | everyday | project tier is flagship |
| N3 | As a CI engineer, I need a stale or tampered tool pin to fail the build, so that CI results are reproducible | everyday | lock-check behaviour in README |
| N4 | As a platform engineer, I need builds to work offline through an internal mirror, so that an air-gapped network can build | integration | longest README section |
| N5 | As a cross-compiling user, I need the right per-platform tool for exec versus target, so that a macOS host can build Linux outputs | everyday | dedicated example |
| N6 | As a remote-cache user, I need tool bytes kept out of action inputs, so that cache hits survive across machines | integration | lazy provisioning |
| N7 | As a security owner, I need to pin trust and config in the repo, so that the host cannot weaken fetches | integration | policy and managed-config sections |
| N8 | As a maintainer of a `genrule` + system-tool setup, I need a migration path, so that I can adopt ocx incrementally | first-steps/everyday | migration guides on rules_python |

## 4. Proposed page inventory

Existing pages: `docs/index.md` (landing, declared), `docs/defs.md` and `docs/extensions.md`
(Stardoc-generated: never edited; `diff_test` guards them; the port script adds frontmatter),
README (readme). Site pages are written by `site/scripts/port-docs.mjs` plus new hand-written
sources under `docs/`; Stardoc outputs stay golden.

| Page (site path under `/integrations/bazel/`) | doc_type | doc_tier | Need | Action |
|---|---|---|---|---|
| `/` landing: goal-based entry points (run a tool, pin a toolchain, go offline) | landing | first-steps | all | rewrite `docs/index.md` |
| `/tutorial/` Run shellcheck in a Bazel test without installing it | tutorial | first-steps | N1 | new; ends on a passing `sh_test` and a `bazel query @tools//...` listing |
| `/guides/pin-toolchain/` Share one toolchain between Bazel and developers | how-to | everyday | N2 | new; from `e2e/project` |
| `/guides/ci-reproducible/` Fail CI on a stale lock; freeze packages and patches | how-to | everyday | N3 | new; README Reproducibility, `ocx patch freeze` |
| `/guides/offline-mirror/` Build behind a corporate mirror or offline | how-to | integration | N4 | new; README Corporate mirrors, mirror-auth caveat |
| `/guides/cross-platform/` Use per-platform tools with transitions | how-to | everyday | N5 | new; `examples/cross_platform` |
| `/guides/remote-cache/` Keep tool bytes out of remote-cached actions | how-to | integration | N6 | new; Lazy provisioning |
| `/guides/migrate-host-tools/` Replace host-installed tools in existing rules | how-to | first-steps | N8 | new (optional, if budget allows) |
| `/concepts/how-it-works/` Why rules_ocx shells out to `ocx` and what is shared | explanation | everyday | N1-N3 | new; README How it works, hermeticity link |
| `/concepts/trust-and-config/` Policy, managed config and patches | explanation | integration | N7 | new; README sections split out |
| `/extensions/` | reference | everyday | all | keep (generated) |
| `/defs/` | reference | everyday | all | keep (generated) |
| `/reference/environment/` env vars passed through vs not | reference | integration | N4, N7 | new table, moved from README |

Minimum for C-004: tutorial plus 3 how-tos (pin-toolchain, ci-reproducible, offline-mirror), each
citing this note; cross-platform and remote-cache follow if budget allows.

## 5. Delete list

Nothing is deleted outright: the three existing docs pages pass both delete signals negatively
(they are linked and carry unique content). Moves, not deletes:
- `README.md` sections "Corporate mirrors", "Managed config & patches", "Reproducibility", "Lazy
  provisioning" shrink to a summary plus links to the site pages above (README is a readme, not the
  manual). Do this only after the new pages exist.
- `docs/_config.yml` and `.github/workflows/pages.yml` go at the Pages flip (D6), not in this step.

## 6. Open items for the rewrite step

- Run the friction log (docs-plan step 4) for N1 with a blind subagent; adjust ranking.
- Verify every snippet against `examples/` and `e2e/` before it enters a page; do not copy the
  README's `0.5.0` pin: use the current release.
- Tabs must not branch the tutorial (single non-branching path).
- Anchor parity: all 75 Stardoc `#ocx.*` anchors must still resolve (C-007).
