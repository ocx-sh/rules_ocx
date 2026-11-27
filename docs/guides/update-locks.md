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
| `tag` | any other `ocx.package` | One platform manifest digest per platform, in `MODULE.bazel.lock` | `bazel mod deps` with `RULES_OCX_UPDATE` |

A moved tag changes nothing until you run an update.
The registry may point `:latest` at a new image tomorrow, and a build with a stored digest still fetches the old one.

## Update a project or an index

The `update` target of a `project` or `index` hub is `ocx` itself, configured for that declaration.
`bazel run` starts the binary rules_ocx fetched, with the arguments and the environment of the tag already set.

```console
$ bazel run @tools//:update
```

For a `project` tag this runs `ocx --project <workspace>/ocx.toml update --no-pull`, with `-g <group>` for each entry of `groups` and the tag's `bindings` as names.
For an `index` tag it runs `ocx --index <snapshot> index update <identifier>`.
Arguments after `--` follow the baked ones.
They do not replace them, so a `-g` you pass adds to the groups of the tag.

```console
$ bazel run @tools//:update -- --verbose
```

The target runs no Bazel.
`MODULE.bazel.lock` follows on your next Bazel command, because the extension watches `ocx.lock` and the snapshot and records a new fact when they change.
Run `bazel mod deps` right after if you want to commit the lock at once.

The target exists only where `ocx` may write the file:

- A `project` tag needs `ocx_toml` and `ocx_lock` in your own repository, in one package, named `ocx.toml` and `ocx.lock`.
- An `index` tag needs its snapshot in your own repository.
- A lock or snapshot of a dependency belongs to the module that holds it. Update it there.

A tag without a target has no `update` label in its hub.

## Update a tag

A `tag` declaration has no target.
Its fact moves when the extension resolves it again, which one Bazel command does:

```console
$ bazel mod deps --lockfile_mode=update --repo_env=RULES_OCX_UPDATE=jq
```

The value is a comma-separated list of hub names.
A `pinned` declaration has no update at all: its digest is in `MODULE.bazel`, so you edit the identifier.

## Read the result

The extension prints one line per declaration and platform.

```console
DEBUG: rules_ocx: jq linux/amd64: sha256:<old> -> sha256:<new>
DEBUG: rules_ocx: jq: unchanged
```

A `project` declaration whose lock changed prints `rules_ocx: <name>: tools recomputed from the new ocx.lock`.

`git diff MODULE.bazel.lock` shows the same move under one key per declaration.
Commit the lock together with `ocx.lock` and the index snapshot.

While `RULES_OCX_UPDATE` is set, the named `tag` declarations resolve again on every evaluation, and rules_ocx prints a warning each time.
Pass it with `--repo_env` on the one command, and do not export it in your shell or rc files.

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

- The target exits with the exit code of `ocx`, and the `ocx` message names the cause.
- `ocx` writes the lock by one atomic rename. A failed update leaves the old `ocx.lock` as it was.
- `ocx update` may create `.ocx/` beside your `ocx.toml` and, for an index, a `config.json` in the snapshot. Both are `ocx` files, not Bazel ones.
- The target uses your `OCX_HOME`, the `ocx` configuration of your machine and its credentials. It does not use a scratch home.
- `no_config`, `config` and the `ocx.policy` settings of the module apply to the update as they do to the build.
