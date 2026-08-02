# hex — swarm memory

Maintained by the hex skills. Small by contract: pointers and preferences,
not copies. Team-shared — commit it.

## Pointers

- Verification: `AGENTS.md` › "Workflow" — `task verify` (lint + unit tests
  + examples); `bazel test //...` for the offline subset.
- Plan / ADR conventions: `AGENTS.md` › "Spec / plan / ADR conventions" —
  plans `.agents/plans/`, ADRs `.agents/adr/`, research `.agents/research/`;
  templates in `.agents/templates/`.
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
