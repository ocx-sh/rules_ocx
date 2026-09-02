# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Project-tier repository rule: provision the workspace toolchain from
ocx.toml + ocx.lock via the ocx CLI (`lock --check` → `pull` → `env`), or —
with `bins` — lazily via launchers that re-enter `ocx exec` at execution
time."""

load(":platforms.bzl", "host_info")
load(
    ":repo_utils.bzl",
    "CONFIG_ATTRS",
    "EAGER_LAZY_MODE",
    "POLICY_ATTRS",
    "bat_value",
    "check_bin_names",
    "decode_json",
    "discover_bins",
    "make_ocx_env",
    "ocx_bin",
    "render_env_bzl",
    "render_launchers_build",
    "render_lazy_launcher",
    "rlocation_path",
    "run_ocx",
    "sh_quote",
    "stage_lazy_config",
    "write_launchers",
)

visibility(["//ocx", "//ocx/tests"])

def pull_args(project, target, groups):
    """The argv for `ocx pull` (pure).

    Args:
        project: `["--project", <toml path>]`.
        target: `["--platform", <platform>]`, or `[]` for the host.
        groups: `ctx.attr.groups`.

    Returns:
        argv list, after the ocx binary.
    """
    args = project + ["pull"] + target + EAGER_LAZY_MODE
    if groups:
        args += ["-g", ",".join(groups)]
    return args

def lazy_project_command(binary, toml, groups, name):
    """The lazy launcher argv that re-enters ocx at execution time (pure).

    `exec`, not `run`: 0.6.0 hides `ocx run` behind a deprecation warning on
    every invocation and 0.7 deletes it, so a launcher baked with the old verb
    is noisy today and broken on the next CLI bump.

    Args:
        binary: the ocx binary argv fragment, already quoted per OS by the caller.
        toml: the `--project` value argv fragment, already quoted per OS.
        groups: `["-g", <already-quoted groups>]`, or `[]`.
        name: the bin name to run — becomes the trailing `-- <name>`.

    Returns:
        argv list; every element arrives already quoted per OS by the caller,
        this builder quotes nothing.
    """
    return [binary, "--project", toml, "exec"] + groups + ["--", name]

def _lazy_project(ctx, host, binary):
    """Renders text-only launchers deferring `ocx pull` to first execution.

    Nothing is materialized at fetch time: each launcher re-enters `ocx exec`
    against copies of the project files. The copies are runfiles — action
    inputs — so tool actions re-key exactly when the lockfile changes, while
    tool content never becomes a Bazel input (a fully remote-cached build
    pulls nothing).
    """
    if ctx.attr.isolated_home:
        fail("rules_ocx: bins (lazy provisioning) is incompatible with isolated_home — " +
             "the store must be resolvable on whatever machine executes the launcher")
    check_bin_names(ctx.attr.bins)
    ctx.file("ocx.toml", ctx.read(ctx.attr.ocx_toml))
    ctx.file("ocx.lock", ctx.read(ctx.attr.ocx_lock))
    staged = stage_lazy_config(ctx, host.is_windows)
    groups = []
    if ctx.attr.groups:
        joined = ",".join(ctx.attr.groups)
        if host.is_windows:
            # Same asymmetry the package tier had: the POSIX arm quotes, so
            # the Batch arm must refuse rather than interpolate bare. Only the
            # root module sets `groups`, so this is a footgun, not a
            # supply-chain path — but it is the same bug either way.
            safe_groups = bat_value(joined)
            if safe_groups == None:
                fail(("rules_ocx: refusing to render a lazy launcher for groups '{}' — a " +
                      "literal quote has no escape inside a batch file").format(joined))
            groups = ["-g", '"{}"'.format(safe_groups)]
        else:
            groups = ["-g", sh_quote(joined)]
    ext = ".bat" if host.is_windows else ".sh"
    for name in ctx.attr.bins:
        if host.is_windows:
            command = lazy_project_command(
                '"{}"'.format(binary),
                '"{}"'.format(ctx.path("ocx.toml")),
                groups,
                name,
            )
        else:
            command = lazy_project_command(
                '"$(rlocation {})"'.format(rlocation_path(ctx.attr.ocx)),
                '"$(rlocation {}/ocx.toml)"'.format(ctx.name),
                groups,
                name,
            )
        ctx.file(
            "launchers/" + name + ext,
            render_lazy_launcher(command, host.is_windows, exports = staged.exports),
            executable = True,
        )
    data = [":ocx.lock", ":ocx.toml", str(ctx.attr.ocx)] + staged.data
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
    ocx_env = make_ocx_env(ctx, host, ctx.attr.isolated_home)
    project = ["--project", str(toml)]

    run_ocx(
        ctx,
        binary,
        project + ["lock", "--check"],
        ocx_env.env,
        "checking {} against its lockfile".format(ctx.attr.ocx_toml),
        host.is_windows,
        hints = {
            65: "run 'ocx lock' next to {} and commit the updated ocx.lock".format(ctx.attr.ocx_toml),
            78: ("missing or unsupported ocx.lock next to {} — run 'ocx lock' with the " +
                 "pinned ocx and commit the result, or run 'ocx config update' if a " +
                 "required managed config is unsynced").format(ctx.attr.ocx_toml),
        },
    )

    if ctx.attr.bins:
        if ctx.attr.platform:
            fail("rules_ocx: platform is incompatible with bins (lazy provisioning) — " +
                 "lazy launchers re-enter `ocx exec`, which resolves the executing " +
                 "host's platform at run time")
        _lazy_project(ctx, host, binary)
        return

    target = ["--platform", ctx.attr.platform] if ctx.attr.platform else []
    no_leaf = {
        78: ("a tool in scope ships no '{}' leaf in ocx.lock — narrow `groups` or drop the " +
             "platform; an unsynced required managed config also exits 78 " +
             "('ocx config update')").format(
            ctx.attr.platform or host.ocx_platform,
        ),
    }
    pull = pull_args(project, target, ctx.attr.groups)
    run_ocx(
        ctx,
        binary,
        pull,
        ocx_env.env,
        "pulling packages for " + str(ctx.attr.ocx_toml),
        host.is_windows,
        hints = no_leaf,
    )

    env_cmd = ["--format", "json"] + project + ["env"] + target + EAGER_LAZY_MODE
    if ctx.attr.groups:
        env_cmd += ["-g", ",".join(ctx.attr.groups)]
    stdout = run_ocx(
        ctx,
        binary,
        env_cmd,
        ocx_env.env,
        "composing the environment of " + str(ctx.attr.ocx_toml),
        host.is_windows,
        hints = no_leaf,
    )
    entries = decode_json(stdout, "ocx env")["entries"]

    # Foreign platforms expose no launchers, so they skip the closure call too.
    runnable = ctx.attr.platform in ("", host.ocx_platform)
    discovered = struct(bins = [], scanned = [], rejected = [])
    if runnable:
        closure_cmd = ["--format", "json"] + project + ["inspect", "--closure"]
        if ctx.attr.groups:
            closure_cmd += ["-g", ",".join(ctx.attr.groups)]

        # `inspect --closure` spends its 65 on a closure conflict, not on a
        # stale lockfile — `lock --check` already passed above.
        closure_hints = dict(no_leaf)
        closure_hints[65] = ("the composed closure conflicts — two tools in scope declare the " +
                             "same entrypoint, or one repository resolved to two digests; run " +
                             "'ocx inspect --closure' next to {} to see the pair, then narrow " +
                             "`groups` or reconcile the versions").format(ctx.attr.ocx_toml)
        discovered = discover_bins(
            ctx,
            run_ocx(
                ctx,
                binary,
                closure_cmd,
                ocx_env.env,
                "reading the declared tool surface of " + str(ctx.attr.ocx_toml),
                host.is_windows,
                hints = closure_hints,
            ),
            "ocx inspect --closure",
            entries,
            host.is_windows,
        )
    write_launchers(ctx, discovered.bins, entries, ocx_env.home, str(binary), host.is_windows)
    ctx.file("env.bzl", render_env_bzl(entries, ocx_env.home, discovered.scanned, discovered.rejected))
    ctx.file("BUILD.bazel", render_launchers_build(
        discovered.bins,
        host.is_windows,
        extra = 'exports_files(["env.bzl"])\n',
    ))

ocx_project_repo = repository_rule(
    implementation = _ocx_project_repo_impl,
    doc = """Provisions the toolchain declared in a workspace ocx.toml/ocx.lock.

Fails when the lockfile is stale or missing (fix with `ocx lock`). Every
executable the toolchain's packages declare as their public surface
(`ocx inspect --closure`) becomes a runnable target `//:<name>`; a package
shipping no complete `binaries` metadata falls back to scanning the composed
PATH, which also exposes its private executables — `//:env.bzl`'s
`OCX_SCANNED_PACKAGES` names the packages that forced it. The raw
environment is loadable from the same file (`OCX_ENV`, `OCX_HOME`).

With `bins`, provisioning is lazy: nothing is pulled at fetch time, and each
named executable becomes a launcher that re-enters `ocx exec` — content
materializes on first execution and never becomes a Bazel action input, so
fully remote-cached builds download no tool content at all.

`groups` scopes both the pull and the composed environment. Omitted, ocx's
defaults apply: every group is pulled, but only the default `[tools]` table
is composed into launchers — name groups explicitly (or use the reserved
`all`) to expose their executables.

`platform` composes a foreign platform's environment from the same
ocx.lock: that platform's leaves are pulled into the store and `env.bzl`
holds their absolute store paths (sysroots, target libraries, container
image content). Foreign repos expose no runnable launchers — the binaries
do not run on this host.""",
    attrs = CONFIG_ATTRS | POLICY_ATTRS | {
        "bins": attr.string_list(
            doc = "Lazy provisioning: names of the executables to expose (not " +
                  "validated at fetch time). When set, nothing is pulled during the " +
                  "fetch — each name becomes a launcher re-entering `ocx exec`, and " +
                  "actions key on the lockfile (a runfile) instead of tool content. " +
                  "Incompatible with isolated_home.",
        ),
        "groups": attr.string_list(
            doc = "ocx.toml groups to provision (comma-joined into `-g` for " +
                  "`ocx pull`, `ocx env`, and lazy `ocx exec`). Reserved names: " +
                  "'default' = the top-level [tools] table, 'all' = default + " +
                  "every declared group.",
        ),
        "isolated_home": attr.bool(
            default = False,
            doc = "Keep the ocx store inside this repository instead of the shared user " +
                  "OCX_HOME. It also relocates OCX_HOME, so ocx's " +
                  "`~/.ocx/sigstore/trusted-root.json` rung is not found there — with a " +
                  "trust policy configured, trusted-root resolution falls through to the " +
                  "Rekor trust-root cache and then a live TUF fetch; offline it stops at the " +
                  "cache and fails outright, as ocx ships no embedded root.",
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
        "platform": attr.string(
            doc = "ocx platform key ('linux/arm64', …) to compose for; empty = host. " +
                  "A foreign platform pulls that platform's leaves from the same " +
                  "ocx.lock and exposes env.bzl only (no runnable launchers). " +
                  "Incompatible with bins — lazy launchers already resolve the " +
                  "executing host at run time.",
        ),
    },
)
