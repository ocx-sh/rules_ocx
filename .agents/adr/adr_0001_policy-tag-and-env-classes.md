# ADR: A root-only `ocx.policy` tag, and env vars classified once

## Metadata

**Status:** Accepted
**Date:** 2026-09-02
**Deciders:** owner
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**
- [x] Decision follows this project's stated architectural conventions /
      golden path
- [ ] OR the deviation is justified in the Rationale section below
**Domain Tags:** security, integration, infrastructure
**Supersedes:** N/A
**Superseded By:** N/A

## Context

ocx 0.6.0 adds signature verification to the fetch path. It attaches only when
the operator's site `config.toml` carries a `[[trust.policy]]` table
(`crates/ocx_cli/src/app/context.rs:498`); a project's own `ocx.toml` is never
consulted for policy. Two ambient environment variables can weaken what a build
verifies or accepts:

- `OCX_NO_VERIFY` turns signature verification off. `ocx package install` (and
  `ocx package pull`, which rules_ocx does not call) also take
  `--verify` / `--no-verify`, and the flag outranks the variable
  (`crates/ocx_cli/src/options/verify.rs`, `SignatureVerify`). The project-tier
  `ocx pull`, `ocx env`, `ocx package which` and `ocx package env` take no such
  flag and follow the variable alone — verification is attached once on the
  shared manager in `Context::try_init` from `OCX_NO_VERIFY`
  (`context.rs:483-494`).
- `OCX_ALLOW_YANKED` admits yanked releases and is env-only in 0.6.0
  (`context.rs:286,815`) — there is no flag and no project-file rung.

`OCX_ALLOW_YANKED` is on today's `OCX_PASSTHROUGH_ENV` list, so a rules_ocx
build already inherits it from whatever shell or CI runner started Bazel.
`OCX_NO_VERIFY` is new and, left alone, would be inherited the same way. That
is the wrong default for a security control: an environment variable exported
three layers up in a CI image would silently decide whether a monorepo's tools
are verified, and nothing in `MODULE.bazel` would record it.

Three smaller 0.6.0 changes ride along and are in scope here because they touch
the same surfaces: the sigstore trusted-root ladder gains an
`OCX_SIGSTORE_TRUSTED_ROOT` rung and an `$OCX_HOME/sigstore/trusted-root.json`
rung; three new sysexits (83, 84, 85) become reachable from the fetch path; and
`ocx run` is hidden-and-warning in 0.6 and deleted in 0.7, so the lazy project
launcher must re-enter `ocx exec` instead.

Separately, the env handling in `ocx/private/repo_utils.bzl` has grown three
loose structures — `OCX_PASSTHROUGH_ENV` (a list), `_OCX_NEUTRALIZED_ENV` (a
dict) and an inline `[(env var, attr)]` pair list inside `make_ocx_env()` — plus
a fourth, `no_config`'s hard-coded blanking set. Adding two more variables with
a *third* behaviour (never read from the environment at all) to that shape means
four places to keep in agreement.

## Decision Drivers

- A security control must be declared where it is reviewable — in
  `MODULE.bazel`, next to the dependency graph — not inherited from ambient
  state.
- Repository rules are unsandboxed and see the real environment; every variable
  that reaches ocx is either tracked (`getenv`, invalidating) or pinned. There
  is no third option that stays hermetic.
- Host config tiers stay first-class: fleet distribution is managed config
  (0.6.0 ships the trusted root inline in managed-config packages), and the
  repository rules watch those tiers. A Bazel-side attr is the *additional*
  route — for a repo that wants trust material in-tree, and for remote
  executors running lazy launchers with no `OCX_HOME`.
- Extension impls must stay a pure function of tags (invariant 3); all env and
  host access belongs to repository rules.
- Public API is a one-way door: a tag class name, its attr names and their
  defaults cannot be renamed after a release without breaking every consumer's
  `MODULE.bazel`.
- Never re-implement ocx internals in Starlark (invariant 1) — rules_ocx passes
  flags and variables, it does not verify signatures.

## Industry Context & Research

**Research artifact:** `.agents/research/research_bazel-policy-surfaces.md`
**Trending approaches:** root-only tag classes gated on `module.is_root`
(rules_python, rules_go `go_sdk`, toolchains_llvm, rules_rust, rules_scala);
"default-plus-root-override", where the extension applies a safe default for
every module and only the root may loosen it (bazelbuild/bazel#22024).
**Key insight:** the ecosystem majority *silently ignores* a non-root
customization tag. rules_ocx already `fail()`s on a non-root `download` or
`project` tag (`ocx/extensions.bzl:200,218`), and for a security policy a silent
drop is the worse failure mode — a dependency writing
`ocx.policy(allow_unverified = True)` should stop the build, not be quietly
ignored while the author believes it took effect.

## Considered Options

The decision has two axes: where the policy surface lives, and what happens to
the ambient weakening knobs.

### Axis 1 — Option A: attrs on the existing `ocx.download` tag

**Description:** `ocx.download` is already root-only and at-most-one. Add
`allow_unverified` / `allow_yanked` / `sigstore_trusted_root` to it.

| Pros | Cons |
|------|------|
| No new tag class; root-only and at-most-one already enforced | Conflates CLI bootstrap with build policy: `ocx.download` answers "which ocx binary", not "what may this build install" |
| Smallest diff | Forces a root that only wants a policy to also opt into the bootstrap-override tag, whose other attrs (`version`, `triple`, `dist_manifest`) then read as deliberate pins |
| | The one-way door lands on the wrong tag: policy would be stuck under a bootstrap name forever |

### Axis 1 — Option B: a new root-only `ocx.policy` tag class (chosen)

**Description:** `ocx.policy(allow_unverified = False, allow_yanked = False,
sigstore_trusted_root = None)`; root module only, at most one per build. The
extension threads the resolved values into every `ocx_project_repo` and
`ocx_package_repo` it declares.

| Pros | Cons |
|------|------|
| Names the concern: one tag, one question ("what may this build install") | A new public tag class — a one-way door on the name and three attr names |
| Root-only matches who owns the answer: the workspace, not a dependency | Slightly more extension code than Option A |
| Applies to `ocx.package` tags declared by *dependencies*, which is exactly the case ambient env handles worst | A root that declares no policy still gets the defaults, so the tag is invisible in most builds (mitigated: the defaults are the safe ones) |
| Extends without breaking: a later knob is a new attr with a safe default | No per-package exception today (a hybrid "root default plus root-settable per-tag override" is additive later, not a one-way door) |

### Axis 1 — Option C: per-tag attrs on `ocx.project` / `ocx.package`

**Description:** No root policy; each `project`/`package` tag carries its own
`allow_unverified` / `allow_yanked`.

| Pros | Cons |
|------|------|
| Finest granularity | `ocx.package` is *not* root-only: a dependency could set `allow_unverified = True` on its own package and the root would have no veto — the opposite of what is wanted |
| No new tag class | Repeats the same policy on every tag; drift between them is silent |
| | No single place a reviewer can read the build's posture off |

### Axis 2 — Option D: keep forwarding the ambient weakening knobs

**Description:** Leave `OCX_ALLOW_YANKED` on the passthrough list, add
`OCX_NO_VERIFY` next to it, both `getenv`-tracked.

| Pros | Cons |
|------|------|
| No breaking change | An exported variable in a CI image silently decides verification for every build on that runner |
| Tracked, so a change does invalidate the fetched repos | Tracked-and-wrong is still wrong: invalidation records *that* the answer changed, never that it was weakened |
| | Two builds of the same commit on two machines can differ in what they verified, with nothing in the sources to explain it |

### Axis 2 — Option E: neutralize the ambient value, drive it from the attr (chosen)

**Description:** Both variables become *explicit-only*: never read with
`getenv`, always written into the invocation environment from the `ocx.policy`
attr. `allow_unverified = True` additionally passes `--no-verify` on
`ocx package install`, the one command rules_ocx calls that accepts it.

| Pros | Cons |
|------|------|
| The build's posture is a function of the sources alone | **Breaking:** `OCX_ALLOW_YANKED` stops working as an ambient escape hatch |
| Deterministic across machines, CI runners and remote executors | An operator who relied on the variable must edit `MODULE.bazel` — a visible, reviewable edit, which is the point |
| Removes two variables from the invalidation surface entirely | |

## Decision Outcome

**Chosen Option:** Option B (a root-only `ocx.policy` tag class) on axis 1, and
Option E (neutralize the ambient knobs, drive them from the attrs) on axis 2.

**Rationale:** The two axes reinforce each other. Neutralizing the ambient
variables removes the only way to answer the question, so the answer has to move
somewhere declared; a root-only tag is the only place in a bzlmod graph where
the workspace owner — and only the workspace owner — can answer it, including
for `ocx.package` tags a dependency declared. Option A would have got the same
enforcement for free but permanently filed "what may this build install" under
the CLI-bootstrap tag. Option C hands the answer to whoever wrote the
dependency.

The attr is named `allow_unverified` (default `False`), not `verify`
(default `True`): rules_ocx cannot *enable* verification — ocx attaches it only
under an operator `[[trust.policy]]` — so a `verify = True` attr would read as a
guarantee it cannot make. `allow_unverified` states what is true and pairs with
`allow_yanked` as two default-off weakening opt-ins.

A non-root `ocx.policy` instance `fail()`s rather than being silently ignored.
This departs from the ecosystem majority and follows the sibling tags in this
same extension; for a security surface, a loud stop beats a quiet drop.

"A function of the sources alone" applies to the *weakening* knobs. Trust
material (the trusted root) is translucent by design: site-authoritative —
including the action environment of a lazy launcher on a remote executor —
unless the root pins it in-tree with `sigstore_trusted_root`. A lazy launcher
therefore exports the pinned rows, the policy pair and any *staged* label, and
deliberately nothing for an unset translucent attr.

Verification itself stays entirely inside the ocx CLI (invariant 1). rules_ocx
passes a flag and a variable and maps the resulting exit codes to hints — it
never touches sigstore, TUF or Rekor.

Bootstrap mirror knobs (`OCX_INSTALL_DIST_URL`, `OCX_INSTALL_MIRROR_URL`) stay
env-only. They are site settings — a corporate mirror is per machine, not per
`MODULE.bazel` — and the official installers expose exactly these variables, so
parity argues for env, not attrs. The one bootstrap addition is the
self-verifying `dist/<sha256>.json` manifest form www-setup publishes.

### Quantified Impact (where applicable)

| Metric | Before | After | Notes |
|--------|--------|-------|-------|
| Ambient env vars that can weaken a fetch | 4 (`OCX_ALLOW_YANKED`, `OCX_NO_VERIFY` had it been forwarded, `OCX_MIRRORS`, `OCX_INSECURE_REGISTRIES`) | 3 (`OCX_SIGSTORE_TRUSTED_ROOT`, `OCX_MIRRORS`, `OCX_INSECURE_REGISTRIES`) | the policy pair becomes explicit-only; the residual three stay ambient by design (site-authoritative). `OCX_SIGSTORE_TRUSTED_ROOT` replaces the trust anchor every signature is checked against whenever no `sigstore_trusted_root` attr is set; the mirror pair redirects transport. Mitigation: set `sigstore_trusted_root`, and pin digests. |
| `getenv`-forwarded vars | 14 | 14 | `OCX_ALLOW_YANKED` leaves, `OCX_SIGSTORE_TRUSTED_ROOT` joins |
| Structures encoding env behaviour in `repo_utils.bzl` | 4 | 1 | one classified table |
| Mapped sysexits | 10 | 13 | 83, 84, 85 |
| Minimum ocx version | none | 0.6.0 | `ocx exec`, `--no-verify` |

### Consequences

**Positive:**

- What a build verifies and accepts is readable off `MODULE.bazel` and diffable
  in review.
- Two machines fetching the same commit make the same trust decisions.
- One table replaces four structures, so a new ocx variable is one row plus its
  class, not four edits that can disagree.
- A dependency attempting to loosen policy stops the build with a message
  naming the module.

**Negative:**

- **Breaking:** `OCX_ALLOW_YANKED` no longer reaches ocx from the environment.
  An operator who used it must write `ocx.policy(allow_yanked = True)`.
- **Breaking:** ocx < 0.6.0 is refused by `ocx_download`. A consumer pinning an
  older CLI with `ocx.download(version = …)` must move the pin.
- Three attr names and one tag class name are now public API and cannot be
  renamed inside a major line.
- `ocx.policy()` with defaults does not *enable* verification — it refuses to
  disable it. Verification attaches only where the operator's config carries
  `[[trust.policy]]`, so on a machine without one the default is a no-op. This
  is inherent to ocx's design and must be stated in the attr doc.
- `no_config = True` prunes the discovered config tiers, which is where a
  site `[[trust.policy]]` lives — so unless a `config` label carries one,
  verification is off whatever `allow_unverified` says. Documented rather than
  refused, because the defaults would otherwise break every existing
  `no_config` user.
- `isolated_home = True` relocates `OCX_HOME` into the repository, so ocx's
  rung-4 convention path `~/.ocx/sigstore/trusted-root.json` is no longer found
  there; with a trust policy configured, resolution falls through to the Rekor
  cache and TUF rungs and can fail offline. Stated in the `isolated_home` attr
  doc, not only the trust-root one.
- Every lazy launcher is re-keyed once: it now exports `OCX_NO_PROJECT=1`,
  `OCX_NO_CONFIG_REFRESH=1` and the policy pair alongside the existing
  `OCX_PROJECT`/`OCX_GLOBAL` lines. It lands in the same release as the
  `run` → `exec` change, which re-keys them anyway.

**Risks:**

- *The floor is the wrong lever if a consumer needs an older CLI.* Mitigation:
  the `fail()` names both the floor and the two reasons for it (`ocx exec`,
  `--no-verify`), so the reader can decide between moving the pin and pinning
  an older rules_ocx.
- *The trusted-root watch fails open.* `$OCX_HOME/sigstore/trusted-root.json` is
  hand-constructed from OCX_HOME layout; relocate it upstream and the watch
  silently covers nothing. Mitigation: same as the managed-config paths — the
  `update-dist` skill re-verifies the layout on every ocx bump, and this path
  joins that list.
- *A self-verifying dist manifest fails open on an unexpected URL shape.* A
  mirror serving `dist.json` under any other name is downloaded unverified,
  exactly as today. Mitigation: the artifact sha256 inside the manifest remains
  the real security boundary; the manifest hash is defence in depth, not a new
  guarantee. The `dist/<sha256>.json` shape is a www-setup convention
  (`dist_pin_digest` in `src/install.sh`) and joins the `update-dist` re-verify
  list and the `starlark.md` carve-out.

## Non-Functional Requirements

| Axis | Impact of this decision |
|---|---|
| Scalability | Not affected. One extra flag on `package install` when loosened; no new subprocess. |
| Availability | Verification adds a Rekor / transparency-log dependency to the fetch path *when the operator enables it* — sysexit 83 becomes reachable and is mapped to a retry-or-loosen hint. Not auto-retried (a settled outage would cost three round-trips); revisit after the first flaky-CI report. |
| Latency | A signature check per installed package, inside ocx. Unchanged when no `[[trust.policy]]` is configured. |
| Security | The point of the ADR: two ambient weakening knobs removed, the trust root becomes a declarable, watched input, and the dist manifest can verify its own body. |
| Cost | Not affected. |
| Operability | Breaking for operators who used `OCX_ALLOW_YANKED`; the fix is one line in `MODULE.bazel`. `bazel fetch --force` is still the answer after a credential change (`OCX_AUTH_*` cannot be enumerated). |

## Technical Details

### Architecture

```
MODULE.bazel
  ocx.policy(allow_unverified, allow_yanked, sigstore_trusted_root)   [root only, ≤1]
        │  resolve_policy()  (pure; returns error string, extension fail()s)
        ▼
  _ocx_impl ──┬─► ocx_project_repo(**POLICY_ATTRS)
              └─► ocx_package_repo(**POLICY_ATTRS)      (hub gets none: no ocx calls)
                        │
                        ▼  make_ocx_env()  — one classified table, OCX_ENV_CLASSES
        explicit    (2)  OCX_NO_VERIFY, OCX_ALLOW_YANKED             from attrs, ambient ignored
        translucent (4)  OCX_CONFIG, OCX_PATCH_SNAPSHOT,
                         OCX_SIGSTORE_TRUSTED_ROOT, OCX_NO_CONFIG    attr, else ambient (+watch)
        site        (10) OCX_MIRRORS … OCX_PATCHES                   ambient, getenv-tracked
        pinned      (5)  OCX_PROJECT "", OCX_GLOBAL "0", OCX_QUIET "0",
                         OCX_NO_PROJECT "1", OCX_NO_CONFIG_REFRESH "1" fixed
                        │
                        ├─► eager: package install carries --no-verify when allowed
                        └─► lazy:  the launcher re-exports the policy pair + pinned rows
```

### API Contract

```python
ocx.policy(
    allow_unverified = False,       # also passes --no-verify to `package install`
    allow_yanked = False,           # OCX_ALLOW_YANKED, attr-only
    sigstore_trusted_root = None,   # label; OCX_SIGSTORE_TRUSTED_ROOT
)

ocx.download(
    version = "",                   # ≥ 0.6.0; mirror knobs stay OCX_INSTALL_* env
)
```

### Data Model

One table in `repo_utils.bzl`, keyed by environment variable name, each row
carrying its class plus the attr it reads (translucent, explicit), the fixed
value it writes (pinned), and whether `no_config` blanks it. Detailed contracts
live in the plan (`.agents/plans/plan_ocx-0-6-0-adoption.md`).

## Implementation Plan

1. [ ] Classified env table + `make_ocx_env()` / `stage_lazy_config()` /
       `render_lazy_launcher()` rewritten onto it.
2. [ ] `POLICY_ATTRS`, `resolve_policy()`, the `ocx.policy` tag class, extension threading.
3. [ ] `--no-verify` argv on `package install` when `allow_unverified`.
4. [ ] Sysexits 83/84/85; `$OCX_HOME/sigstore/trusted-root.json` watched outside the `no_config` gate.
5. [ ] `ocx_download`: 0.6.0 floor, self-verifying `dist/<sha256>.json` manifest.
6. [ ] Lazy project launcher `ocx run` → `ocx exec`; docs and doc strings.
7. [ ] Pin bump: `python3 scripts/bump_ocx.py --version 0.6.0`, then `task verify`.

## Validation

- [ ] Guard tests red before the guard exists (per `.claude/rules/starlark.md`).
- [ ] `bazel test //...` — unit tests plus docs freshness.
- [ ] `task verify` — lint, unit tests, examples against the live registry
      (the examples exercise all four parsed JSON shapes against the pinned
      binary; that run is what lets AGENTS.md say "verified against 0.6.0").
- [ ] Security review: no ambient variable can weaken a fetch; no ocx internals
      re-implemented in Starlark.

## Resolved Questions

- **Does `no_config = True` blank `OCX_SIGSTORE_TRUSTED_ROOT`?** No. A trust
  root is not a config tier. With `no_config` and no `config` label there is no
  operator policy, so no trust root is read at all; with `no_config` plus a
  `config` label that carries `[[trust.policy]]`, ocx reads the env rung and
  then `$OCX_HOME/sigstore/trusted-root.json` — so the env value must survive
  and the home path must be watched *outside* the `no_config` gate.
- **`no_config = True` silently removes the discovered tier carrying
  `[[trust.policy]]` — warn, or document?** Document in both attr docs. The
  defaults are the safe ones, so a warning would fire for every existing
  `no_config` user and be unactionable.
- **Rename `ambient_config_paths()` once it also returns the trust root?** No
  rename. The trust root is watched by a separate `sigstore_trust_root_path(home, is_windows)`
  helper because it sits outside the `no_config` gate; `ambient_config_paths()`
  keeps its name and its meaning. `.claude/rules/starlark.md` names both.

## Deferred (owner)

- A hybrid "root default plus root-settable per-tag override" (one vendor's
  yanked pin while the graph stays strict) is additive later. Not built now.
- Adding 83 to the retry set once transparency-log flakiness is observed.

## Links

- Related ADR: N/A (first ADR in this repo)
- Research: `.agents/research/research_bazel-policy-surfaces.md`
- `is_root` semantics: https://github.com/bazelbuild/bazel/discussions/22024
- skylib version helpers: https://github.com/bazelbuild/bazel-skylib/blob/main/lib/versions.bzl

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-09-02 | architect | Initial draft, accepted |
| 2026-09-02 | hex-plan review | `verify` → `allow_unverified`; `--no-verify` only on `package install`; mirror attrs dropped (env-only site knobs); `OCX_NO_PROJECT` pinned `1`, `OCX_CEILING_PATH` row dropped; trust root watched outside the `no_config` gate via a separate helper; questions resolved |
