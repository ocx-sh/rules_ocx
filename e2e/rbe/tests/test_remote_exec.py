# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Remote execution on network-less executors. Each test carries its control case; the control that the executors
really have no network is test_executor_has_no_route."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from conftest import BACKEND, LOCK_HUB, LOCK_P, Workspace, assert_ok, fixtures, output, pkg_decl, platform_slug, tool_report

CONFIG = BACKEND  # buildbarn | nativelink


def manifest(client, repo: str) -> dict:
    return json.loads((client.external(repo) / "manifest.json").read_text(encoding="utf-8"))


def test_build_passes_on_network_less_executors(workspace: Workspace) -> None:
    # The control that "no network" holds is test_executor_has_no_route: the same probe reports a default route
    # on the client and none on the executor.
    c = workspace.client("a")
    res = c.run("build", "//:tool_run", config=CONFIG)
    assert_ok(res, "tool_run")
    assert res.processes().get("remote", 0) >= 1, res.processes()
    assert output(c, "tool_run.txt").strip() == "tool platform=linux/amd64 libc=glibc"


def test_executor_has_no_route(workspace: Workspace) -> None:
    """Red control of the whole file: an action run on the executor finds no default route, the same action run locally does."""
    c = workspace.client("a")
    local = c.run("build", "//:executor_net", "--spawn_strategy=local", "--action_env=RIG_PROBE=local", config=CONFIG)
    assert_ok(local, "executor_net, local")
    assert output(c, "executor_net.txt").strip() == "default-route=yes", "the probe cannot see a route even where one exists"
    remote = c.run("build", "//:executor_net", "--action_env=RIG_PROBE=remote", config=CONFIG)
    assert_ok(remote, "executor_net, remote")
    assert remote.processes().get("remote", 0) >= 1, remote.processes()
    assert output(c, "executor_net.txt").strip() == "default-route=none"


def test_exec_platform_selects_its_set(workspace: Workspace, log) -> None:
    c = workspace.client("a")
    # The host platform is always an execution platform too; making it exec_none leaves no platform a toolchain fits.
    control = c.run("build", "//:tool_run", "--extra_execution_platforms=//platforms:exec_none",
                    "--host_platform=//platforms:exec_none", config=CONFIG)  # fmt: skip
    assert control.rc != 0 and "toolchain" in control.out.lower(), control.out[-2000:]
    log.mark()
    res = c.run("build", "//:tool_run", "--extra_execution_platforms=//platforms:exec_glibc", config=CONFIG)
    assert_ok(res, "tool_run on exec_glibc")
    uris = [r["uri"] for r in log.registry()]
    digests = fixtures()["rig/tool"]["1.0.0"]
    assert any(digests["linux/amd64+libc.glibc"] in u for u in uris), uris
    others = [d for p, d in digests.items() if p != "linux/amd64+libc.glibc"]
    assert not [u for u in uris if any(d in u for d in others)], uris


def _inputs_named_ocx(res) -> list[str]:
    return [i["path"] for s in res.spawns() for i in s.get("inputs", []) if Path(i["path"]).name in ("ocx", "ocx.exe")]


def test_no_ocx_among_action_inputs(workspace: Workspace) -> None:
    c = workspace.client("a")
    control = c.run("build", "//:ocx_input_control", config=CONFIG)
    assert_ok(control, "ocx_input_control")
    assert _inputs_named_ocx(control), "the scan finds no ocx input even where one is"
    res = c.run("build", "//:tool_run", config=CONFIG)
    assert_ok(res, "tool_run")
    assert not _inputs_named_ocx(res)


@pytest.mark.skipif(BACKEND != "buildbarn", reason="the no-shell runner is a Buildbarn worker (compose runner-noshell)")
def test_direct_start_on_shell_less_runner(workspace: Workspace) -> None:
    c = workspace.client("a")
    control = c.run("build", "//:sh_direct_control", config="buildbarn_noshell")
    assert control.rc != 0 and "no such file or directory" in control.out.lower(), control.out[-2000:]
    res = c.run("build", "//:tool_direct", config="buildbarn_noshell")
    assert_ok(res, "tool_direct on the no-shell runner")
    assert output(c, "tool_direct.txt").strip() == "tool platform=linux/amd64 libc=glibc"
    genrule = c.run("build", "//:tool_run", config="buildbarn")
    assert_ok(genrule, "tool_run on the shell runner")


def test_wasm_package_is_an_action_input(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:wasm_read", config=CONFIG)
    assert_ok(res, "wasm_read")
    assert output(c, "wasm_read.txt").split() == ["00", "61", "73", "6d"]
    wasm = manifest(c, "wasm_wasip1_wasm")
    assert not [t for t in wasm.get("tools", []) if t.get("launcher_path")], wasm.get("tools")
    # Control: a package with a launcher does carry one.
    assert_ok(c.run("fetch", "--repo=@tools_linux_amd64_libc_glibc"), "fetch tools set")
    assert [t for t in manifest(c, "tools_linux_amd64_libc_glibc")["tools"] if t.get("launcher_path")]


def _manifest_links(m: dict) -> dict[str, str]:
    out = {}
    for pkg in m["packages"]:
        for link in pkg["tree"]["links"]:
            out[link["path"]] = link["target"]
    return out


def test_links_are_links_with_their_targets(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:links_read", config=CONFIG)
    assert_ok(res, "links_read")
    seen = dict(line.split(" ", 1) for line in output(c, "links_read.txt").splitlines())
    want = _manifest_links(manifest(c, "links_linux_amd64"))
    assert want, "the links fixture declares no link"
    assert {k.split("links_linux_amd64/", 1)[-1]: v for k, v in seen.items()} == want


@pytest.mark.parametrize(("platform", "libc"), [("exec_glibc", "glibc"), ("exec_musl", "musl")])
def test_libc_leaf(workspace: Workspace, platform: str, libc: str) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:tool_run", f"--extra_execution_platforms=//platforms:{platform}", config=CONFIG)
    assert_ok(res, f"tool_run on {platform}")
    assert output(c, "tool_run.txt").strip() == f"tool platform=linux/amd64 libc={libc}"


def test_entry_point_without_ocx(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:entry_run", config=CONFIG)
    assert_ok(res, "entry_run")
    assert output(c, "entry_run.txt").strip() == "entry hello"
    assert not _inputs_named_ocx(res)


def test_directory_labels_give_the_file_label_input_list(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:set_inputs", config=CONFIG)
    assert_ok(res, "set_inputs")
    repo = c.external("tools_linux_amd64_libc_glibc")
    reference = sorted(
        str(p.relative_to(repo)) for p in repo.rglob("*")
        if (p.is_file() or p.is_symlink()) and p.relative_to(repo).parts[0] in ("packages", "selections")
    )  # fmt: skip
    assert reference, f"no vendored file under {repo}"
    spawn = next(s for s in res.spawns() if "set_inputs" in json.dumps(s.get("listedOutputs", [])))
    got = sorted(i["path"].split("tools_linux_amd64_libc_glibc/", 1)[1] for i in spawn["inputs"]
                 if "tools_linux_amd64_libc_glibc/" in i["path"])  # fmt: skip
    assert got[:-1] != reference, "control: the reference minus one file still compares equal"
    assert got == reference


@pytest.mark.parametrize(("target", "want"), [("cmake_finds_ccache", "ccache-found"), ("cmake_finds_ccache_alone", "ccache-missing")])
def test_a_tool_brings_its_whole_set(workspace: Workspace, target: str, want: str) -> None:
    c = workspace.client("a")
    res = c.run("build", f"//:{target}", config=CONFIG)
    assert_ok(res, target)
    assert output(c, f"{target}.txt").split() == ["cmake", want]


def test_reserved_names_at_their_places(workspace: Workspace) -> None:
    c = workspace.client("a")
    res = c.run("build", "//:buildfiles_read", config=CONFIG)
    assert_ok(res, "buildfiles_read")
    lines = output(c, "buildfiles_read.txt").splitlines()
    assert lines[0] == "buildfiles"
    names = {Path(p).name: p for p in lines[1:]}
    assert {"BUILD.bazel", "build", "BUILD"} <= set(names), lines
    assert names["BUILD"].endswith("sub/BUILD") and Path(names["BUILD.bazel"]).parent == Path(names["build"]).parent


def test_tag_locked_tool_runs_remotely(lockrig) -> None:
    """A tag declaration's set vendors the locked digest: after the tag moved, a second client gives the same set inputs."""
    hub = LOCK_HUB
    lockrig.push("1.0", "tool v1")
    ws = lockrig.workspace(pkg_decl(hub, lockrig.ident("1.0")), {hub: [LOCK_P]})
    targets = (f"//:inputs_{hub}", f"//:run_{hub}")
    marker = f"{hub}_{platform_slug(LOCK_P)}/"

    def set_digests(res) -> dict[str, str]:
        spawn = next(s for s in res.spawns() if f"inputs_{hub}" in json.dumps(s.get("listedOutputs", [])))
        return {i["path"].split(marker, 1)[1]: json.dumps(i.get("digest"), sort_keys=True) for i in spawn["inputs"] if marker in i["path"]}

    ra = ws.client("a").run("build", *targets, config=CONFIG, lockfile="update")
    assert_ok(ra, "client a")
    assert ra.processes().get("remote", 0) >= 1, ra.processes()
    lockrig.push("1.0", "tool v2")
    b = ws.client("b")
    rb = b.run("build", *targets, config=CONFIG, lockfile="error")
    assert_ok(rb, "client b, tag moved")
    assert rb.processes().get("remote", 0) >= 1, rb.processes()
    assert tool_report(b, hub) == "tool v1"
    da = set_digests(ra)
    assert da, "no set input in the execution log"
    assert da == set_digests(rb)
