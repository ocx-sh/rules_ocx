"""Minimal platform-transitioned filegroup (avoids an aspect_bazel_lib dep)."""

def _transition_impl(_settings, attr):
    return {"//command_line_option:platforms": str(attr.target_platform)}

_platform_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _platform_filegroup_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        src[DefaultInfo].files
        for src in ctx.attr.srcs
    ]))]

platform_filegroup = rule(
    implementation = _platform_filegroup_impl,
    attrs = {
        "srcs": attr.label_list(cfg = _platform_transition),
        "target_platform": attr.label(mandatory = True),
    },
    doc = "Filegroup whose srcs are built for target_platform.",
)
