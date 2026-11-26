"""Runs a hub tool in an action, with runfiles trees on or off, and records how it ended.

A vendored launcher finds its files in the runfiles tree of the action that
starts it. Without the tree it exits 78. The rule exists so that a test can show
both outcomes of the same tool in the same build, without a second Bazel
invocation: Windows has no runfiles tree unless `--enable_runfiles` is set.
"""

def _transition_impl(_settings, attr):
    # A tri-state option, set by its spelling on the command line.
    return {"//command_line_option:enable_runfiles": "yes" if attr.runfiles else "no"}

_runfiles_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = ["//command_line_option:enable_runfiles"],
)

def _launcher_status_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.run_shell(
        outputs = [out],
        tools = [ctx.executable.tool],
        # The action never fails: the test reads the exit code and the message.
        command = '"$1" --version > "$2" 2>&1; echo "exit=$?" >> "$2"; exit 0',
        arguments = [ctx.executable.tool.path, out.path],
        mnemonic = "LauncherStatus",
    )
    return [DefaultInfo(files = depset([out]))]

launcher_status = rule(
    implementation = _launcher_status_impl,
    cfg = _runfiles_transition,
    attrs = {
        "runfiles": attr.bool(
            mandatory = True,
            doc = "Whether the action's configuration builds runfiles trees.",
        ),
        "tool": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "A hub tool to start.",
        ),
    },
    doc = "Output `<name>.txt`: what the tool printed, then `exit=<code>`.",
)
