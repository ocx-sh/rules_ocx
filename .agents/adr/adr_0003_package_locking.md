# ADR: Package locking, update targets, and paths read from the vendor manifest

## Metadata

**Status:** Accepted (accepted under goal-loop authority, 2026-11-26; the owner may revisit)
**Date:** 2026-11-26
**Deciders:** owner
**Issue/Ticket:** https://github.com/ocx-sh/rules_ocx/issues/37, https://github.com/ocx-sh/ocx/issues/785
**Related PRD:** N/A
**Architectural Conventions:**
- [x] Decision follows this project's stated architectural conventions /
      golden path
- [ ] OR the deviation is justified in the Rationale section below
**Domain Tags:** integration, infrastructure, persisted format
**Supersedes:** the rule "a floating tag gets no fact and the extension is not reproducible" (`ocx/private/facts.bzl:36-49`, `ocx/extensions.bzl:319-322`, `docs/concepts/design.md:36-37`)
**Superseded By:** N/A
**Amends:** [`adr_0002_vendor_tool_sets.md`](adr_0002_vendor_tool_sets.md) § Contract (layout, record files, runfiles lookup)

**Classification:** blast radius cross-area (rules_ocx, plus manifest and behaviour requirements on `ocx`, listed as MR-1 to MR-14). One-way door, medium: the fact JSON is persisted in users' `MODULE.bazel.lock`, and the `update` targets are user-facing names.

## Context

A package declared by tag is not locked today.
`fact_cacheable` returns false for a package identifier without a digest (`ocx/private/facts.bzl:36-49`).
The extension then records no fact and reports `reproducible = False` (`ocx/extensions.bzl:319-322`).
Every set repository resolves the tag when it is fetched, so a moved tag changes the build without any edit.
A user who pins a digest often pins the image index, and a registry may drop an index once no tag points to it (zot 2.1.21 answered 404, observed in the earlier prototype, issue 37 text).

The project tier does not have this problem: `ocx.lock` holds one platform manifest digest per platform.

The owner fixed four rows (issue 37 comment, goal file § Second run, rules_ocx items 1-4):

| Declaration | Its lock | What `update` does |
|---|---|---|
| `ocx.project` | `ocx.lock` | runs `ocx update` |
| `ocx.package` with `index` | the committed index snapshot | runs `ocx --index DIR index update PACKAGE` |
| `ocx.package`, tag, no digest, no `index` | one platform manifest digest per listed platform, as a fact in `MODULE.bazel.lock` | resolves the tag again |
| `ocx.package` with a digest | the identifier | reports that it is pinned |

Owner rules that bind this record (goal file § Rules):

- "we cannot lock an index but only manifests": a lock holds platform manifest digests only.
- `manifest.json` is the only interface between `ocx vendor` and rules_ocx; rules_ocx derives no file name.
- "do not re-implement any env/package content or other construction methods".
- The new vendored layout of ocx issue 785: `manifest.json`, `l/NAME`, `p/HEX16/c/`, `p/HEX16/e/NAME`, one record file `NAME.launch` beside each launcher.
- The launcher gains a runfiles-manifest lookup, so a Windows build needs no `--enable_runfiles`.

Three more facts shape the design.

- rules_ocx still derives names: `_TOP_LEVEL` (`ocx/private/set_repo.bzl:19`), `_sidecar()` (`set_repo.bzl:24-27`), the `.exe` and `.direct` names of `ocx_tool` (`ocx/private/set_rules.bzl:109-113`), and the `packages`/`selections` prefix checks (`ocx/private/vendor_manifest.bzl:290,385,401,404`). `read`.
- A tag on a fresh `OCX_HOME` fails today, because the extension runs `ocx vendor --manifest-only` without `--remote` (`observed`, research `research_launcher-atomic-publish-and-runfiles.md` § 6).
- What ocx reports for a platform manifest digest is settled by the ocx record (`adr_unified_launcher.md` R-U9, ocx repository): `ocx` vendors a bare platform manifest for the requested `-p P`, reports `platform = P` and `available_platforms = ["any"]`, and refuses nothing, because a bare manifest records no platform (`read`, ocx `crates/ocx_package_manager/src/tasks/vendor.rs:310-312`). The earlier prototype agrees: its sets vendored `registry/repo@<platform digest>` with `-p` and built (`observed`, `proto/EVIDENCE.md` T10). A set that vendors a pin therefore does not compare `available_platforms`, and the platform check is rules_ocx's, at resolve time (step 9).

### What Bazel guarantees (research `research_bazel-extension-facts-lock.md`)

- A fact is persisted in `MODULE.bazel.lock`, survives a code change, and is replaced by what the run returns; a fact the run does not return is dropped (§ 1, `observed` T7).
- No flag re-resolves a fact. `--lockfile_mode=refresh` does not touch facts. A value read with `module_ctx.getenv` is a recorded input, so a changed `--repo_env` re-runs the extension with the old facts still passed in (§ 2).
- Under `--lockfile_mode=error` a fact miss still runs the extension, then fails "MODULE.bazel.lock is no longer up-to-date because the extension '…' has changed its facts" (§ 2, `observed`). The lockfile documentation says `error` mode makes no network request during resolution (https://bazel.build/external/lockfile); the observation contradicts it, and this record follows the observation.
- With `reproducible = True` the extension runs once per changed input or new output base, and a fact hit makes no request (§ 3, `observed`). The hidden lockfile that caches this is documented as "only a performance optimization" (https://bazel.build/external/lockfile). The committed fact is the authority; the cache only saves runs.
- A `bazel run` binary may call `bazel` again in the same workspace and output base; the client releases its lock before it starts the binary, except under `--batch` (§ 4, `read in source`; `observed` without deadlock on 9.2.0, `proto/EVIDENCE.md` T3).
- Two update runs back to back through the target, with the tag moved between them and no other command between, both resolved and wrote the new digests: the outer `bazel run` evaluates the extension without the switch, so the switch is a changed recorded input each time (`observed`, `proto/EVIDENCE.md` T9). A bare `bazel mod deps --repo_env=…` repeated twice with no command between was not run.
- Bazel's lockfile merge driver (`MODULE.bazel.lock merge=bazel-lockfile-merge` in `.gitattributes`, https://bazel.build/external/lockfile) merges `facts` shallowly, per key (`read in source` by the SOTA review, https://bazel.googlesource.com/bazel/+/refs/heads/release-9.3.0/scripts/bazel-lockfile-merge.jq).

### Prior art

- rules_oci marks its extension non-reproducible when a pull has no digest and writes no facts (research § 3, `extensions.bzl` lines 42-46, 83-87 of rules_oci). Its users pin the digest of the image index (https://raw.githubusercontent.com/bazel-contrib/rules_oci/main/docs/pull.md).
- No OCI ruleset was found that locks a tag by its per-platform manifest digests, so there is no precedent for reporting such a lock as stale.
- rules_go, rules_js, rules_swc and rules_nodejs use facts as checksum caches keyed by a stable version (research § 1, https://aspect.build/blog/bazel-facts-api.md).
- rules_jvm_external (`REPIN=1 bazel run @maven//:pin`) and rules_rust (`CARGO_BAZEL_REPIN`, allow-list `CARGO_BAZEL_REPIN_ONLY`) switch the resolve with an environment variable (research § 4, `documented` by search results only).
- aspect `write_source_files` writes source files from a `bazel run` target through `BUILD_WORKSPACE_DIRECTORY` (research § 4).
- No ruleset was found whose run target edits `MODULE.bazel.lock` itself (research § 4).

## Decision Drivers

- A moved tag changes nothing until someone updates on purpose.
- One lock per declaration, and `update` moves that lock and nothing else.
- A fact hit runs no `ocx` and makes no request.
- rules_ocx owns no Bazel file format and no ocx file name.
- A plain `bazel build` under `--lockfile_mode=error` stays the CI gate.
- Windows works without a shell and without `--enable_runfiles`.

## Considered Options

### Update mechanism

**U1: nested `bazel mod deps`.** The update target writes `ocx.lock` or the snapshot where needed, then runs `bazel mod deps --lockfile_mode=update --repo_env=RULES_OCX_UPDATE=<names>` in `BUILD_WORKSPACE_DIRECTORY`. The extension ignores the stored fact of a named tag declaration and resolves again. Observed on 9.2.0: no deadlock, only the named fact changed, `print()` reached stderr (`proto/EVIDENCE.md` T3-T5, T9).

**U2: the target edits `MODULE.bazel.lock`.** The target runs `ocx`, computes digests and rewrites the facts entry itself.

**U3: the target prints the command.** The target writes `ocx.lock` or the snapshot and prints `bazel mod deps --lockfile_mode=update --repo_env=RULES_OCX_UPDATE=<names>` for the user to run.

| Criterion | Weight | U1 | U2 | U3 |
|---|---|---|---|---|
| Owns no Bazel file format; one writer per file | 30 | 5 | 1 | 5 |
| One step leaves both locks consistent | 25 | 5 | 5 | 2 |
| Works on Windows without a shell | 15 | 3 | 3 | 3 |
| Prior art | 10 | 2 | 1 | 4 |
| Size of the code rules_ocx owns | 10 | 3 | 1 | 5 |
| Failure is clear and recoverable | 10 | 4 | 3 | 3 |
| **Weighted total (max 500)** | | **410** | **250** | **365** |

Prior art: no ruleset found nests `bazel` in a run target; the REPIN rulesets switch the resolve with a variable the user sets, which is closer to U3. Windows: every option needs a generated program on Windows, so the row does not separate them.
U2 parses and rewrites a Bazel-owned file whose facts are a JSON string inside JSON, and it races a running server that also writes the file. U3 leaves `ocx.lock` and `MODULE.bazel.lock` inconsistent until the user acts, and a CI under `--lockfile_mode=error` fails in between.

### Which `bazel` the update target runs

**B1:** `bazel` from `PATH`, overridden by `RULES_OCX_BAZEL`. **B2:** startup options passed through as arguments. **B3:** a path recorded at analysis time.
Bazel names neither its binary nor its startup options to a `bazel run` binary (research § 4, https://bazel.build/docs/user-manual), so B3 has nothing to record.
B2 is rejected because correctness does not depend on matching startup options: the lockfile lives in the workspace, so a nested call with other startup options writes the same file. A mismatch costs a second server and its startup time. A user who needs a wrapper points `RULES_OCX_BAZEL` at it. There is no `RULES_OCX_BAZEL_ARGS`.

### Fact key

**K1:** `package|<hub name>|<identifier>` (today, `facts.bzl:18-30`). **K2:** `<tier>|<hub name>`, one fact per declaration. **K3:** one fact per platform, `package|<hub name>|<platform>`. **K4:** `package|<identifier>`, shared by declarations.

| Criterion | Weight | K1 | K2 | K3 | K4 |
|---|---|---|---|---|---|
| `update` of one declaration moves only that declaration | 30 | 5 | 5 | 2 | 1 |
| A shallow merge keeps one resolve per value | 25 | 5 | 5 | 1 | 4 |
| A lock diff reads as one entry changing | 20 | 3 | 5 | 4 | 3 |
| No stale key left behind by an edit | 15 | 5 | 5 | 4 | 3 |
| Churn against today | 10 | 4 | 3 | 2 | 3 |
| **Weighted total (max 500)** | | **450** | **480** | **245** | **265** |

The stale-key row is equal for K1 and K2: a key the run does not return is dropped (T7), so an edit leaves nothing behind under either.
K3 lets a merge combine platforms from two different resolves, which breaks "a package updates all its listed platforms together". K4 shares one fact between declarations with different `platforms` and between modules. K2 keeps the key stable across an identifier edit, so `git diff` shows the old and new digests under one key.

## Decision Outcome

**Chosen:** U1 with B1, and K2. The facts carry a `v` of 2. A declaration of kind `tag` or `pinned` vendors its per-platform pins.

**Rationale:**

- U1 is the only option that leaves `ocx.lock`, the snapshot and `MODULE.bazel.lock` consistent in one command without rules_ocx writing a Bazel file.
- The environment switch follows the REPIN prior art, and the prototype on 9.2.0 shows the nested call works (T3, T9).
- K2 is one value per declaration, so a shallow per-key merge keeps one side's whole resolve.
- Vendoring the pins for `pinned` too means a declared image index digest is only the resolve input. A registry that collects that index no longer breaks a locked checkout, and the fact of a `pinned` declaration is a pure function of an immutable digest.

### Consequences

**Positive:**

- A tag or digest declaration is locked by platform manifest digests, its sets vendor a digest, and they become reproducible (`set_repo.bzl:384-388` already returns `reproducible = True` for a pinned package).
- The extension is `reproducible = True` for every kind. It no longer writes its whole result into `MODULE.bazel.lock`, only facts.
- rules_ocx reads `manifest.json` and derives no other file name.
- A Windows build needs neither `--enable_runfiles` nor `--windows_enable_symlinks` for vendored tools. This is a claim until the job named in § Test plan runs.

**Negative:**

- A tool named `update` can no longer be exposed by a hub; the hub's `update` target takes the name. The collision fails with the existing text of `hub_content_error` (`hub.bzl:25-42`), and a user exposes such a tool with an `alias` of the set's file.
- Upgrading rules_ocx makes every stored v1 fact miss once. A checkout under `--lockfile_mode=error` fails once until someone runs `bazel mod deps --lockfile_mode=update` with network.
- The update program exists twice, as POSIX `sh` and as Windows batch. The batch form is unproven until CI runs it.
- A fresh offline checkout of a tag declaration without a committed fact cannot build. This is inherent: the lock does not exist yet.
- A cold start gains little: a fresh output base still downloads `ocx` and runs one vendor per set it fetches. A fact hit saves only the extension's runs. A reproducible set can come from a remote repository contents cache (`e2e/rbe/tests/test_caches_facts.py:22-39`).

**Risks:**

- The facts documentation speaks of "universally true facts". A fact for a moving tag stretches that wording, although each recorded digest is immutable. Mitigation: the set checks its vendored root digest against the fact.
- Old platform manifests survive a tag move only while something keeps them. `ocx package push` writes keep tags (`__ocx.keep.<algorithm>-<hex>`), which is an ocx convention, not an OCI guarantee. When one is gone, the set fetch fails with X6, which names the update.
- A signature or attestation attached to the image index only is checked when the tag is resolved (a miss or an update), not when a set vendors the pin (see Decided points).
- `ocx update --no-pull` on the scratch copy renders a toolchain into `<copy>/.ocx/toolchain` and writes project state under `$OCX_HOME/state/projects/<key>` (`read`, ocx `crates/ocx_cli/src/command/update.rs:164-186`, where `toolchain_render_scope` and `commit_and_render` run). Both land in the scratch copy and the scratch `OCX_HOME` of the run (§ The `update` targets, steps) and go with them. A `toolchain_dir` in the user tier of `config.toml` (`HOME` is inherited) moves the render outside the scratch; it then leaves an unused directory under that root.
- A fact edited by hand to name another platform's manifest for P vendors that manifest, because `ocx` does not check a bare digest against `-p` (MR-6). The fact is committed text and shows in `git diff`; a pin is trusted like an `ocx.lock` pin (§ Decided points), and `cross_check`'s root-digest clause only compares the vendored root with the fact.
- Whether `--noblock_for_lock` on the nested call counts as a startup option that restarts the server is `not established`; a restart costs time, not correctness.

**Reversibility:** medium. The `update` names and the `RULES_OCX_UPDATE` switch are user-facing. The fact schema can move again with a `v` bump, at the cost of one miss per declaration.

## Technical Details

### Declaration kinds

The extension classifies each tag once, before any fact lookup, in this order:

1. `ocx.project` → kind `project`.
2. `ocx.package` whose identifier ends in `@sha256:<64 lowercase hex>` → kind `pinned`. An `index` on it is still passed to ocx for routing, but it is not the lock.
3. `ocx.package` with `index` → kind `index`.
4. Any other `ocx.package` → kind `tag`.

An identifier whose first character is not `A-Za-z0-9` fails with X7 before any `ocx` run. A value that starts with `-` therefore never reaches ocx's argv as a flag. `ocx package vendor` takes its positional with `num_args = 1..` and no `last` attribute (`read`, ocx `crates/ocx_cli/src/command/package_vendor.rs:22`); clap ends option parsing at `--` by default, but rules_ocx does not rely on that, because it was not run against ocx 0.6.8.

### Fact key and value

- Key: `project|<name>` or `package|<name>`. `<name>` is the hub name. Bazel refuses two repositories of one name (`extensions.bzl:302-305`).
- Value: a JSON object, stored as `json.encode` text, as today (`facts.bzl:63-82`).
- `v` is 2. A value whose `v` is not 2 is a miss (`facts.bzl:94-95`). No `facts_version` bump is used.
- Every field under "inputs" below is compared exactly with the tag; any difference is a miss. Changing `platforms` or the identifier is a declaration edit, so the whole declaration resolves again, every platform (`observed`, `proto/EVIDENCE.md` T6).
- `tools` is `{platform: [[name, kind], ...]}` with exactly one key per entry of `platforms`. `kind` is `binary` or `entrypoint` (ocx `crates/ocx_package/src/vendor/selection.rs:45-53`).
- `schema_version` is the manifest's, 2.
- `pins` maps each listed platform to a bare digest, `sha256:<64 lowercase hex>`, of the root platform manifest (MR-5). Decoding checks each value with the existing `is_sha256` test (`set_repo.bzl:6`); a non-digest value makes the whole fact a decode error, which is a miss. No image index digest is stored anywhere: the manifest's `packages[].index_digest` is read once, in step 8, and dropped.
- The set builds the identifier it vendors from the identifier in `MODULE.bazel`: the tag and any digest are removed, and `@<pin>` is added. A tampered pin can therefore only name another digest of the declared repository.

Kind `tag`. Inputs: `kind`, `name`, `identifier`, `platforms`. `config`, `no_config`, `blob_dirs` and the ocx version are not inputs on purpose: a digest is a content address, and a mirror or another ocx does not change it. A user who changed a mirror and wants the tag read again runs the update.

```json
{
  "available_platforms": ["darwin/arm64", "linux/amd64+libc.glibc", "linux/arm64+libc.glibc"],
  "identifier": "ghcr.io/acme/jq:1.8",
  "kind": "tag",
  "name": "jq",
  "pins": {
    "linux/amd64+libc.glibc": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
    "linux/arm64+libc.glibc": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
  },
  "platforms": ["linux/amd64+libc.glibc", "linux/arm64+libc.glibc"],
  "schema_version": 2,
  "tools": {
    "linux/amd64+libc.glibc": [["jq", "binary"]],
    "linux/arm64+libc.glibc": [["jq", "binary"]]
  },
  "v": 2
}
```

`available_platforms` is what the first resolve reported (MR-7). The hub checks `platforms` against it without a request. A set of kind `tag` or `pinned` never compares it.

Kind `pinned`. Inputs: `kind`, `name`, `identifier`, `platforms`. Value as for `tag`. The declared digest may name an image index or a platform manifest; either way `pins` holds the platform manifest digest each platform resolved to.

`identifier` in every kind is an input: a copy of the `MODULE.bazel` text, compared to detect an edit. It is never vendored and never a lock value, so a declared image index digest in it does not make the fact lock an index; only `pins` is the lock, and `pins` holds platform manifest digests. Likewise `snapshot.files` names files of the user's snapshot to detect a change; a dispatch object there may hold an image index, and it is read by ocx, never pinned by rules_ocx.

Kind `index`. Inputs: `kind`, `name`, `identifier`, `platforms`, `snapshot`.

```json
{
  "available_platforms": ["linux/amd64+libc.glibc"],
  "identifier": "registry.example/rig/tool:1.0.0",
  "kind": "index",
  "name": "tool",
  "pins": {
    "linux/amd64+libc.glibc": "sha256:3333333333333333333333333333333333333333333333333333333333333333"
  },
  "platforms": ["linux/amd64+libc.glibc"],
  "schema_version": 2,
  "snapshot": {
    "files": [
      ["registry.example/p/rig/tool.json", 412, -1288001112],
      ["registry.example/p/rig/tool/o/sha256/4444444444444444444444444444444444444444444444444444444444444444.json", 1873, 90233411],
      ["registry.example/config.json", -1, 0]
    ]
  },
  "tools": {"linux/amd64+libc.glibc": [["tool", "binary"]]},
  "v": 2
}
```

`snapshot.files` lists `[path, length, hash]` for every path the resolution looked up in the snapshot directory, found or not (MR-9). A path looked up and absent is recorded with length `-1` and hash `0`, so a file added there later is a miss. rules_ocx does not know the index layout; the paths come from the manifest.

- Path rules, checked on the MR-9 field and again when a stored fact is decoded: relative, `/` only, no `..` and no empty segment, no `\`, no drive letter. A path that breaks them fails with X8 on the manifest, and is a miss on a stored fact.
- Each path is resolved against `module_ctx.path(index)`, the directory of the `index` label. A non-root module's snapshot resolves into that module's directory and is read the same way; only the update cannot write it (E5).
- The extension reads exactly these files on every evaluation with `module_ctx.read(..., watch = "yes")`, so they are recorded inputs of the reproducible extension. A file that is missing now but was present at resolve time is a miss.
- `hash` is Starlark `hash()` of the file text, which the Bazel documentation defines as the same algorithm as Java's `String.hashCode()` (https://bazel.build/rules/lib/globals/all#hash). `length` is the length in characters.
- A manifest of kind `index` without the MR-9 field fails with X9.

Why not every file of the directory: `ocx index update` also writes a catalog, `c/index.json`, for a published source (ocx `crates/ocx_index/src/store.rs:186-189`; ocx rule `subsystem-oci.md` § LocalIndex), and rules_ocx's own `.gitignore:8-11` ignores it. A key over every file would differ between a machine that ran `ocx index update` and a CI checkout, and `--lockfile_mode=error` would fail on CI.

`hash()` is 32 bits. A collision can only leave a stale fact. It cannot change what is built, because an index set vendors the tag through the snapshot itself and checks its root digest against the fact (§ Set and hub checks).

Kind `project`. Inputs: `kind`, `name`, `lock` (the full `ocx.lock` text, as today), `groups`, `bindings`, `platforms`. No `pins`: the lock is the authority, and a project set has many roots.

```json
{
  "available_platforms": ["darwin/arm64", "linux/amd64", "windows/amd64"],
  "bindings": [],
  "groups": ["lint"],
  "kind": "project",
  "lock": "<the full text of ocx.lock>",
  "name": "dev_tools",
  "platforms": ["darwin/arm64", "linux/amd64", "windows/amd64"],
  "schema_version": 2,
  "tools": {
    "darwin/arm64": [["actionlint", "binary"], ["shellcheck", "binary"]],
    "linux/amd64": [["actionlint", "binary"], ["shellcheck", "binary"]],
    "windows/amd64": [["actionlint", "binary"], ["shellcheck", "binary"]]
  },
  "v": 2
}
```

### Behaviour per `--lockfile_mode`

| Mode | Fact hit | Fact miss | `RULES_OCX_UPDATE` names a tag declaration |
|---|---|---|---|
| `update` (default) | used; no ocx, no request | resolves, writes the fact | resolves again, writes the new fact |
| `refresh` | used | resolves, writes | as `update` |
| `error` | used | runs ocx, then Bazel fails with its "has changed its facts" text | unchanged digests pass; moved digests fail with that text |
| `off` | no facts read | resolves every declaration; nothing written | as miss |

Sources: research § 2 table, `proto/EVIDENCE.md` T5 and T8. A moved tag does not fail `error` mode: the fact still answers.

### Extension algorithm

For each declaration, after the existing name, platform and duplicate checks (`extensions.bzl:285-305`):

1. Classify the kind; refuse a bad first character with X7.
2. Build the inputs. For kind `index`, read the files of the stored `snapshot.files` (only when a stored v2 fact of kind `index` exists) and compute their length and hash.
3. Look up `<tier>|<name>`. It is a hit when the value decodes, `v == 2` and every input equals the tag's.
4. A hit is ignored when the kind is `tag` and `RULES_OCX_UPDATE` names this hub. `RULES_OCX_UPDATE` is read once with `module_ctx.getenv` and split on `,`. A hub name cannot hold a comma: `tag_name_error` (`ocx/private/vendor_manifest.bzl:172-179`) validates every hub name before use, and Bazel's repository-name grammar refuses it too.
5. On a hit, use the stored value. Run no ocx and make no request.
6. On a miss, fetch the ocx binary once and run, for each listed platform, `ocx --format json [--remote] [--frozen] [--project P] [--index I] [--blob-dir D]... package vendor|vendor -o OUT -p PLATFORM --omit-links --manifest-only [-g G]... [IDENT|NAMES]`:
   - `--remote` for kind `tag` only. The resolve must read the live tag, and on a fresh home it fails without it (MR-12).
   - `--frozen` for kind `index` only, so a snapshot that lacks the tag fails instead of falling back to the registry (ocx `crates/ocx_cli/src/app/context_options.rs:73-84`).
   - Kinds `pinned` and `project` get neither flag. A `pinned` resolve names the declared digest.
7. From each manifest record `tools`; from the first record `available_platforms`; for package kinds record `pins[platform]` = the root digest (MR-5); for kind `index` record `snapshot.files` from `index_lookups` (MR-9).
8. For kind `tag`, read the root's `packages[].index_digest` of every platform (MR-8) and check that all platforms came from one image index. On a mismatch, resolve the whole declaration once more; a second mismatch fails with X3. A root with no `index_digest` (the identifier named a platform manifest) skips the check. The value is never stored.
9. Run `hub_platform_error(platforms, available_platforms)` (`ocx/private/hub.bzl:116-135`) on the recorded value. This is the platform check of MR-6, and it is rules_ocx's: `ocx` cannot decide whether a bare platform manifest serves P, so rules_ocx decides here, while the identifier still goes through the image index. `ocx` selects the leaf for `-p P` from that index, `available_platforms` is the index's platform list, and step 8 shows every leaf came from one index. The set later vendors the bare digest, and the `platform = P` that `ocx` reports for it says nothing about the digest.
10. Declare one set per platform and the hub.
11. Print the result lines of § Output lines.

Return `extension_metadata(reproducible = True, facts = …)` with every declaration's fact. `fact_cacheable` goes away. A failed evaluation returns no facts, so `MODULE.bazel.lock` keeps the facts it had (research § 1).

The extension's `ocx` environment stays `manifest_env` (`facts.bzl:140-175`): a scratch `OCX_HOME`, the pinned rows, the policy pair and the tag's `config`. `module_ctx.execute` inherits the process environment, so an ambient `OCX_OFFLINE` reaches the resolve unrecorded. The extension does not read it with `getenv`, which would make it a recorded input of every evaluation. `HOME` is inherited, as today (`facts.bzl:145-147`): Docker credentials and the user tier of `config.toml` live there. The scratch-`HOME` rule of this design run binds its own test calls, not the product.

When `RULES_OCX_UPDATE` is set, every evaluation prints the warning W1, so a variable left exported in a shell does not go unnoticed.

### Set repository per kind

| Kind | `package` passed to ocx | Extra root flags | `expected_digest` | `expected_available_platforms` |
|---|---|---|---|---|
| `tag`, `pinned` | `<declared registry/repo>@<pins[platform]>` | `--index` if given (routing) | `pins[platform]` | empty: not checked |
| `index` | the identifier as declared | `--index SNAPSHOT --frozen` | `pins[platform]` | the fact's list |
| `project` | none (`--project`) | as today | empty: not checked | the fact's list |

A `tag` or `pinned` set vendors `repo@<platform manifest digest>` with `-p PLATFORM` (MR-6): `ocx` reports `platform = PLATFORM` and `available_platforms = ["any"]` and does not check the digest against the platform. It needs no `--remote`. Its identifier is digest-pinned, so `package_pinned` (`set_repo.bzl:273-282`) already makes it reproducible.

An index set keeps watching the snapshot with `watch_tree` (`set_repo.bzl:300-307`), as today.

A set fetch of kind `tag` or `pinned` that fails adds the X6 hint, except when `ocx` exits 65: a full run refuses a package whose declared binary its content lacks, where the extension's `--manifest-only` run succeeded (MR-10). That text names the package and its cause, and the X6 hint would mislead. rules_ocx does not retry it and does not change the fact; the publisher corrects the package.

### Set and hub checks

`cross_check` (`set_repo.bzl:156-186`) keeps its three clauses and gains a fourth. A clause whose expected value is empty is skipped.

- `manifest.platform` equals the requested platform.
- Sorted `name:kind` of `manifest.tools` equals the fact's rows.
- Sorted `manifest.available_platforms` equals the fact's list (kinds `index` and `project` only).
- New: the root digest equals `expected_digest`. The root digest is the only root of the only selection (MR-5).

New clause text, joined into the existing message:

```text
the root package is sha256:<actual> where the fact recorded sha256:<expected>
```

The message keeps its head, `rules_ocx: the vendored set for <platform> disagrees with the fact in MODULE.bazel.lock: <clauses>;`, and its tail names the fix that helps for the kind. Today's tail, which always names `bazel mod deps --lockfile_mode=update`, goes: for a `tag` fact that command reuses the stale value.

| Kind | Tail |
|---|---|
| `tag`, `pinned` | `run bazel run @<name>//:update` |
| `index` | `the snapshot changed outside the update: run bazel run @<name>//:update or restore the snapshot` |
| `project` | `run bazel mod deps --lockfile_mode=update` |

The set repository gains the hub name and the kind as attributes for this text.

The hub keeps `hub_platform_error` against the fact's `available_platforms`. For kinds `tag` and `pinned` that list comes from the first resolve of the declared identifier, never from a set that vendors a pin.

A declaration whose identifier names a single platform manifest (kind `tag` or `pinned`) keeps today's behaviour. `ocx` reports `["any"]` for it (MR-6), which lists no requested platform, so the hub refuses with today's text: `rules_ocx: platform '<platform>' is not served by the lock (available: <list>); pick one of them, or lock a leaf for it` (`hub.bzl:133-134`), and the list reads `any`. rules_ocx does not treat `any` as a platform. Changing that is out of scope.

### Paths from the manifest

- `_TOP_LEVEL` goes. The set repository moves every top-level entry of `ocx vendor`'s output directory into the repository and reads only `manifest.json` by name.
- It refuses an output whose top level holds `_ocx_reserved`, as today (`set_repo.bzl:350-351`). `_ocx_reserved` stays rules_ocx's stash name for Bazel-reserved files (`set_repo.bzl:16`), and ocx never uses it (MR-2).
- `_sidecar()` goes. Launcher and record paths come from `tools[].launcher_path` and `tools[].record_path`, and from `entrypoints[].launcher_path` and `entrypoints[].record_path` (MR-3).
- `ocx_tool` (`set_rules.bzl:100-118`) symlinks the launcher and the record into its own package under their manifest basenames, side by side. It derives no `.exe` and no `.direct` (MR-4).
- The parser drops the fixed prefixes `packages` and `selections` (`vendor_manifest.bzl:290,385,401,404`). It keeps the checks that relate one manifest field to another: `content_dir` under `package_dir`, entry-point launchers under `package_dir`, tree paths and link targets inside `content_dir`, and a record in the same directory as its launcher.
- Link restoration under `--omit-links` is unchanged: links come from `tree.links` and are declared in the set package (`set_rules.bzl:30-35`); reserved files are moved and restored (`set_rules.bzl:37-44`). MR-11 keeps `tree.links` complete.
- The hub's `_RESERVED_TOOLS` (`hub.bzl:19`) gains `update`.

### The `update` targets

Repositories:

- The extension declares one more repository, `ocx_update`.
- Its rule writes a plan as a data file, `plan.txt`, one value per line, and one program that reads it. No tag value becomes program text.
  - Per declaration, in a fixed field order: name, kind, a main-repository flag, the lock or snapshot path as `<package>/<name>`, the identifier, the `config` path, `no_config`, `allow_unverified`, `allow_yanked`, the trusted-root path, the number of groups and each group, the number of bindings and each binding.
  - The main-repository flag is `Label.repo_name == ""` of the `ocx_lock` or `index` label, not the declaring module.
  - Read-only inputs (`config`, trusted root, the ocx binary) are absolute paths from `rctx.path`. Write targets are workspace-relative.
- The rule resolves `@ocx_tool//:ocx` with `rctx.path`, so `ocx` is downloaded only when an update target is built. A plain build that only fetches the hub fetches neither `ocx_update` nor, through it, `ocx_tool`.
- The program is `update.sh` when `rctx.os.name` is not Windows and `update.bat` when it is. The rule declares one executable target per hub, `hub_<name>`, and `update` for all declarations.
- Each hub BUILD gains `alias(name = "update", actual = "@ocx_update//:hub_<name>")`. Repositories of one extension see each other by apparent name.
- rules_ocx's `MODULE.bazel` gains `use_repo(ocx, "ocx_update")`, and its root `BUILD.bazel` gains `alias(name = "update", actual = "@ocx_update//:update")`.
- `ocx_update` is not marked reproducible. It holds absolute paths of this machine and never enters a repository cache.
- A per-hub rule with `RunEnvironmentInfo` and no `ocx_update` repository is a possible later simplification; it waits until MR-13 is proven.

Value rules, checked by the `ocx_update` rule (E10). The extension's X7 checks an identifier's first character earlier, at resolution; E10 repeats that check as the plan's backstop, so a value that reaches the plan file by any path is checked once more:

- Tag values (hub names, identifiers, groups, bindings): first character `A-Za-z0-9`, then only `A-Za-z0-9._:/@+=,-`; no `..` segment; no userinfo, that is no `@` before the first `/` of an identifier.
- Paths may hold spaces and non-ASCII. Only `"`, `%` and a newline are refused.

Program rules:

- `update.sh` reads `plan.txt` with `while IFS= read -r`, quotes every expansion, and passes the user's ARGS to `ocx update` only as `"$@"`. Its scratch directory comes from `mktemp -d` and is removed by a `trap` on exit.
- `update.bat` reads `plan.txt` with `for /f "usebackq delims="`, assigns with `set "V=..."`, expands as `"%V%"`, and enables no delayed expansion. It passes the user's ARGS as `%*` once, to `ocx update`, and refuses ARGS holding `& | < > ^ %` or `"` with E13. A Ctrl-C can leave the scratch copies of `ocx.toml` and `ocx.lock` under `%TEMP%`; they hold no credentials.
- The bazel call is quoted: `"${RULES_OCX_BAZEL:-bazel}"` and `"%RULES_OCX_BAZEL%"` (set to `bazel` when empty), and `"--repo_env=RULES_OCX_UPDATE=a,b"`.

Entry points:

- `bazel run @<hub>//:update [-- ARGS]` updates that one declaration.
- `bazel run @rules_ocx//:update [-- NAMES]` updates every declaration, or the named ones. NAMES are hub names.
- ARGS of a project hub replace its default `ocx update` arguments; those defaults are `-g G` for each `groups` entry of the tag and the tag's `bindings` as names. A package hub takes no ARGS.

Selection, decided before anything runs, in this order:

1. `BUILD_WORKSPACE_DIRECTORY` unset → E9.
2. `@rules_ocx//:update`: an argument that starts with `-` → E3.
3. `@rules_ocx//:update`: an argument that is not a hub name → E1.
4. `@<hub>//:update` of a package hub with ARGS → E2.
5. No NAMES → every declaration of every module, dependency modules included.
6. No declaration at all → the line `rules_ocx: no ocx declarations`, exit 0, no nested call.

Steps, in this order:

1. Preflight: run `"$BAZEL" --noblock_for_lock info output_base` in `BUILD_WORKSPACE_DIRECTORY`. A missing binary prints E8; exit 9 prints E11. In both cases nothing is written. Bazel 9.2.0 accepts the startup option (`observed`, `proto/EVIDENCE.md` T11), and exit 9 means the output-base lock was held (https://bazel.build/run/scripts).
2. For each selected declaration in name order:
   - Kind `pinned`: print E4. Nothing else runs for it.
   - A lock or snapshot outside the main repository: print E5. Nothing else runs for it.
   - The write target is `$BUILD_WORKSPACE_DIRECTORY/<package>/<name>`, computed at run time. When its real path lies outside the real path of `BUILD_WORKSPACE_DIRECTORY`, print E12 and skip it.
   - Kind `project`: copy `ocx.toml` and `ocx.lock` into the scratch directory. Run `ocx --project SCRATCH/ocx.toml update --no-pull ARGS`. Publish `SCRATCH/ocx.lock` over the workspace `ocx.lock` (§ Publishing `ocx.lock`). The copy, with a scratch `OCX_HOME`, keeps `ocx update`'s render (`<copy>/.ocx/toolchain`), its project state (`$OCX_HOME/state/projects/<key>`), its consent stamp and its pull out of the workspace and the user's own home (`update.rs:164-198`: render 164-186, consent stamp 191, pull 198; MR-14). `--no-pull` still resolves live; a `--frozen --index` or `--offline` in the user's ARGS stops that.
   - Kind `index`: run `ocx --index <snapshot dir> index update <identifier>`. ocx writes the snapshot itself.
   - Kind `tag`: no ocx step; the nested call resolves it.
   - Every `ocx` run gets a fresh scratch `OCX_HOME`, the pinned rows of `OCX_ENV_CLASSES` (`ocx/private/repo_utils.bzl:81-85`), the policy pair and the tag's `config`/`no_config`. `HOME` is inherited, as in the extension.
   - An `ocx` failure prints E6, and the loop goes on, so files that were written still reach step 3.
3. Run `"$BAZEL" --noblock_for_lock mod deps --lockfile_mode=update "--repo_env=RULES_OCX_UPDATE=<names>"` in `BUILD_WORKSPACE_DIRECTORY`.
   - `<names>` are the selected declarations of kinds `tag`, `index` and `project`, never `pinned`. The extension re-resolves `tag` only; for `index` and `project` the name selects the result line, and the fact follows its file by content.
   - The call is skipped when that list is empty.
   - It reads the workspace rc files like any `bazel` call. `--lockfile_mode=update` on the command line overrides an rc `--lockfile_mode=error`.
   - Exit 9 prints E11. Any other failure prints E7.
4. Exit with the first failing `ocx` exit code in name order, else the first refusal of a declaration (E12 or E14, exit 78) in name order, else the nested call's exit code, else 0. E4 and E5 are notices and exit 0: nothing is wrong with the declaration, it is only not this workspace's to move. E12 and E14 are refusals: the declaration should move and cannot.

What the nested call writes: it evaluates the extension under `update` mode, so it also writes any fact that misses for another reason, such as a new or edited declaration or a v1 fact. Any build in update mode does the same. "Moves only that declaration" holds for declarations whose facts hit.

When the nested call fails, no fact moved, because a failed evaluation writes no lockfile (research § 1). The recovery is `bazel mod deps --lockfile_mode=update` without the switch: project and index facts follow the files already written, and tag facts are not resolved again, so their first result stays. An update of every name fails as a whole when one tag has vanished from its registry; naming the other declarations is the workaround.

`RULES_OCX_UPDATE` and `RULES_OCX_BAZEL` are rules_ocx names on purpose: `OCX_*` is ocx's environment namespace.

### Publishing `ocx.lock`

- The program writes a temporary file with a unique name in the directory of the workspace `ocx.lock`, copies the original's file mode to it, and renames it over `ocx.lock`.
- A workspace `ocx.lock` that is a symlink is refused with E14 before anything is written.
- On any failure the temporary file is removed and the program exits non-zero.
- On Windows the rename is `move /y`. Whether it replaces the file atomically is `not established`; the `windows-update-target` job (§ Test plan) runs it.

### Output lines

The extension prints these lines on stderr as Bazel `DEBUG:` lines (`observed`, `proto/EVIDENCE.md` T3). The update program prints only E4, E5 and its errors. The text after `rules_ocx: ` is the contract.

| Line | Printed by | When |
|---|---|---|
| `rules_ocx: <name> <platform>: sha256:<old> -> sha256:<new>` | extension | kinds `tag`, `pinned`, `index`, when a stored v2 fact is replaced and that platform's pin differs |
| `rules_ocx: <name>: unchanged` | extension | a declaration named in `RULES_OCX_UPDATE` whose fact did not change |
| `rules_ocx: <name>: tools recomputed from the new ocx.lock` | extension | kind `project`, when its fact is replaced |
| `rules_ocx: <name>: resolved again (the stored fact was from an older rules_ocx)` | extension | a v1 fact was replaced |
| W1 `rules_ocx: RULES_OCX_UPDATE=<names> is set; those tag declarations resolve again on every evaluation while it is set` | extension | every evaluation with the variable set |
| E4, E5 | program | see § Error texts |

`ocx update` and `ocx index update` print their own reports. The user also sees the move in `git diff MODULE.bazel.lock`, under one key per declaration. The user docs add the Bazel lockfile merge driver line `MODULE.bazel.lock merge=bazel-lockfile-merge` for `.gitattributes`. K2 survives its per-key merge, and a merge of a v1 and a v2 lock drops the v1 entries, which are misses anyway.

### Error texts

Update program (stderr):

| Id | Text | Exit |
|---|---|---|
| E1 | `rules_ocx: no ocx declaration is named '<name>'; known: <names>` | 64 |
| E2 | `rules_ocx: '<name>' is an ocx.package declaration; its update takes no arguments` | 64 |
| E3 | `rules_ocx: @rules_ocx//:update takes declaration names only; pass ocx update arguments to @<name>//:update` | 64 |
| E4 | `rules_ocx: <name>: pinned by digest in MODULE.bazel; edit the identifier to move it` | 0 |
| E5 | `rules_ocx: <name>: its <ocx.lock or index snapshot> is not in this workspace; update it in the module that holds it` | 0 |
| E6 | `rules_ocx: <name>: ocx <argv> failed (exit <n>)`, after ocx's own stderr | n |
| E7 | `rules_ocx: bazel mod deps --lockfile_mode=update failed (exit <n>); no fact moved; the ocx.lock and snapshot files written above stay; once the cause is fixed, run bazel mod deps --lockfile_mode=update` | n |
| E8 | `rules_ocx: no bazel found; put bazel on PATH or set RULES_OCX_BAZEL` | 78 |
| E9 | `rules_ocx: run this target with bazel run` | 64 |
| E11 | `rules_ocx: the Bazel output base is locked (another command, or bazel --batch run); run the update again without --batch` | 75 |
| E12 | `rules_ocx: <name>: <path> resolves outside the workspace; refusing to write it` | 78 |
| E13 | `rules_ocx: an update argument holds one of & \| < > ^ % "; rename the group or binding, or run the update on a POSIX host` | 64 |
| E14 | `rules_ocx: <name>: <path> is a symlink; replace it with the file it points to before updating` | 78 |

Extension and repository rules (`fail()` text, or a hint appended to it):

| Id | Text |
|---|---|
| X1 | the `run_ocx` failure text (`repo_utils.bzl:612-636`), then `hint: MODULE.bazel.lock holds no digests for '<name>'; resolve the tag once online and commit MODULE.bazel.lock, pin a digest in the identifier, or give the package an index snapshot` (kind `tag`, fact miss) |
| X2 | `rules_ocx: '<name>': ocx package vendor reported <n> selections or roots; a package needs exactly one` |
| X3 | `rules_ocx: the tag of '<name>' moved while it was resolved; run the update again` |
| X4 | the `run_ocx` failure text, then `hint: the index snapshot <label> has no entry for <identifier>; run bazel run @<name>//:update` (kind `index`, exit 81) |
| X5 | `unsupported vendor manifest schema_version <n>: this rules_ocx reads 2 — pin an ocx and rules_ocx pair that agree` (replaces `vendor_manifest.bzl:367-368`) |
| X6 | the set fetch failure text, then `hint: the platform manifest MODULE.bazel.lock pins for '<name>' may be gone from the registry; run bazel run @<name>//:update` (kinds `tag`, `pinned`) |
| X7 | `rules_ocx: '<name>': the identifier '<identifier>' must start with a letter or digit` |
| X8 | `rules_ocx: '<name>': the manifest names the snapshot path '<path>', which is not a plain relative path` |
| X9 | `rules_ocx: '<name>': the manifest lists no index inputs; rules_ocx needs an ocx that reports them (MR-9)` |
| E10 | `rules_ocx: '<name>': cannot write an update step for '<value>': <reason>` (reasons: a first character outside `A-Za-z0-9`, a character outside `A-Za-z0-9._:/@+=,-`, a `..` segment, userinfo, or in a path one of `"`, `%`, newline) |

Under `--lockfile_mode=error` a miss fails with Bazel's own text after ocx ran; rules_ocx adds nothing.

### Offline

- A fact hit makes no request and runs no ocx, offline or not.
- A set that vendors a digest needs the blobs: from the network, or from `blob_dirs` (unchanged). A logical index-routed name may still need the routing root fetched once (explorer § 8, `documented` only).
- A fresh offline checkout of a tag declaration with no fact fails with X1. Ambient `OCX_OFFLINE` makes ocx refuse the tag resolve (ocx `context_options.rs:62-71`), and X1 names the three fixes.
- An index declaration resolves offline from the snapshot when its leaf manifests and configs are reachable through `blob_dirs`. `not established`.

### Manifest fields rules_ocx requires

For reconciliation with the parallel ocx design. "Today" means ocx at `9c9e32d4`.

- **MR-1** `schema_version` is 2. rules_ocx reads exactly 2 and refuses 1 with X5.
- **MR-2** Every manifest path is relative to the output directory, uses `/`, and names what a full vendor writes. No path segment and no top-level entry is `_ocx_reserved`; `ocx` refuses a package path holding that segment with exit 65 (ocx C-025).
- **MR-3** A tool has `launcher_path` and `record_path` together, or neither. An entry point has both. A record sits in the same directory as its launcher and is named `NAME.launch` (the launcher's basename, minus one `.exe`, plus `.launch`). The name is whatever `record_path` says; rules_ocx never derives it.
- **MR-4** A launcher finds its record from the name it was started by. Linking both files under their manifest basenames into one directory keeps that relation, on every platform. rules_ocx derives neither name.
- **MR-5** `ocx package vendor` writes exactly one selection, `default`, with exactly one root. The root's `packages[]` entry has `digest`, a platform manifest digest and never an image index digest.
- **MR-6** (refused as written; ocx R-U9) `ocx package vendor -p P registry/repo@<platform manifest digest>` vendors that manifest for P, reports `platform = P` and `available_platforms = ["any"]`, and refuses nothing: a bare platform manifest records no platform, so `ocx` cannot decide that it serves P, and it exits 65 for no such case. The platform check stays in rules_ocx, at resolve time, through the image index: the `-p P` resolve selects the leaf, `available_platforms` is the index's platform list (MR-7) and `packages[].index_digest` shows the leaves share one index (MR-8). A lock holds platform manifest digests only, never an index digest; `index_digest` is read and never stored.
- **MR-7** When the identifier resolves through an image index, `available_platforms` lists that index's platforms (today, `vendor.rs:304-309`).
- **MR-8** The field is `packages[].index_digest`, per package, optional: the image index digest the root was selected from. It is absent when the identifier named a platform manifest or the package was reached by digest, and on every dependency. rules_ocx uses it only to check that every platform of one declaration came from one index (step 8), and never stores it.
- **MR-9** With `--index DIR`, the top-level field `index_lookups[]`, each `{path, found}`, lists every path under DIR that the resolution read, relative to DIR and `/`-separated, sorted and without duplicates. It is absent without `--index`.
- **MR-10** `--manifest-only` writes the same fields as a full vendor except `content` (`absent`) and `packages[].tree`. A full run can refuse where `--manifest-only` succeeds: a package whose declared binary its content lacks is refused with exit 65 (ocx R-U1, today node 26.13.1). The extension records the fact from the manifest-only run; the set fetch then fails with ocx's own text and no X6 hint, rules_ocx does not retry or edit the fact, and the package publisher corrects the claim (§ Set repository per kind).
- **MR-11** `--omit-links` writes no link and lists every omitted link in `tree.links` with its target (today).
- **MR-12** `--remote` resolves a tag live on a fresh `OCX_HOME`. `--frozen` with `--index` never fetches a tag the snapshot lacks (exit 81), and a vendor run writes nothing into the `--index` directory. Today a vendor run can write there (ocx `tasks/vendor.rs:379`, `:1011-1017`, a digest-addressed resolve through the writable manager); the ocx plan fixes it with a read-only view (ocx R-U10, C-030). This ADR depends on that fix: `test_set_fetch_leaves_the_snapshot_unchanged` is red against an `ocx` without it, so the `ocx` build the pins name must carry it.
- **MR-13** The launcher finds its record beside the path it was started by, never through a manifest. It finds its root through the runfiles tree (`ARGV0.runfiles`, `RUNFILES_DIR` when the path lies under it), then through the runfiles manifest: `ARGV0.runfiles/MANIFEST`, `ARGV0.runfiles_manifest`, then `RUNFILES_MANIFEST_FILE` only when it lists the started path. It takes the root from the line whose key ends `/<name>.launch`, decodes the escaped line form of Bazel 7.4 and later (research § 5), and exits 78 only when neither a tree nor a manifest gives a root.
- **MR-14** `ocx update --no-pull` against a scratch project copy writes `ocx.lock` beside that copy and nothing beside the workspace's `ocx.toml`, and keeps its exit codes 64, 65 and 78 (`update.rs:94-122,271-327`). It also renders a toolchain into `<copy>/.ocx/toolchain` and writes project state under `$OCX_HOME/state/projects/<key>`; the update program runs it in a scratch directory with a fresh scratch `OCX_HOME` (§ The `update` targets, steps), so both land in the scratch and the user's own home is never written. `--no-pull` still resolves live.

### Versions

- Bazel: rules_ocx requires `bazel_compatibility = [">=9.0.0"]` (`MODULE.bazel:11`). That is above the 8.5 floor of facts (research § 1, third-party source) and the 8.6.0 fix that validates `error` mode against the workspace lockfile only (https://bazel.googlesource.com/bazel/+/refs/heads/release-8.6.0). No new guard is needed.
- `MIN_OCX_VERSION` stays `0.6.8` (`ocx/private/versions.bzl:22`). Neither `ocx vendor` nor manifest schema 1 has been released, so the first release with schema 2 is still the first with `ocx vendor`. The messages at `versions.bzl:24-47` say schema version 2.
- `DEFAULT_OCX_VERSION` and `dist/dist.json` move with the ocx release, as the owner steps already say.
- `e2e/rbe/ocx-under-test.txt` moves to the dev build of the final ocx head of pull request 784, and is removed before the default branch (`scripts/ocx_under_test.sh:32`).

### Runfiles and Windows

- The launcher keeps the runfiles-tree lookup and adds the manifest lookup (MR-13). Reasons are in ADR 0002 § Runfiles.
- Consumer docs drop the `--enable_runfiles` requirement: `README.md:19`, `docs/concepts/design.md:43-44`, `docs/guides/cross-platform.md:89`, `docs/guides/remote-cache.md:22,25`, `docs/tutorial.md:56`.
- `e2e/bzlmod/.bazelrc:5-6` and the three example `.bazelrc` files drop both lines, so CI exercises the consumer default.
- rules_ocx's root `.bazelrc:7-9` keeps both lines for its own `sh_test`s, whose data need a tree (`.bazelrc:7`).
- `examples/cross_platform:no_runfiles_test` asserts exit 78 on Windows today. It is inverted (§ Test plan).

### C4 sketch

```text
Context
  user / CI ──bazel build──▶ Bazel ──fetch──▶ registry (OCI)
  user ──bazel run @hub//:update──▶ update program ──▶ ocx, nested bazel

Containers
  Bazel server   module extension `ocx`        reads facts, runs ocx on a miss, declares repos
                 set repo per platform          runs ocx vendor, generates BUILD from manifest.json
                 hub repo                       toolchains, ocx_tool targets, alias :update
                 ocx_update repo                plan.txt, update.sh / update.bat
  Workspace      MODULE.bazel.lock (facts)      written only by Bazel
                 ocx.lock, index snapshot       written only by ocx (ocx.lock published by the program)
  ocx binary     @ocx_tool                      vendor, update, index update

Components (rules_ocx)
  facts.bzl            kind, key, inputs, hit/miss, value encode/decode
  extensions.bzl       per-kind resolve, RULES_OCX_UPDATE switch, result lines
  vendor_manifest.bzl  manifest v2 parse, field-relation checks
  set_repo.bzl         vendor argv per kind, move top-level entries, cross_check
  set_rules.bzl        ocx_set, ocx_tool (manifest basenames)
  hub.bzl              BUILD with alias :update, platform check
  update_repo.bzl      plan.txt, generated program, value checks
```

### NFR coverage

- **Latency.** A fact hit runs no ocx and makes no request, for every kind. A reproducible extension runs once per changed input or new output base. An index hit reads the few snapshot files named in its fact. See the cold-start note under Consequences.
- **Availability and offline.** See § Offline. A moved or deleted tag does not affect a locked checkout until the old platform manifest is gone from the registry (X6).
- **Security.** The update program and the nested bazel run the user's own workspace configuration with the user's rights, the same as typing the command. Every `ocx` call uses a scratch `OCX_HOME`. Writes go to `ocx.lock` (§ Publishing `ocx.lock`), the snapshot (by ocx) and `MODULE.bazel.lock` (by Bazel), all inside the workspace (E12). The one new trust boundary is tag values of every module reaching a generated program; the plan file and E10 close it. A pin can name only a digest of the declared repository (§ Fact key and value). No credential is stored or forwarded beyond what `module_ctx.execute` and the shell already inherit.
- **Cost.** An update of a tag declaration costs one `ocx vendor --manifest-only` per platform plus one nested bazel; the nested call reuses the server when its startup options match.
- **Operability.** Result lines per declaration and platform; a stable fact key gives a one-entry `git diff`; every error names its fix; W1 shows a leftover switch.
- **Scalability.** A stored package fact for 2 platforms was 498 characters in the earlier prototype (`observed`, `proto/EVIDENCE.md` T10). Estimates for this schema: about 400 bytes plus about 150 per platform for `tag` and `pinned`, plus about 100 bytes per snapshot path for `index`. A project fact holds the full `ocx.lock` text, as today. `@rules_ocx//:update` runs ocx sequentially, one declaration and platform at a time.

### Test plan

Each check is shown red once and green once. A red is a planted mutation of the new code or a failure observed today.

Unit tests (struct-stub pattern, `ocx/tests/repo_utils_test.bzl:20,48`), all over new pure functions:

| Test | Red | Green |
|---|---|---|
| `facts_test`: key is `<tier>\|<name>` | mutation: key keeps the identifier | key equals `package\|jq` |
| `facts_test`: a v1 value misses | mutation: `_VERSION = 1` | v1 is a miss, v2 a hit |
| `facts_test`: golden JSON per kind, one `tools` key per platform | mutation: `fact_value` drops `pins` | each example above round-trips |
| `facts_test`: a non-digest pin is a decode error | mutation: drop the `is_sha256` check | `ghcr.io/x@sha256:…` as a pin is a miss |
| `facts_test`: the switch forces a miss for kind `tag` only | mutation: drop the kind test | `tag` misses; `pinned`, `project`, `index` hit |
| `facts_test`: index inputs change with one file's text, and with an absent path that appears | mutation: skip absent entries | both are misses |
| `facts_test`: snapshot path rules (`..`, `\`, drive letter, empty segment) | mutation: drop the check | each is refused |
| `facts_test`: same-index check of step 8 | mutation: the check always passes | two index digests give a retry, then X3 |
| `set_repo_test`: `cross_check` root digest clause and per-kind tails | mutation: compare with `pins` of another platform | mismatch gives the clause and the kind's tail |
| `set_repo_test`: an empty expected value is skipped | mutation: compare an empty list | a `tag` set with `["any"]` passes |
| `set_repo_test`: vendor argv per kind | mutation: swap `--remote` and `--frozen` | argv matches the table; X7 for `-x` |
| `vendor_manifest_test`: v2 parses; v1 gives X5; record beside launcher; no fixed prefixes; MR-9 missing gives X9 | mutation: accept 1 | v2 fixture parses; each refusal text matches |
| `hub_test`: `update` is reserved and the alias is generated | mutation: drop `update` from the list | tool `update` refused; alias present |
| `update_repo_test`: plan file golden, value rules | mutation: allow `;` in a group | goldens match; `;` refused with E10; a path with a space accepted; `%` refused |
| `update_repo_test`: selection decisions | mutation: check names after the ocx steps | E9, E3, E1, E2 in that order; E4 for a pinned name |

e2e on the zot rig, new module `e2e/rbe/tests/test_package_lock.py`, using the counting ocx wrapper (`e2e/rbe/tests/conftest.py`) where a fault must be planted:

| Test | Red | Green |
|---|---|---|
| `test_moved_tag_keeps_the_locked_digests` | mutation: kind `tag` gets no fact | a clean output base builds the old content; the registry log shows only the digest |
| `test_pinned_index_digest_vendors_the_pins` | mutation: `pinned` vendors the declared digest; then delete the index | builds after the index is gone |
| `test_hub_update_moves_only_that_declaration` | mutation: the switch counts as "all" | only that fact changes |
| `test_update_writes_a_missing_fact_of_another_hub` | mutation: the nested call uses `--lockfile_mode=off` | the second hub's fact appears too |
| `test_rules_ocx_update_all_and_named` | mutation: names are ignored | all, then only the named one, change |
| `test_error_mode_moved_tag_passes_update_fails` | mutation: the extension ignores the switch | build passes; switch run fails with Bazel's text |
| `test_fresh_home_tag_resolves` | observed today: fails without `--remote` (research § 6) | resolves on a fresh home |
| `test_tag_lock_vendors_the_platform_digest` | mutation: the set vendors the declared identifier instead of `<repo>@<pin>`; after the tag moved, the root-digest clause of `cross_check` fails | set vendors `<repo>@<pin>` with `-p`; the manifest reports `platform = P` and `available_platforms = ["any"]`; root checks pass after the tag moved (MR-6) |
| `test_platform_outside_the_index_is_refused` | mutation: the hub check skips kinds `tag` and `pinned` | a `platforms` entry the index does not list gives `hub_platform_error`'s text at resolve time, with no set fetch; a bare platform manifest identifier gives the same text with `available: any` |
| `test_full_vendor_refusal_is_not_hinted_as_gone` | mutation: the X6 hint is added for exit 65 | a package whose declared binary is missing from its content: the extension's fact is written, the set fetch fails with ocx's text and exit 65, no X6 hint |
| `test_snapshot_refresh_invalidates_the_fact` | mutation: drop `snapshot` from the inputs | `ocx index update`, then a build, re-resolves |
| `test_set_fetch_leaves_the_snapshot_unchanged` | mutation: drop `--frozen`, and remove the tag's row from the snapshot: the fetch resolves live | snapshot bytes equal before and after; the missing row gives X4 |
| `test_project_update_writes_only_ocx_lock` | mutation: `ocx update` runs on the workspace `ocx.toml` | only `ocx.lock` and `MODULE.bazel.lock` change; no `.ocx/` |
| `test_offline_fresh_tag_names_the_fix` | mutation: drop the hint | X1 hint present |
| `test_old_fact_misses_once` | mutation: `_decode` accepts v1 | one resolve, then hits |
| `test_update_selection_errors` | mutation: names checked after the ocx steps | E1, E2, E3, E9 with exit 64 and no ocx call; E4 with exit 0 |
| `test_update_refusals` | mutation: drop the real-path check, the symlink check, or the `PATH` probe | an `ocx_lock` symlinked outside the workspace gives E12, a symlinked `ocx.lock` gives E14, both exit 78 and leave the file unchanged; `RULES_OCX_BAZEL` set to a missing file gives E8 with exit 78 before any write |
| `facts_test`: snapshot path rules | mutation: accept `..` | `../x`, `/x`, `a//b`, `a\b`, `C:/x` each give X8 |
| `test_update_skips_a_dependency_snapshot` | mutation: drop the main-repository flag and the real-path check | E5 printed; the dependency's snapshot unchanged |
| `test_update_continues_after_an_ocx_failure` | mutation: stop at the first failure | E6 for the bad project group; the other declaration's fact moves |
| `test_update_reports_a_failed_nested_call` | mutation: ignore the nested exit | with `RULES_OCX_BAZEL` set to a wrapper exiting 2, E7 and exit 2 |
| `test_update_refuses_a_locked_output_base` | mutation: drop `--noblock_for_lock` (the run blocks until the test times out) | with a second client holding the lock, E11 and no file changed |
| `test_vendor_shape_errors` | mutation: drop each check | the wrapper's two-root manifest gives X2; per-platform index digests that differ give X3 |
| `test_gone_platform_manifest_names_the_update` | mutation: drop the hint | after the manifest is deleted from zot, X6 |
| `test_result_lines` | mutation: drop the prints | `sha256:<old> -> sha256:<new>` and `unchanged` lines |
| `test_refresh_and_off_modes` | mutation: ignore stored facts | `refresh` makes no vendor call; `off` makes one per platform |
| `test_switch_naming_a_project_does_not_resolve` | mutation: the switch forces every kind | no vendor call for an unchanged project |
| `test_switch_leaves_no_trace_in_the_lock` | mutation: store the switch in the fact | `MODULE.bazel.lock` holds no `RULES_OCX_UPDATE`; W1 printed |
| `test_update_in_a_workspace_path_with_a_space` | mutation: one unquoted expansion in `update.sh` | the update succeeds |
| `test_hub_tool_finds_its_record` | mutation: `ocx_tool` links the record under another basename (the launcher exits 78) | the tool runs through the hub |

Changes to existing tests: `test_caches_facts.py:96` asserts `"package|dep_tool"`; `test_only_a_digest_pinned_package_is_reproducible` (`:173-186`) gains a `tag` case that must be reproducible.

Remote-execution rig: `test_remote_exec.py` gains `test_tag_locked_tool_runs_remotely` on buildbarn and nativelink. Red: mutation as in `test_moved_tag_keeps_the_locked_digests`; input digests differ after a tag move. Green: two clients give identical set input digests.

Platforms (claims until these run):

- `examples/cross_platform:no_runfiles_test` becomes `manifest_runfiles_test`: without a runfiles tree the launcher starts jq and prints its version. Red today on the Windows leg of `verify-deep.yml` (it asserts exit 78 now). Green after MR-13.
- A Linux twin in `verify-basic.yml`: `bazel test --noenable_runfiles --spawn_strategy=local` of the same target. Red today: exit 78, `no vendored root found` (`observed`, research `research_launcher-atomic-publish-and-runfiles.md` § 5). Green after MR-13.
- `windows-update-target` in `verify-deep.yml`, in a copy of `e2e/bzlmod` under a path with a space: `bazel run @jq//:update` through `update.bat` exits 0 and prints the `unchanged` line, and a project update replaces `ocx.lock`. Red: mutation of the generated `update.bat` that drops the quotes around one expansion; the same run fails. The same job runs `bazel run @dev_tools//:update -- -g "a&b"` and expects E13 with exit 64 (red: mutation that drops the E13 check, after which cmd splits the argument), and `RULES_OCX_BAZEL` set to a missing file, expecting E8 (red: mutation that drops the probe, after which cmd prints its own error and exits 9009).

### Decided points

1. **How far a pin in `MODULE.bazel.lock` is trusted.** Decided under goal-loop authority, 2026-11-26 (no human answered in this run; the owner may revisit): a pin is trusted like an `ocx.lock` pin. At build, the set's digest vendor runs the committed and operator policies (`signer_rounds_for_pinned`, ocx `crates/ocx_package_manager/src/tasks/auto_verify.rs:354-367,406-410`), and the publisher checks from the index run at resolve (a miss or an update). The pin rule limits a tampered pin to another digest of the declared repository. Reason: it is the model the project tier already uses, and it needs no new ocx requirement. A signature or attestation attached to the image index only is therefore not checked when a set vendors the pin.

## Links

- [`adr_0002_vendor_tool_sets.md`](adr_0002_vendor_tool_sets.md): the vendor contract this record amends.
- [`adr_0001_policy-tag-and-env-classes.md`](adr_0001_policy-tag-and-env-classes.md): the env classes the update program reuses.
- [The vendor model](../../docs/concepts/design.md)
- ocx research: `.agents/research/research_bazel-extension-facts-lock.md`, `.agents/research/research_launcher-atomic-publish-and-runfiles.md` (ocx repository).
- https://bazel.build/external/extension, https://bazel.build/external/lockfile, https://bazel.build/docs/user-manual, https://bazel.build/run/scripts, https://bazel.build/rules/lib/globals/all#hash

---

## Changelog

| Date | Author | Change |
|------|--------|--------|
| 2026-11-26 | owner | Initial record (Proposed) |
| 2026-11-26 | owner | review round 1 applied |
| 2026-11-26 | owner | re-validation warns applied (identifier is an input, refusal exits, test rows for E8, E12-E14, X8) |
| 2026-11-26 | goal loop | reconciled with the ocx record `adr_unified_launcher.md`: MR-6 refused (platform check stays here), MR-8 `packages[].index_digest`, MR-9 `index_lookups[]`, MR-10, MR-12, MR-13, MR-14 statements; pin trust decided; Accepted under goal-loop authority |
