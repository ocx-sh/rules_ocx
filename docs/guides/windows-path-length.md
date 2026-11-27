<!-- doc_type: explanation -->
<!-- doc_tier: integration -->
# Windows: path length

Most Win32 path functions stop at 260 characters (`MAX_PATH`, see [Maximum path length limitation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)).
A vendored tool sits deep inside Bazel's output base, so a path can reach the limit before the tool starts.

## Where the characters go

A vendored tool has a short layout: the launcher sits in `l/` and each package in `p/<HEX16>/`, with its content in `c/`.
The table builds one example path for a `shellcheck.exe` through a hub named `tools`, from these parts.
The character counts are those of the literal strings in the table.

| Part | Example | Characters | You control it |
| --- | --- | --- | --- |
| Bazel output root and configuration directories | `C:\users\runner\_bazel_runner\0123456789abcdef0123456789abcdef\execroot\_main\bazel-out\x64_windows-opt-exec\bin` | 112 (87 with `--output_user_root=C:/b`) | The output root and the workspace location |
| Repository and runfiles names | `external\rules_ocx++ocx+tools\shellcheck.exe.runfiles\rules_ocx++ocx+tools_windows_amd64` | 88 with a hub named `tools` | The name of the hub repository: a short name counts twice |
| Vendored package layout | `p\0123456789abcdef\c` | 20 | No |
| File name inside the package | `shellcheck.exe` | 14 | No |

Joined with backslashes, the example is 237 characters, or 212 with the short output root.
Measured relative to the execroot, the path of the real program has a prefix of 101 characters for `jq` through the hub with runfiles, and 42 in-tree.
In that measured path, the short layout takes the package part from 67 to 23 characters.

## What already handles it

The launcher passes a program path of 260 characters or more to Windows in extended-length form (`\\?\`), the same fallback Bazel uses for its own launchers (see [Bazel on Windows](https://bazel.build/configure/windows)).
Starting a tool does not fail on the length of the tool's own path.

## What nothing lifts

- A working directory longer than 260 characters. Windows refuses to start any process from it, with or without the prefix, the system long-path policy or a manifest. A Bazel test's working directory is its runfiles tree.
- Batch entry points (`.bat`, `.cmd`), because they run through `cmd.exe`.
- Tools that open their own files below a long directory, such as interpreters with deep module trees, compilers and linkers.

The system `LongPathsEnabled` policy together with an application manifest covers the file functions of programs that opt in. It does not cover starting a process (see the Microsoft page above).
In these cases the launcher names the length and the limit in its error line. The symptoms are a failed start with Windows error 3 or 87 on a path of 260 characters or more, or a tool that cannot find its own files.

## What to do

1. Keep the output root short with one line in the workspace `.bazelrc`, as [Bazel on Windows](https://bazel.build/configure/windows) recommends:

   ```bash
   startup --output_user_root=C:/b
   ```

2. Check the workspace out near the drive root.
3. Give the hub a short name in `use_repo`.
4. For a tool with a deep internal tree, use that tool's own long-path setting where it has one.

This is standard Bazel practice on Windows and is not specific to these rules.
Set the line yourself: the checked-in example workspaces do not carry it, because a `startup` option cannot be limited to one operating system.
