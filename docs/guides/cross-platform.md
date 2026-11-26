<!-- doc_type: how-to -->
<!-- doc_tier: everyday -->
# Use tools for several platforms

This guide vendors one package for several platforms and runs the right one on each machine.
It also shows how to inspect the files of a platform you do not run.
It assumes you know how to declare an [`ocx.package`](ci-reproducible.md).

## Declare the platforms

List the platforms on the package.
rules_ocx creates one set repository per platform.
It also creates a hub that selects a toolchain by the platform an action executes on.

```starlark
ocx.package(
    name = "jq",
    index = "//:index",
    package = "ocx.sh/jqlang/jq:latest",
    platforms = [
        "darwin/amd64",
        "darwin/arm64",
        "linux/amd64",
        "linux/arm64",
        "windows/amd64",
    ],
)
use_repo(ocx, "jq")

register_toolchains("@jq//:all")
```

A build fetches the set of the platform it executes on and no other.
A platform that the package does not serve fails the build and names the platform.

`@jq//:jq` is the tool.
When a Linux machine and a macOS machine build the same target, each runs its own launcher.

## Name a platform with libc

A platform key can carry features, such as `linux/amd64+libc.musl`.
The hub lists the musl toolchain before the glibc one, so a musl executor gets the musl set.
A platform key with no libc feature, or with `libc.glibc`, adds no constraint.

## Read the files of a platform you do not run

A set repository is named `<tag>_<platform>`, with every character that is not a lowercase letter or digit turned into `_`.
Its `:set` target holds every file of the set.
Add the repository to `use_repo` and depend on `:set` to fetch it without running anything from it.

```starlark
use_repo(ocx, "jq", "jq_linux_arm64", "jq_windows_amd64")
```

```starlark
sh_test(
    name = "abi_test",
    srcs = ["abi_test.sh"],
    data = [
        "@jq_linux_arm64//:set",
        "@jq_windows_amd64//:set",
    ],
    env = {
        "JQ_LINUX_ARM64": "$(locations @jq_linux_arm64//:set)",
        "JQ_WINDOWS_AMD64": "$(locations @jq_windows_amd64//:set)",
    },
)
```

The test reads the first bytes of each binary and expects an ELF aarch64 file and a PE32+ file.
Run it with `bazel test //:abi_test` in `examples/cross_platform`.

## Run a tool in a repository rule

A repository rule cannot select a toolchain.
It can read a file of one set repository.
Build the label from a string, so that the sets of other platforms stay unfetched.
`examples/project/host_tool_version.bzl` runs `shellcheck --version` this way while Bazel fetches.

## Check the result

Run `bazel build @jq//:jq` on a Linux machine and on a macOS machine.
Each one fetches only its own set repository.

## Know the limits

- A Windows set cannot carry symlinks, because Bazel declares none there. A Windows set whose package lists a link fails and names the package.
- On Windows, build with `--enable_runfiles`. The launcher looks for its files in the runfiles tree and exits 78 without it.

## Windows: path length

Most Win32 path functions stop at 260 characters (`MAX_PATH`, see [Maximum path length limitation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)).
A vendored tool sits deep inside Bazel's output base, so a path can reach the limit before the tool starts.

### Where the characters go

This is the path of a `shellcheck.exe` launcher used as a build tool in this repository's Windows CI. It was 267 characters.

| Part | Example | Characters | You control it |
| --- | --- | --- | --- |
| Bazel output root and configuration directories | `C:\users\<user>\_bazel_<user>\<hash>\execroot\_main\bazel-out\x64_windows-opt-exec\bin` | 99 (64 with `--output_user_root=C:/b`) | The output root and the workspace location |
| Repository and runfiles names | `external\rules_ocx++ocx+<hub>\<tool>.exe.runfiles\rules_ocx++ocx+<hub>_windows_amd64` | 89 with a hub named `tools` | The name of the hub repository: a short name counts twice |
| Vendored package layout | `packages\<registry>\sha256\<2 hex>\<30 hex>\content` | 65 | No |

The file name inside the package comes last.

### What already handles it

The launcher passes a program path of 260 characters or more to Windows in extended-length form (`\\?\`), the same fallback Bazel uses for its own launchers (see [Bazel on Windows](https://bazel.build/configure/windows)).
Starting a tool no longer fails on the length of the tool's own path.
This needs an `ocx` that carries the change, so use a recent one.

### What nothing lifts

- A working directory longer than 260 characters. Windows refuses to start any process from it, with or without the prefix, the system long-path policy or a manifest. A Bazel test's working directory is its runfiles tree.
- Batch entry points (`.bat`, `.cmd`), because they run through `cmd.exe`.
- Tools that open their own files below a long directory, such as interpreters with deep module trees, compilers and linkers.

The system `LongPathsEnabled` policy together with an application manifest covers the file functions of programs that opt in. It does not cover starting a process (see the Microsoft page above).
In these cases the launcher names the length and the limit in its error line. The symptoms are `ocx-shim: failed to start … win32 error 3` or `87` with a path of 267 characters, or a tool that cannot find its own files.

### What to do

1. Keep the output root short with one line in the workspace `.bazelrc`, as [Bazel on Windows](https://bazel.build/configure/windows) recommends:

   ```
   startup --output_user_root=C:/b
   ```

2. Check the workspace out near the drive root.
3. Give the hub a short name in `use_repo`.
4. For a tool with a deep internal tree, use that tool's own long-path setting where it has one.

This is standard Bazel practice on Windows and is not specific to these rules.
Set the line yourself: the checked-in example workspaces do not carry it, because a `startup` option cannot be limited to one operating system.
This repository's Windows CI legs set the short output root themselves (`scripts/ocx_under_test.sh`).
