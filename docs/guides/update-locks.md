<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Update locked tools

This guide moves the pins of your tools on purpose, with one command, and shows what each kind of declaration pins.
It assumes the module setup from the [tutorial](../tutorial.md).

## Know what each declaration pins

rules_ocx sorts every `ocx.project` and `ocx.package` tag into one of four kinds.
Each kind has one source of truth for its digests.

| Kind | Tag | What pins it | What moves it |
| --- | --- | --- | --- |
| `project` | `ocx.project` | The `ocx.lock` of the tag | `ocx update` on the lock |
| `pinned` | `ocx.package` whose identifier ends in `@sha256:<digest>` | The digest in the identifier | You edit the identifier |
| `index` | `ocx.package` with `index` | The committed index snapshot | `ocx index update` on the snapshot |
| `tag` | any other `ocx.package` | One platform manifest digest per platform, in `MODULE.bazel.lock` | The update target |

A moved tag changes nothing until you run an update.
The registry may point `:latest` at a new image tomorrow, and a build with a stored digest still fetches the old one.

## Update one declaration

Run the `update` target of the hub.

```console
$ bazel run @tools//:update
```

For a `project` tag, the target copies `ocx.toml` and `ocx.lock` to a scratch directory, runs `ocx update --no-pull` there, and replaces your `ocx.lock` in one rename.
Arguments after `--` replace the default arguments, which are `-g <group>` for each entry of `groups` and the tag's `bindings` as names.

```console
$ bazel run @tools//:update -- -g lint
```

For an `index` tag, it runs `ocx index update` on the snapshot.
For a `tag` declaration it needs no `ocx` step.
A `pinned` declaration prints a notice and nothing else, because the digest is in `MODULE.bazel`.
An `ocx.package` hub takes no arguments.

The target then runs `bazel mod deps --lockfile_mode=update` once, so that `MODULE.bazel.lock` follows.
It finds `bazel` on `PATH`, or in the variable `RULES_OCX_BAZEL`.

## Update every declaration

`@rules_ocx//:update` covers all declarations of every module, or only the ones you name.

```console
$ bazel run @rules_ocx//:update
$ bazel run @rules_ocx//:update -- tools jq
```

The names are hub names.
This target accepts no `ocx update` arguments: pass those to the hub's own target.
It skips a lock or snapshot that lies outside your workspace, because that file belongs to the module that holds it.

## Read the result

The extension prints one line per declaration and platform.

```console
DEBUG: rules_ocx: jq linux/amd64: sha256:<old> -> sha256:<new>
DEBUG: rules_ocx: jq: unchanged
```

A `project` declaration whose lock changed prints `rules_ocx: <name>: tools recomputed from the new ocx.lock`.

`git diff MODULE.bazel.lock` shows the same move under one key per declaration.
Commit the lock together with `ocx.lock` and the index snapshot.

The update target passes `RULES_OCX_UPDATE=<names>` to its one nested Bazel call.
While that variable is set, the named `tag` declarations resolve again on every evaluation, and rules_ocx prints a warning each time.
Do not export it in your shell or rc files.

## Choose a lockfile mode

`--lockfile_mode` decides what a build does with the stored digests.

| Mode | A stored digest exists | A stored digest is missing |
| --- | --- | --- |
| `update` (the default) | Used. No `ocx` run, no request. | Resolved and written. |
| `refresh` | Used. | Resolved and written. |
| `error` | Used. | `ocx` runs, then Bazel fails and names the changed lock. |
| `off` | Not read. | Every declaration resolves, and nothing is written. |

A moved tag never fails `error` mode, because the stored digest still answers.
Use `error` in CI to catch a declaration that was added without its lock.

## Merge the lock file

Tell git to merge `MODULE.bazel.lock` with the Bazel merge driver, one key at a time.
Add this line to `.gitattributes`:

```ini
MODULE.bazel.lock merge=bazel-lockfile-merge
```

## Fix an update that fails

- An `ocx` failure on one declaration is reported and the others go on. The files already written stay.
- When the nested `bazel mod deps` fails, no fact moved. Fix the cause and run `bazel mod deps --lockfile_mode=update`.
- A held output base (another Bazel command, or a `bazel --batch` run) exits 75. Run the update again without `--batch`.
- A workspace `ocx.lock` that is a symlink, or a path that leaves the workspace, is refused. The error names the path.
- A preflight `bazel info output_base` that fails for another reason exits with Bazel's exit code. Nothing is written.
- A failed replace of `ocx.lock` exits 74 after the other declarations ran. The error names the path.
- A truncated plan, or on Windows an argument line that cannot be read, exits 70. Both are internal errors of the generated update program.
