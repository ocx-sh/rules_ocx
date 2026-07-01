# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Shared plumbing for repository rules that shell out to the ocx CLI.

Everything that can be a pure function of plain values (launcher rendering,
env-file rendering) is one, so tests/ can cover it without a repository_ctx.
"""

# Env vars forwarded verbatim to every ocx invocation. getenv() registers
# them with Bazel, so changing one invalidates the fetched repos.
# OCX_AUTH_<REGISTRY>_* cannot be enumerated here — document `bazel fetch
# --force` after credential changes.
OCX_PASSTHROUGH_ENV = [
    "OCX_MIRRORS",
    "OCX_INSECURE_REGISTRIES",
    "OCX_OFFLINE",
    "OCX_FROZEN",
    "OCX_REMOTE",
    "OCX_JOBS",
    "OCX_INDEX",
    "OCX_DEFAULT_REGISTRY",
]

_SYSEXIT_HINTS = {
    64: "usage error — the pinned ocx version and rules_ocx disagree on the CLI surface; check DEFAULT_OCX_VERSION",
    65: "stale data — the lockfile does not match its declaration; run 'ocx lock' and commit the result",
    69: "a required service or registry is unavailable — check network, OCX_MIRRORS, and registry auth",
    78: "missing configuration — an expected ocx.toml/ocx.lock was not found next to the declared labels",
}

def make_ocx_env(ctx, isolated_home):
    """Assembles the environment for ocx invocations from this repo rule.

    Args:
        ctx: repository_ctx.
        isolated_home: if True, keep the ocx store inside this repository
            instead of the shared user OCX_HOME.

    Returns:
        struct(env = dict for repository_ctx.execute, home = resolved OCX_HOME).
    """
    if isolated_home:
        home = str(ctx.path(".ocx_home"))
    else:
        home = ctx.getenv("OCX_HOME")
        if not home:
            base = ctx.getenv("USERPROFILE") if ctx.os.name.lower().startswith("windows") else ctx.getenv("HOME")
            if not base:
                fail("rules_ocx: cannot resolve the default OCX_HOME — neither OCX_HOME nor HOME/USERPROFILE is set")
            home = base + ("\\.ocx" if ctx.os.name.lower().startswith("windows") else "/.ocx")

    # `ocx run` exports OCX_PROJECT (possibly relative) into child processes;
    # a bazel invoked that way would leak it into every repo-rule ocx call,
    # which runs from a different cwd. Project context only ever comes from
    # explicit --project flags here, so neutralize it (empty = unset).
    env = {"OCX_HOME": home, "OCX_PROJECT": ""}
    for key in OCX_PASSTHROUGH_ENV:
        value = ctx.getenv(key)
        if value != None:
            env[key] = value
    return struct(env = env, home = home)

def ocx_bin(ctx):
    """Resolves the ocx binary path from the rule's `ocx` label attribute.

    On Windows the executable lives next to the stable `ocx` file as
    `ocx.exe`; prefer it when present.

    Args:
        ctx: repository_ctx with an `ocx` label attr.

    Returns:
        path object of the executable to invoke.
    """
    stable = ctx.path(ctx.attr.ocx)
    exe = stable.dirname.get_child(stable.basename + ".exe")
    return exe if exe.exists else stable

def run_ocx(ctx, binary, args, env, what, hints = {}, retries = 0):
    """Runs the ocx CLI, mapping failures to actionable messages.

    Args:
        ctx: repository_ctx.
        binary: path of the ocx executable.
        args: argv after the binary.
        env: environment dict (from make_ocx_env().env).
        what: short human description used in error messages.
        hints: {exit_code: extra hint} overriding the sysexits defaults.
        retries: extra attempts after a failure. Repo rules fetch in
            parallel, and concurrent `ocx package install` calls of the same
            package can race on store symlink creation (ocx TOCTOU); the
            store is idempotent, so a retry converges.

    Returns:
        stdout string.
    """
    result = None
    for _ in range(retries + 1):
        result = ctx.execute([str(binary)] + args, environment = env, timeout = 600)
        if result.return_code == 0:
            return result.stdout
    hint = hints.get(result.return_code) or _SYSEXIT_HINTS.get(result.return_code, "")
    fail("rules_ocx: {} failed (exit {}): ocx {}\n{}{}".format(
        what,
        result.return_code,
        " ".join([str(a) for a in args]),
        result.stderr.strip(),
        "\nhint: " + hint if hint else "",
    ))

def decode_json(stdout, what):
    """json.decode with an error message naming the failing command."""
    if not stdout.strip():
        fail("rules_ocx: {} produced no output — expected JSON".format(what))
    return json.decode(stdout)

def list_executables(ctx, directory, is_windows):
    """Lists executable file names in a directory (non-recursive).

    Args:
        ctx: repository_ctx.
        directory: absolute directory path string.
        is_windows: host flag; on Windows executables are picked by extension,
            elsewhere by the executable bit.

    Returns:
        list of basenames, directory order.
    """
    path = ctx.path(directory)
    if not path.exists:
        return []
    if is_windows:
        names = []
        for child in path.readdir():
            lower = child.basename.lower()
            if lower.endswith(".exe") or lower.endswith(".bat") or lower.endswith(".cmd"):
                names.append(child.basename)
        return names
    result = ctx.execute([
        "/bin/sh",
        "-c",
        'for f in "$0"/* ; do if [ -f "$f" ] && [ -x "$f" ]; then printf "%s\\n" "${f##*/}"; fi; done',
        directory,
    ])
    if result.return_code != 0:
        return []
    return [name for name in result.stdout.splitlines() if name]

def scan_bins(ctx, entries, is_windows):
    """Discovers runnable tools from the `path`-typed env entries.

    Mirrors ocx PATH semantics: entries in declaration order, first name
    wins. Windows binaries are keyed by their extension-less name.

    Args:
        ctx: repository_ctx.
        entries: env entries [{"key", "value", "type"}, ...] from `ocx env`.
        is_windows: host flag.

    Returns:
        list of struct(name, target) in discovery order, where target is the
        absolute path of the real executable.
    """
    seen = {}
    bins = []
    for entry in entries:
        if entry["type"] != "path":
            continue
        for basename in list_executables(ctx, entry["value"], is_windows):
            name = basename
            if is_windows and "." in basename:
                name = basename[:basename.rfind(".")]
            if name in seen:
                continue
            seen[name] = True
            bins.append(struct(name = name, target = entry["value"] + "/" + basename))
    return bins

def render_launcher(entries, target, home, ocx, is_windows):
    """Renders a launcher script applying the ocx env and exec-ing a tool.

    `path` entries prepend to the invoking environment; `constant` entries
    replace. OCX_HOME and OCX_BINARY_PIN are baked so ocx entrypoint
    launchers re-enter the pinned ocx against the right store.

    Args:
        entries: env entries [{"key", "value", "type"}, ...].
        target: absolute path of the executable to exec.
        home: resolved OCX_HOME.
        ocx: absolute path of the pinned ocx binary.
        is_windows: render .bat instead of POSIX sh.

    Returns:
        script content string.
    """
    path_values = {}  # key -> [values] in declaration order
    constants = []  # (key, value)
    for entry in entries:
        if entry["type"] == "path":
            path_values.setdefault(entry["key"], []).append(entry["value"])
        else:
            constants.append((entry["key"], entry["value"]))

    if is_windows:
        lines = ["@echo off", "rem Generated by rules_ocx - do not edit."]
        lines.append('set "OCX_HOME={}"'.format(home))
        lines.append('set "OCX_BINARY_PIN={}"'.format(ocx))
        for key, value in constants:
            lines.append('set "{}={}"'.format(key, value))
        for key, values in path_values.items():
            lines.append('set "{}={};%{}%"'.format(key, ";".join(values), key))
        lines.append('"{}" %*'.format(target))
        return "\r\n".join(lines) + "\r\n"

    lines = ["#!/usr/bin/env bash", "# Generated by rules_ocx — do not edit.", "set -euo pipefail"]
    lines.append('export OCX_HOME="{}"'.format(home))
    lines.append('export OCX_BINARY_PIN="{}"'.format(ocx))
    for key, value in constants:
        lines.append('export {}="{}"'.format(key, value))
    for key, values in path_values.items():
        joined = ":".join(values)
        lines.append('export {key}="{values}${{{key}:+:${{{key}}}}}"'.format(key = key, values = joined))
    lines.append('exec "{}" "$@"'.format(target))
    return "\n".join(lines) + "\n"

def render_env_bzl(entries, home):
    """Renders the generated repo's env.bzl.

    JSON round-trip keeps escaping correct for arbitrary values.

    Args:
        entries: env entries from `ocx env`.
        home: resolved OCX_HOME.

    Returns:
        env.bzl content string.
    """
    payload = json.encode({"entries": entries, "home": home})
    return "\n".join([
        '"""Generated by rules_ocx — composed ocx environment."""',
        "",
        "_DATA = json.decode({})".format(repr(payload)),
        "",
        "# Ordered [{\"key\", \"value\", \"type\"}, ...]; type is \"path\" (prepend) or \"constant\" (replace).",
        'OCX_ENV = _DATA["entries"]',
        "",
        "# The OCX_HOME these paths point into.",
        'OCX_HOME = _DATA["home"]',
        "",
    ])

def render_launchers_build(bins, is_windows, extra = ""):
    """Renders a generated BUILD file exposing one runnable target per tool.

    Args:
        bins: list of struct(name, target) from scan_bins().
        is_windows: host flag (launcher extension and native_binary out name).
        extra: additional BUILD content appended verbatim.

    Returns:
        BUILD file content string.
    """
    ext = ".bat" if is_windows else ".sh"
    parts = [
        'load("@bazel_skylib//rules:native_binary.bzl", "native_binary")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for b in bins:
        parts.append("native_binary(")
        parts.append('    name = "{}",'.format(b.name))
        parts.append('    src = "launchers/{}{}",'.format(b.name, ext))
        if is_windows:
            parts.append('    out = "{}.bat",'.format(b.name))
        parts.append(")")
        parts.append("")
    if extra:
        parts.append(extra)
    return "\n".join(parts)

def write_launchers(ctx, bins, entries, home, ocx, is_windows):
    """Writes launcher scripts for all discovered tools.

    Args:
        ctx: repository_ctx.
        bins: list of struct(name, target) from scan_bins().
        entries: env entries applied by every launcher.
        home: resolved OCX_HOME.
        ocx: absolute path string of the pinned ocx binary.
        is_windows: host flag.
    """
    ext = ".bat" if is_windows else ".sh"
    for b in bins:
        ctx.file(
            "launchers/" + b.name + ext,
            render_launcher(entries, b.target, home, ocx, is_windows),
            executable = True,
        )
