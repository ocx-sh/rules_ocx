# rules_ocx — Agent Entry Point

This is the cross-vendor entry point for AI agents that run **outside** the
Claude Code harness (e.g., Codex CLI, other `AGENTS.md`-aware tools).

**If you are Claude Code, stop reading this file** — use `CLAUDE.md` instead;
it is the authoritative project context and is auto-loaded by the harness.

## Where the real context lives

1. **`CLAUDE.md`** (repo root) — what rules_ocx is, architecture, design
   invariants, workflow, commit conventions. Start here.
2. **`.claude/rules/`** — focused procedure docs (Starlark style, dist
   snapshot updates, release procedure).

## Non-negotiable invariants

- Never re-implement OCX internals (OCI protocol, auth, index/store layout)
  in Starlark — shell out to the pinned `ocx` CLI.
- Extension impls do no host detection; repository rules do.
- Bump `DEFAULT_OCX_VERSION` and `dist/dist.json` together.

## General agent safety

- Use non-interactive shell flags (`cp -f`, `rm -f`, `apt-get -y`, …) —
  interactive aliases hang agents.
- **Never push to remote**; commit locally on a feature branch.
- Never commit directly to `main`.
- Run `task verify` after any implementation change.
