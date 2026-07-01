# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Project-tier repository rule: provision the workspace toolchain from
ocx.toml + ocx.lock via the ocx CLI (`lock --check` → `pull` → `env`), or —
with `bins` — lazily via launchers that re-enter `ocx run` at execution
time."""

load(":platforms.bzl", "host_info")
load(
    ":repo_utils.bzl",
    "decode_json",
    "make_ocx_env",
    "ocx_bin",
    "render_env_bzl",
    "render_launchers_build",
    "render_lazy_launcher",
    "rlocation_path",
    "run_ocx",
    "scan_bins",
    "write_launchers",
)

def _lazy_project(ctx, host, binary):
    """Renders text-only launchers deferring `ocx pull` to first execution.

    Nothing is materialized at fetch time: each launcher re-enters `ocx run`
    against copies of the project files. The copies are runfiles — action
    inputs — so tool actions re-key exactly when the lockfile changes, while
    tool content never becomes a Bazel input (a fully remote-cached build
    pulls nothing).
    """
    if ctx.attr.isolated_home:
        fail("rules_ocx: bins (lazy provisioning) is incompatible with isolated_home — " +
             "the store must be resolvable on whatever machine executes the launcher")
    ctx.file("ocx.toml", ctx.read(ctx.attr.ocx_toml))
    ctx.file("ocx.lock", ctx.read(ctx.attr.ocx_lock))
    groups = ["-g", ",".join(ctx.attr.groups)] if ctx.attr.groups else []
    ext = ".bat" if host.is_windows else ".sh"
    for name in ctx.attr.bins:
        if host.is_windows:
            command = ['"{}"'.format(binary), "--project", '"{}"'.format(ctx.path("ocx.toml")), "run"]
        else:
            command = [
                '"$(rlocation {})"'.format(rlocation_path(ctx.attr.ocx)),
                "--project",
                '"$(rlocation {}/ocx.toml)"'.format(ctx.name),
                "run",
            ]
        command += groups + ["--", name]
        ctx.file("launchers/" + name + ext, render_lazy_launcher(command, host.is_windows), executable = True)
    data = [":ocx.lock", ":ocx.toml", str(ctx.attr.ocx)]
    if not host.is_windows:
        data.append("@bazel_tools//tools/bash/runfiles")
    ctx.file("BUILD.bazel", render_launchers_build(
        [struct(name = name, target = None) for name in ctx.attr.bins],
        host.is_windows,
        extra = 'exports_files(["ocx.lock", "ocx.toml"])\n',
        data = data,
    ))

def _ocx_project_repo_impl(ctx):
    host = host_info(ctx.os.name, ctx.os.arch)
    binary = ocx_bin(ctx)
    toml = ctx.path(ctx.attr.ocx_toml)
    ctx.path(ctx.attr.ocx_lock)  # register the lock as an input — edits refetch
    ocx_env = make_ocx_env(ctx, ctx.attr.isolated_home)
    project = ["--project", str(toml)]

    run_ocx(
        ctx,
        binary,
        project + ["lock", "--check"],
        ocx_env.env,
        "checking {} against its lockfile".format(ctx.attr.ocx_toml),
        hints = {
            65: "run 'ocx lock' next to {} and commit the updated ocx.lock".format(ctx.attr.ocx_toml),
            78: "no ocx.lock next to {} — run 'ocx lock' and commit it".format(ctx.attr.ocx_toml),
        },
    )

    if ctx.attr.bins:
        _lazy_project(ctx, host, binary)
        return

    pull = project + ["pull"]
    if ctx.attr.groups:
        pull += ["-g", ",".join(ctx.attr.groups)]
    run_ocx(ctx, binary, pull, ocx_env.env, "pulling packages for " + str(ctx.attr.ocx_toml))

    stdout = run_ocx(
        ctx,
        binary,
        ["--format", "json"] + project + ["env"],
        ocx_env.env,
        "composing the environment of " + str(ctx.attr.ocx_toml),
    )
    entries = decode_json(stdout, "ocx env")["entries"]

    bins = scan_bins(ctx, entries, host.is_windows)
    write_launchers(ctx, bins, entries, ocx_env.home, str(binary), host.is_windows)
    ctx.file("env.bzl", render_env_bzl(entries, ocx_env.home))
    ctx.file("BUILD.bazel", render_launchers_build(
        bins,
        host.is_windows,
        extra = 'exports_files(["env.bzl"])\n',
    ))

ocx_project_repo = repository_rule(
    implementation = _ocx_project_repo_impl,
    doc = """Provisions the toolchain declared in a workspace ocx.toml/ocx.lock.

Fails when the lockfile is stale or missing (fix with `ocx lock`). Every
executable reachable through the composed environment's `path` entries
becomes a runnable target `//:<name>`; the raw environment is loadable from
`//:env.bzl` (`OCX_ENV`, `OCX_HOME`).

With `bins`, provisioning is lazy: nothing is pulled at fetch time, and each
named executable becomes a launcher that re-enters `ocx run` — content
materializes on first execution and never becomes a Bazel action input, so
fully remote-cached builds download no tool content at all.

Note: ocx composes the default group's environment; `groups` currently only
widens which groups are pulled into the store.""",
    attrs = {
        "bins": attr.string_list(
            doc = "Lazy provisioning: names of the executables to expose (not " +
                  "validated at fetch time). When set, nothing is pulled during the " +
                  "fetch — each name becomes a launcher re-entering `ocx run`, and " +
                  "actions key on the lockfile (a runfile) instead of tool content. " +
                  "Incompatible with isolated_home.",
        ),
        "groups": attr.string_list(
            doc = "Additional ocx.toml groups to pull (comma-joined into `ocx pull -g`).",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Keep the ocx store inside this repository instead of the shared user OCX_HOME.",
        ),
        "ocx": attr.label(
            default = "@ocx_tool//:ocx",
            allow_single_file = True,
            doc = "The pinned ocx CLI binary.",
        ),
        "ocx_lock": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The ocx.lock next to ocx_toml; watched so lock changes refetch.",
        ),
        "ocx_toml": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The project ocx.toml declaring the toolchain.",
        ),
    },
)
