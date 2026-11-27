# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Caches and facts. Witnesses: nginx `/v2/` lines of one leg, the
harness's ocx call log (the counting wrapper installed as @ocx_tool), execution-log input digests."""

from __future__ import annotations

import json
import shutil

import pytest
from conftest import BACKEND, REGISTRY, ROOT, RUN, Workspace, assert_ok, lock, ocx, output, pin, render

CONFIG = BACKEND
REMOTE_REPO_CACHE = ("--experimental_remote_repo_contents_cache",)


def vendor_calls(ws: Workspace, since: int) -> list[str]:
    return [line for line in ws.ocx_calls()[since:] if line.startswith("start ") and " vendor" in line]


def test_fresh_client_takes_the_set_from_the_remote_repo_contents_cache(workspace: Workspace, log) -> None:
    # Client a is the trusted writer: rig.bazelrc keeps local results (a repo contents entry is one) out of the cache.
    a = workspace.client("a")
    assert_ok(a.run("build", "//:tool_run", "--remote_upload_local_results", config=CONFIG, startup=REMOTE_REPO_CACHE,
                    lockfile="update"), "client a")  # fmt: skip
    # Control: flag off, the fresh client runs the set rule and reaches the registry.
    c = workspace.client("c")
    n, log_c = len(workspace.ocx_calls()), log
    log_c.mark()
    assert_ok(c.run("build", "//:tool_run", config=CONFIG, lockfile="update"), "client c (flag off)")
    assert vendor_calls(workspace, n) and log_c.registry(), "control: flag off made no ocx call or no registry request"
    b = workspace.client("b")
    n = len(workspace.ocx_calls())
    log.mark()
    assert_ok(b.run("build", "//:tool_run", config=CONFIG, startup=REMOTE_REPO_CACHE, lockfile="update"), "client b")
    assert vendor_calls(workspace, n) == []
    assert log.registry() == []
    assert output(b, "tool_run.txt").strip() == "tool platform=linux/amd64 libc=glibc"


def _set_digests(res) -> dict[str, str]:
    spawn = next(s for s in res.spawns() if "set_inputs" in json.dumps(s.get("listedOutputs", [])))
    marker = "tools_linux_amd64_libc_glibc/"
    return {i["path"].split(marker, 1)[1]: json.dumps(i.get("digest"), sort_keys=True)
            for i in spawn["inputs"] if marker in i["path"]}  # fmt: skip


def test_two_clients_give_identical_set_input_digests(workspace: Workspace) -> None:
    other = render(RUN / "ws" / (workspace.test_id + "-moved"), workspace.test_id + "-moved")
    a = workspace.client("a", umask=0o022, tz="UTC")
    b = other.client("b", umask=0o077, tz="Pacific/Kiritimati")
    try:
        ra = a.run("build", "//:set_inputs", config=CONFIG)
        rb = b.run("build", "//:set_inputs", config=CONFIG)
        assert_ok(ra, "client a")
        assert_ok(rb, "client b")
        da, db = _set_digests(ra), _set_digests(rb)
        assert da, "no set input in the execution log"
        assert da == db
    finally:
        b.shutdown()


def _hub_query(client, hub: str, lockfile: str):
    return client.run("query", f"@@rules_ocx++ocx+{hub}//:all", lockfile=lockfile)


def test_non_root_package_facts_need_no_registry(log) -> None:
    """A non-root module declares a package by digest; the root has no ocx.lock."""
    from conftest import Workspace as W
    from conftest import _counting_wrapper

    test_id = "v16-" + __import__("uuid").uuid4().hex[:6]
    ws_dir = RUN / "ws" / test_id
    shutil.rmtree(ws_dir, ignore_errors=True)
    (ws_dir / "dep").mkdir(parents=True)
    (ws_dir / "MODULE.bazel").write_text(
        'module(name = "v16_root")\nbazel_dep(name = "dep", version = "0.0.0")\n'
        'local_path_override(module_name = "dep", path = "dep")\n'
        f'bazel_dep(name = "rules_ocx", version = "0.0.0")\nlocal_path_override(module_name = "rules_ocx", path = "{ROOT}")\n'
    )  # fmt: skip
    (ws_dir / "BUILD.bazel").write_text("")
    (ws_dir / ".bazelversion").write_text((ROOT / ".bazelversion").read_text())
    (ws_dir / "dep" / "MODULE.bazel").write_text(
        'module(name = "dep", version = "0.0.0")\nbazel_dep(name = "rules_ocx", version = "0.0.0")\n'
        'ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")\n'
        f'ocx.package(name = "dep_tool", package = "{pin("rig/tool", "linux/amd64+libc.glibc")}", platforms = ["linux/amd64+libc.glibc"])\n'
        'use_repo(ocx, "dep_tool")\n'
    )  # fmt: skip
    (ws_dir / "dep" / "BUILD.bazel").write_text("")
    counter = ws_dir / ".ocx-calls.log"
    ws = W(ws_dir, test_id, counter, _counting_wrapper(ws_dir.parent / f"{test_id}-ocx", counter))
    try:
        assert_ok(_hub_query(ws.client("a"), "dep_tool", "update"), "client a writes the facts")
        assert '"package|dep_tool"' in (ws_dir / "MODULE.bazel.lock").read_text()
        b = ws.client("b")
        n = len(ws.ocx_calls())
        log.mark()
        assert_ok(_hub_query(b, "dep_tool", "error"), "client b, facts kept")
        assert (ws.ocx_calls()[n:], log.registry()) == ([], [])
        (ws_dir / "MODULE.bazel.lock").unlink()
        c = ws.client("c")
        n = len(ws.ocx_calls())
        log.mark()
        assert_ok(_hub_query(c, "dep_tool", "update"), "client c, facts deleted (control)")
        assert vendor_calls(ws, n) and log.registry(), "control: deleted facts made no ocx call or no request"
    finally:
        for cl in ws.clients:
            cl.shutdown()


def test_kept_lock_skips_ocx_and_registry_during_resolution(workspace: Workspace, log) -> None:
    assert_ok(_hub_query(workspace.client("a"), "tools", "update"), "client a")
    b = workspace.client("b")
    n = len(workspace.ocx_calls())
    log.mark()
    assert_ok(_hub_query(b, "tools", "error"), "client b, lock kept")
    assert (workspace.ocx_calls()[n:], log.registry()) == ([], [])
    (workspace.path / "MODULE.bazel.lock").unlink()
    c = workspace.client("c")
    n = len(workspace.ocx_calls())
    log.mark()
    assert_ok(_hub_query(c, "tools", "update"), "client c, lock deleted")
    assert vendor_calls(workspace, n) and log.registry()


def test_lock_edit_with_the_same_tool_names_recomputes_the_fact(workspace: Workspace) -> None:
    a = workspace.client("a")
    assert_ok(_hub_query(a, "tools", "update"), "first resolution")
    n = len(workspace.ocx_calls())
    assert_ok(_hub_query(a, "tools", "update"), "unchanged lock")
    assert vendor_calls(workspace, n) == [], "control: an unchanged lock recomputed the fact"
    toml = workspace.path / "ocx.toml"
    toml.write_text(toml.read_text().replace("rig/tool:1.0.0", "rig/tool:1.0.1"))
    lock(workspace.path)
    n = len(workspace.ocx_calls())
    assert_ok(_hub_query(a, "tools", "update"), "edited lock")
    assert vendor_calls(workspace, n)
    assert_ok(a.run("build", "//:tool_run", config=CONFIG, lockfile="update"), "tool_run after the edit")
    assert output(a, "tool_run.txt").strip() == "tool 1.0.1 platform=linux/amd64 libc=glibc"


def test_changed_platforms_recompute_the_fact_and_declare_the_set(workspace: Workspace) -> None:
    a = workspace.client("a")
    assert_ok(_hub_query(a, "tools", "update"), "first resolution")
    n = len(workspace.ocx_calls())
    assert_ok(_hub_query(a, "tools", "update"), "unchanged platforms")
    assert vendor_calls(workspace, n) == [], "control: unchanged platforms recomputed the fact"
    module = workspace.path / "MODULE.bazel"
    old = '        "linux/amd64+libc.musl",\n    ],'
    assert old in module.read_text()
    module.write_text(module.read_text().replace(old, '        "linux/amd64+libc.musl",\n        "linux/arm64+libc.glibc",\n    ],', 1))
    n = len(workspace.ocx_calls())
    res = _hub_query(a, "tools", "update")
    assert_ok(res, "added platform")
    assert vendor_calls(workspace, n)
    assert "linux_arm64_libc_glibc" in res.out


def _index(ws: Workspace) -> str:
    """A committed index snapshot holding rig/tool's tags, made with the ocx under test."""
    ocx(ws.path.parent / f"{ws.test_id}-indexhome", "--index", str(ws.path / "index"), "index", "update", f"{REGISTRY}/rig/tool")
    (ws.path / "BUILD.bazel").write_text((ws.path / "BUILD.bazel").read_text() + '\nexports_files(["index"])\n')
    return "//:index"


def _contents_entries(client) -> int:
    root = client.repo_cache / "contents"
    return sum(1 for _ in root.iterdir()) if root.exists() else 0


@pytest.mark.parametrize("form", ["pinned", "tagged", "tag"])
def test_only_a_digest_pinned_package_is_reproducible(workspace: Workspace, form: str) -> None:
    """`pinned` and `tag` sets vendor `<repo>@<pin>` (reproducible); an `index` set vendors the identifier through its snapshot."""
    index = _index(workspace)
    module = workspace.path / "MODULE.bazel"
    module.write_text(module.read_text() + (
        f'\nocx.package(name = "tagged", package = "{REGISTRY}/rig/tool:1.0.0", index = "{index}", '
        'platforms = ["linux/amd64+libc.glibc"])\nuse_repo(ocx, "tagged_linux_amd64_libc_glibc")\n'
        f'ocx.package(name = "tag", package = "{REGISTRY}/rig/tool:1.0.0", platforms = ["linux/amd64+libc.glibc"])\n'
        'use_repo(ocx, "tag_linux_amd64_libc_glibc")\n'
    ))  # fmt: skip
    c = workspace.client(form)
    assert_ok(c.run("fetch", "--repo=@ocx_tool", lockfile="update"), "fetch @ocx_tool")  # its own entry, if any, comes first
    before = _contents_entries(c)
    assert_ok(c.run("fetch", f"--repo=@{form}_linux_amd64_libc_glibc", lockfile="update"), f"fetch {form}")
    entries = _contents_entries(c) - before
    assert (entries > 0) == (form in ("pinned", "tag")), f"{form}: {entries} repo contents cache entries"
