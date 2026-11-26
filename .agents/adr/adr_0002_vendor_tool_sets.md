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

`ocx vendor` writes that thing for one platform: the package files, one native launcher per tool and a `manifest.json` (`schema_version` 2, ADR 0003).
The manifest lists packages, tools, links, the environment each tool needs and the platforms available.

## Decision Drivers

- Remote execution: actions carry their inputs and run nothing else.
- One document to parse, versioned, instead of several command reports.
- Reproducibility: the tool list must be a function of `ocx.lock`, of an index snapshot, of a digest-pinned identifier, or of the platform manifest digests a fact records for a tag ([ADR 0003](adr_0003_package_locking.md)).
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

- `ocx vendor -o <dir> -p <platform> --omit-links [-g …] [names…]` for a project, `ocx package vendor` for a package. A package declared by tag without an index, or by digest, is vendored as `repo@<platform manifest digest>` from its fact ([ADR 0003](adr_0003_package_locking.md)).
- Output: `manifest.json` and what it lists. The layout of ocx issue 785 is `l/NAME` (selection launchers), `p/HEX16/c/` (package content), `p/HEX16/e/NAME` (entry-point launchers), and one record file `NAME.launch` beside each launcher (JSON; `kind` is `direct` in a vendored tree). It replaces `packages/`, `selections/` and the `.direct` sidecar.
- `manifest.json` is the one file name rules_ocx knows. The set repository moves every top-level entry of the output directory into the repository; it takes every launcher path and every record path from the manifest (`tools[].launcher_path`, `tools[].record_path`, `entrypoints[].launcher_path`, `entrypoints[].record_path`) and derives no `.exe`, no sidecar name and no directory name. The required fields are MR-1 to MR-14 of ADR 0003.
- `_ocx_reserved` stays rules_ocx's own stash name for Bazel-reserved file names (`ocx/private/set_repo.bzl:16`); ocx never writes it.
- Each tag declares a hub repository named by the tag and one set repository per entry of `platforms`.
- A launcher finds its record beside the path it was started by, and its root through the runfiles tree, then through Bazel's runfiles manifest; with neither it exits 78.

### Runfiles

Decision: keep the runfiles-tree lookup, and add a runfiles-manifest lookup for the case without a tree.

Why the lookup goes through runfiles at all:

- In a `processwrapper-sandbox` action the set exists only under `TOOL.runfiles/`; `external/SET` is absent (`observed`, ocx research `research_launcher-atomic-publish-and-runfiles.md` § 5).
- The source tree of the set repository is incomplete. Links are generated outputs declared in the set package (`ocx/private/set_rules.bzl:30-35`), so a launcher started from the source tree misses them: `npm` and `npx` fail with exit 74 there (`observed`, same § 5). Bazel-reserved file names are moved to `_ocx_reserved/<n>` and restored as outputs at their original path (`set_rules.bzl:37-44`), so they too exist only in the outputs.
- Bazel offers no documented way for a prebuilt program to learn its repository directory at run time (https://bazel.build/external/extension).

What the lookup costs (`observed`, Bazel 9.2.0, same § 5): 7 file system calls in-tree and 14 through the hub path. Over 300 runs of `jq --version` the median was 1,059 µs in-tree, 1,140 µs through the hub and 489 µs for the binary started directly; the research puts the cost of the lookup at about 75 µs. For node the difference is inside the noise.

Why `--omit-links`: a set is a tree of source files to Bazel. The remote upload of a source directory follows links and sends copies (`read`, same § 5), so a link ocx wrote into the repository would reach the executor as a copy or dangle. `ocx vendor --omit-links` writes no link and lists each one in `tree.links`; rules_ocx declares it with `declare_symlink` in the set's own package (`set_rules.bzl:30-35`), never as `root_symlinks` of another repository's rule, which crashes Bazel 9.2.0 in the exec configuration (`set_rules.bzl:30-31`). Windows sets refuse links (`set_repo.bzl:214-233`).

Windows: `--enable_runfiles` defaults to off there, and only the manifest is written (research `research_bazel-extension-facts-lock.md` § 5). With the manifest lookup a Windows build needs neither `--enable_runfiles` nor `startup --windows_enable_symlinks` for a vendored tool. This is a claim until the Windows leg of `verify-deep.yml` runs `examples/cross_platform:manifest_runfiles_test` green (ADR 0003 § Test plan). rules_ocx's own `.bazelrc:7-9` keeps both lines for its `sh_test`s.

## Links

- [`adr_0001_policy-tag-and-env-classes.md`](adr_0001_policy-tag-and-env-classes.md): the policy tag and the env classes, which this decision keeps.
- [The vendor model](../../docs/concepts/design.md)
- [`AGENTS.md`](../../AGENTS.md)

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-11-26 | owner | Initial record |
| 2026-11-26 | owner | Amended by ADR 0003: short layout (`l/`, `p/HEX16/c/`, `p/HEX16/e/`), launcher and record paths read from the manifest, the § Runfiles position with its measured cost and reasons, `--omit-links` reasons, the runfiles-manifest lookup for Windows |
| 2026-11-26 | owner | review round 1 applied: a digest-pinned package is also vendored by its platform manifest digests |
| 2026-11-26 | goal loop | reconciled with the ocx record `adr_unified_launcher.md`: `schema_version` 2 only, record `NAME.launch` decided, record found beside the started path and the root through tree then manifest |
