# hex — swarm memory

Maintained by the hex skills. Small by contract: pointers and preferences,
not copies. Team-shared — commit it.

## Pointers

- Verification: `AGENTS.md` › "Workflow" — `task verify` (lint + unit tests
  + examples); `bazel test //...` for the offline subset.
- Spec / plan / ADR conventions: `AGENTS.md` › "Spec / plan / ADR
  conventions" — specs `.agents/specs/`, plans `.agents/plans/`, ADRs
  `.agents/adr/`, research `.agents/research/`; templates in
  `.agents/templates/`.
- Product knowledge: `AGENTS.md` › "Product".
- Key rules: `AGENTS.md` › "Invariants — do not violate";
  `.claude/rules/starlark.md`, `.claude/rules/release.md`,
  `.claude/rules/dist-snapshot.md` — the sha256 rows in `dist/dist.json`
  are the security boundary.
- Worktrees: default `.agents/worktrees/` (gitignored).

## Preferences

```yaml
# hex config, vocabulary v2. Unknown keys warn once and are ignored.
models:
  fast-balanced: sonnet
  deep-reasoning: opus
  overrides:
    builder:implement: deep-reasoning
    tester: deep-reasoning
    reviewer:quality: deep-reasoning
    reviewer:security: deep-reasoning
    reviewer:performance: deep-reasoning
    reviewer:spec: deep-reasoning
    reviewer:user-feedback: deep-reasoning
adversary: codex:rescue
```

- Model intent: Sonnet only for low/easy work (exploration, research, docs,
  stubs); everything non-trivial runs Opus. Fable is the session
  orchestrator only — never a spawn target.

## Memory

- Stardoc cannot build in a fresh agent worktree on this host — its
  renderer pulls a C++ toolchain (`cc1plus` is absent), so
  `bazel run //docs:update` fails there. It succeeds in the main checkout,
  whose output base already has the renderer built. Have workers edit the
  `.bzl` docstrings and regenerate `docs/` from the main checkout at merge.
- `.bazelignore` must list `.agents/worktrees` — Bazel does not read
  `.gitignore`, so `bazel test //...` otherwise globs into a live worktree's
  own `examples/` packages and fails to start.

- Last plan: `.agents/plans/plan_ocx-0-6-0-adoption.md` (State: done — hex-review
  round 2 Approve 2026-09-03; branch `hex/ocx-0-6-0-adoption`). No active plan. ADR: `.agents/adr/adr_0001_policy-tag-and-env-classes.md`.
  Research: `.agents/research/research_bazel-policy-surfaces.md`.
- The `codex:rescue` adversary runs as a fork that spawns a `codex-plan-review`
  forwarder; the fork's own task-notification fires *before* the review
  arrives, and the verdict lands later as a teammate message from the
  forwarder. Wait for that message, not the fork's completion.
- The `codex:codex-rescue` agent type, spawned directly (not via a fork), returns
  its code-diff verdict in its own idle notification — no forwarder wait.
- ocx 0.6.0 `pull`/`exec` stamp shell-activation consent unconditionally
  (`$OCX_HOME/state/projects/<key>/consent.json`); documented side effect,
  upstream ask ocx-sh/ocx#400 (`OCX_NO_CONSENT`) — when it lands, add one
  pinned row to `OCX_ENV_CLASSES` and drop the AGENTS.md caveat.
