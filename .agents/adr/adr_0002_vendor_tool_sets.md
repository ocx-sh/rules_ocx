# ADR: Build tool sets from `ocx vendor`

## Metadata

**Status:** Accepted
**Date:** 2026-11-26
**Deciders:** owner
**Issue/Ticket:** N/A
**Related PRD:** N/A
**Architectural Conventions:**
- [x] Decision follows this project's stated architectural conventions /
      golden path
- [ ] OR the deviation is justified in the Rationale section below
**Domain Tags:** integration, infrastructure
**Supersedes:** adr_0001 in part (the fetch path; the policy tag and env-class decisions stand)
**Superseded By:** N/A

## Context

rules_ocx provisions tools through the `ocx` binary and never re-implements OCX internals in Starlark.
A tool must run in a local action and on a remote executor that has no network, no `ocx` and no `OCX_HOME`.
The ruleset needs one stable thing to read from `ocx`, so that a change in how `ocx` stores packages or reports state cannot break it.

`ocx vendor` writes that thing for one platform: the package files, one native launcher per tool and a `manifest.json` (`schema_version` 1).
The manifest lists packages, tools, links, the environment each tool needs and the platforms available.

## Decision Drivers

- Remote execution: actions carry their inputs and run nothing else.
- One document to parse, versioned, instead of several command reports.
- Reproducibility: the tool list must be a function of `ocx.lock` or of a digest-pinned identifier.
- Bazel 9 is the floor.

## Considered Options

### Option 1: Vendor, then read the manifest

**Description:** A set repository runs `ocx vendor` for its platform and generates its `BUILD.bazel` from `manifest.json`.
The extension computes the tool list once per tag and platform with `ocx vendor --manifest-only` and stores it as a fact in `MODULE.bazel.lock`.

| Pros | Cons |
|------|------|
| Actions need no `ocx`, no network, no home | A set repository holds a full copy of its packages |
| One versioned document is the whole contract | Needs an `ocx` release with `ocx vendor` |
| Facts make a locked checkout run no `ocx` at analysis | Facts must be recomputed when the lock changes |

### Option 2: Launch through `ocx` at action time

**Description:** Each tool is a launcher that starts `ocx exec` at run time and lets `ocx` resolve and provision on demand.

| Pros | Cons |
|------|------|
| Small repositories | Every executor needs `ocx`, a home and the network |
| | Not usable under remote execution |

## Decision Outcome

**Chosen Option:** Option 1.

**Rationale:** It is the only option under which an action needs nothing from the executor except its inputs, and it reduces the dependency on `ocx` to one document.

### Consequences

**Positive:**
- Remote execution works, and a digest-pinned tool gives the same action key on every machine.
- The ruleset parses `manifest.json` and no other `ocx` output.
- `ocx` runs only when Bazel fetches a repository.

**Negative:**
- The supported `ocx` is the first release that carries `ocx vendor` and later (`MIN_OCX_VERSION`). Nothing else is supported.
- A Windows set cannot carry symlinks, because Bazel declares none there.
- Empty directories of a package are not visible to actions on a remote executor.

**Risks:**
- A manifest with another `schema_version` fails the fetch and names both sides.
- The ruleset hard-codes the config paths it watches, and a relocated path fails open; the `update-dist` skill lists them for every bump.

## Technical Details

### Contract

- `ocx vendor -o <dir> -p <platform> --omit-links [-g …] [names…]` for a project, `ocx package vendor` for a package.
- Output: `manifest.json`, `packages/`, `selections/`.
- Each tag declares a hub repository named by the tag and one set repository per entry of `platforms`.
- Launchers find their `.direct` sidecar beside themselves, then in the runfiles tree; without either they exit 78.

## Links

- [`adr_0001_policy-tag-and-env-classes.md`](adr_0001_policy-tag-and-env-classes.md): the policy tag and the env classes, which this decision keeps.
- [The vendor model](../../docs/concepts/design.md)
- [`AGENTS.md`](../../AGENTS.md)

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-11-26 | owner | Initial record |
