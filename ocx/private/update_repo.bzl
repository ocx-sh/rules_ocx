# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

"""The `ocx_update` repository: a data plan and the program that reads it.

The rule writes `plan.txt`, one value per line, and one program (`update.sh` or
`update.bat`) that reads it, so no tag value ever becomes program text. It
declares one executable target per hub, `hub_<name>`, and `update` for all
declarations. Not reproducible: the plan holds absolute paths of this machine.
"""

visibility(["//ocx", "//ocx/tests"])

UPDATE_SH_TEMPLATE = Label("//ocx/private:update.sh.tpl")
UPDATE_BAT_TEMPLATE = Label("//ocx/private:update.bat.tpl")

# buildifier: disable=unused-variable
def check_value(name, value, path = False):
    """Whether a value may reach the plan file (pure; E10).

    Tag values (hub names, identifiers, groups, bindings): first character
    `A-Za-z0-9`, then only `A-Za-z0-9._:/@+=,-`; no `..` segment; no userinfo,
    that is no `@` before the first `/`. A path may hold spaces and non-ASCII;
    only `"`, `%` and a newline are refused.

    Args:
        name: the declaration (hub) name, for the message.
        value: the value to check.
        path: True when the value is a file path.

    Returns:
        "" when the value is allowed, else
        `rules_ocx: '<name>': cannot write an update step for '<value>': <reason>`.
    """
    fail("unimplemented")

# buildifier: disable=unused-variable
def plan_content(declarations):
    """The `plan.txt` text (pure).

    Per declaration, one value per line in this fixed order: name, kind,
    main-repository flag (`true`/`false`), `write_path`, identifier, config,
    `no_config` (`true`/`false`), `allow_unverified`, `allow_yanked`,
    trusted root, the number of groups and each group, the number of bindings
    and each binding. An empty value is an empty line. No header, no
    separator: declarations follow one another.

    Args:
        declarations: list of struct(name, kind, main_repo, write_path,
            identifier, config, no_config, allow_unverified, allow_yanked,
            trusted_root, groups, bindings). `write_path` is
            `<package>/<name>` of the lock or snapshot, workspace-relative.

    Returns:
        the plan text, each line ending in a newline.
    """
    fail("unimplemented")

# buildifier: disable=unused-variable
def select_declarations(declarations, target, args, workspace):
    """Decides what an update run touches, before anything runs (pure).

    Checks in this order: E9 (`workspace` is None), then for the all-declarations
    target E3 (an argument starting with `-`) and E1 (an argument that is no
    hub name), then E2 (a package hub with arguments). No names selects every
    declaration. E4 (kind `pinned`) and E5 (`main_repo` false) become notices
    and leave the declaration out of `selected`. No declaration at all is the
    notice `rules_ocx: no ocx declarations`, exit 0.

    Args:
        declarations: list of struct(name, kind, main_repo).
        target: "" for `@rules_ocx//:update`, else the hub name.
        args: list of argument strings.
        workspace: value of BUILD_WORKSPACE_DIRECTORY, or None.

    Returns:
        struct(error, exit_code, selected, notices). `error` is "" or the
        E1/E2/E3/E9 text (exit code 64); `selected` the names whose steps run,
        in name order; `notices` the E4/E5 lines, or the no-declaration line.
    """
    fail("unimplemented")

# buildifier: disable=unused-variable
def _ocx_update_repo_impl(rctx):
    fail("unimplemented")

ocx_update_repo = repository_rule(
    implementation = _ocx_update_repo_impl,
    doc = """The update programs of every declaration.

Writes `plan.txt` and `update.sh` (or `update.bat` on Windows) from the
templates, and declares the targets `hub_<name>` and `update`.""",
    attrs = {
        "declarations": attr.string_list(
            doc = "One `json.encode`d object per declaration, with keys name, kind, main_repo (bool), identifier, no_config, allow_unverified, allow_yanked, groups, bindings.",
        ),
        "files": attr.string_keyed_label_dict(
            doc = "Keys `<name>:lock`, `<name>:index`, `<name>:config`, `<name>:trusted_root`.",
        ),
        "ocx": attr.label(
            mandatory = True,
            doc = "The ocx binary, `@ocx_tool//:ocx`; resolved with `rctx.path` only when the update is built.",
        ),
    },
)
