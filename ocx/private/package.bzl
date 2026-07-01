# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""Package-tier repository rules: provision a single OCI package via the ocx
CLI (`package install` → `package which` → `package env`), plus the
multi-platform hub that select()s between per-platform repos."""

load(":platforms.bzl", "OCX_PLATFORMS", "host_info")
load(
    ":repo_utils.bzl",
    "decode_json",
    "make_ocx_env",
    "ocx_bin",
    "render_env_bzl",
    "render_launchers_build",
    "run_ocx",
    "scan_bins",
    "write_launchers",
)

def _platform_args(platform):
    return ["-p", platform] if platform else []

def _ocx_package_repo_impl(ctx):
    host = host_info(ctx.os.name, ctx.os.arch)
    binary = ocx_bin(ctx)
    ctx.path(ctx.attr.ocx)  # fetch ordering
    ocx_env = make_ocx_env(ctx, ctx.attr.isolated_home)
    pkg = ctx.attr.package
    json_pkg = ["--format", "json", "package"]
    runnable = ctx.attr.platform in ("", host.ocx_platform)

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["install"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "installing " + pkg,
    )
    report = decode_json(stdout, "ocx package install")
    identifier = report.values()[0]["identifier"]
    if "@sha256:" not in pkg:
        # buildifier: disable=print
        print("rules_ocx: '{}' resolved to '{}' — pin it in ocx.package(package = ...) for reproducibility".format(pkg, identifier))

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["which"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "locating " + pkg,
    )
    root = decode_json(stdout, "ocx package which").values()[0]

    stdout = run_ocx(
        ctx,
        binary,
        json_pkg + ["env"] + _platform_args(ctx.attr.platform) + [pkg],
        ocx_env.env,
        "composing the environment of " + pkg,
    )
    entries = decode_json(stdout, "ocx package env")["entries"]

    # The store is content-addressed and digest-pinned: symlinks into it are
    # stable for the lifetime of the pin.
    ctx.symlink(root + "/content", "content")
    if ctx.path(root + "/entrypoints").exists:
        ctx.symlink(root + "/entrypoints", "entrypoints")

    bins = scan_bins(ctx, entries, host.is_windows) if runnable else []
    write_launchers(ctx, bins, entries, ocx_env.home, str(binary), host.is_windows)
    ctx.file("env.bzl", render_env_bzl(entries, ocx_env.home))
    ctx.file("BUILD.bazel", render_launchers_build(
        bins,
        host.is_windows,
        extra = "\n".join([
            'exports_files(["env.bzl"])',
            "",
            "filegroup(",
            '    name = "content",',
            '    srcs = glob(["content/**"], allow_empty = True),',
            ")",
            "",
        ]),
    ))

ocx_package_repo = repository_rule(
    implementation = _ocx_package_repo_impl,
    doc = """Provisions a single OCX package from an OCI registry.

`//:content` is the package tree; every executable reachable through the
package environment becomes a runnable target `//:<name>` (host-platform
repos only). Pin with `registry/repo@sha256:…` for reproducibility —
floating tags resolve at fetch time and log the resolved digest.""",
    attrs = {
        "isolated_home": attr.bool(
            default = False,
            doc = "Keep the ocx store inside this repository instead of the shared user OCX_HOME.",
        ),
        "ocx": attr.label(
            default = "@ocx_tool//:ocx",
            allow_single_file = True,
            doc = "The pinned ocx CLI binary.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Fully-qualified identifier: 'registry/repo[:tag][@sha256:…]'.",
        ),
        "platform": attr.string(
            doc = "ocx platform key ('linux/amd64', …) to provision for; empty = host.",
        ),
    },
)

def _ocx_package_hub_impl(ctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    conditions = {}
    for platform, repo in ctx.attr.platform_repos.items():
        if platform not in OCX_PLATFORMS:
            fail("rules_ocx: unknown ocx platform '{}' (known: {})".format(
                platform,
                ", ".join(OCX_PLATFORMS.keys()),
            ))
        setting = platform.replace("/", "_")
        conditions[platform] = setting
        lines += [
            "config_setting(",
            '    name = "{}",'.format(setting),
            "    constraint_values = [",
        ] + ['        "{}",'.format(c) for c in OCX_PLATFORMS[platform]] + [
            "    ],",
            ")",
            "",
        ]
    lines += [
        "alias(",
        '    name = "content",',
        "    actual = select({",
    ]
    for platform, repo in ctx.attr.platform_repos.items():
        lines.append('        ":{}": "@{}//:content",'.format(conditions[platform], repo))
    lines += [
        "    }),",
        ")",
        "",
    ]
    ctx.file("BUILD.bazel", "\n".join(lines))

ocx_package_hub = repository_rule(
    implementation = _ocx_package_hub_impl,
    doc = """Multi-platform hub for an ocx.package() with `platforms`.

`//:content` select()s the per-platform package repo matching the target
platform — combine with a platform transition to fetch foreign-platform
tools (e.g. for container images).""",
    attrs = {
        "platform_repos": attr.string_dict(
            mandatory = True,
            doc = "ocx platform key -> apparent name of the per-platform package repo.",
        ),
    },
)
