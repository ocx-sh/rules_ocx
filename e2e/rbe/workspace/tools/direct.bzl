# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""A rule that starts a tool with `ctx.actions.run`: no shell between Bazel and the tool."""

def _direct_run_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run(
        executable = ctx.executable._capture,
        arguments = [out.path, ctx.executable.tool.path] + ctx.attr.tool_args,
        tools = [ctx.attr.tool[DefaultInfo].files_to_run, ctx.executable._capture],
        outputs = [out],
        mnemonic = "OcxDirect",
    )
    return [DefaultInfo(files = depset([out]))]

direct_run = rule(
    implementation = _direct_run_impl,
    doc = "Runs `tool` directly (no shell) and writes its stdout to `<name>.txt`.",
    attrs = {
        "tool_args": attr.string_list(doc = "Arguments for the tool."),
        "tool": attr.label(executable = True, cfg = "exec", allow_files = True, mandatory = True, doc = "The tool to start."),
        "_capture": attr.label(
            default = "//tools:capture.bin",
            allow_single_file = True,
            executable = True,
            cfg = "exec",
        ),
    },
)
