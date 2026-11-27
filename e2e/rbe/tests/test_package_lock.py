# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Package locking (ADR 0003 § Test plan, e2e rows): a tag or index declaration records one platform manifest
digest per platform in MODULE.bazel.lock, and every set vendors `<repo>@<pin>`.

Each test publishes to a repository of its own (`lockrig.push`) and builds a minimal workspace over it
(`lockrig.workspace`), so moving a tag or deleting a manifest never touches a fixture another test reads.
Witnesses: MODULE.bazel.lock, the harness's ocx call log, nginx's `/v2/` lines, Bazel's output."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import time

import pytest
from conftest import (
    LOCK_HUB as H,
    LOCK_MUSL,
    LOCK_P as P,
    REGISTRY,
    ROOT,
    RUN,
    Workspace,
    _counting_wrapper,
    assert_ok,
    drop_fact,
    hub_query,
    lock_facts,
    ocx,
    ocx_work,
    pkg_decl,
    plant_fact,
    platform_slug,
    resolve_calls,
    run_hub,
    run_update,
    set_calls,
    tool_report,
    tree_bytes,
    update_client,
    ws_bytes,
)
from test_offline import offline

KEY = f"package|{H}"
SET = f"{H}_{platform_slug(P)}"


def _pin(ws, platform: str = P) -> str:
    return lock_facts(ws)[KEY]["pins"][platform]


def _tag_ws(lockrig, tag: str = "1.0", **kw):
    return lockrig.workspace(pkg_decl(H, lockrig.ident(tag)), {H: [P]}, **kw)


def test_moved_tag_keeps_the_locked_digests(lockrig, log) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    a = ws.client("a")
    assert_ok(run_hub(a, H), "client a, first resolution")
    assert tool_report(a, H) == "tool v1"
    assert _pin(ws) == first[P]
    lockrig.push("1.0", "tool v2")
    b = ws.client("b")
    log.mark()
    assert_ok(run_hub(b, H, lockfile="error"), "client b, clean output base, tag moved, lock kept")
    assert tool_report(b, H) == "tool v1"
    uris = lockrig.uris(log)
    assert not [u for u in uris if u.endswith("/manifests/1.0")], uris  # the tag is never asked again
    assert any("/manifests/sha256:" in u for u in uris), uris  # the old digest is


def test_pinned_index_digest_vendors_the_pins(lockrig) -> None:
    leaf = lockrig.push("1.0", "tool v1")
    index = lockrig.index_digest("1.0")
    assert index != leaf[P], "control: the declared digest must be the image index, not the leaf"
    ws = lockrig.workspace(pkg_decl(H, f"{lockrig.ident('1.0')}@{index}"), {H: [P]})
    a = ws.client("a")
    assert_ok(run_hub(a, H), "client a")
    assert _pin(ws) == leaf[P]
    lockrig.delete(index)
    b = ws.client("b")
    assert_ok(run_hub(b, H, lockfile="error"), "client b, the index is gone")
    assert tool_report(b, H) == "tool v1"


def test_error_mode_moved_tag_passes_update_fails(lockrig) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "client a, first resolution")
    switch = f"--repo_env=RULES_OCX_UPDATE={H}"
    control = hub_query(ws.client("control"), H, switch, lockfile="error")
    assert_ok(control, "switch run before the tag moved: unchanged digests pass")
    lockrig.push("1.0", "tool v2")
    assert_ok(hub_query(ws.client("b"), H, lockfile="error"), "error mode, tag moved: the fact answers")
    res = hub_query(ws.client("c"), H, switch, lockfile="error")
    assert res.rc != 0 and "facts" in res.out, "the switch run must fail with Bazel's text about the changed facts:\n" + res.out[-2000:]
    assert _pin(ws) == first[P], "error mode must not write the lock"


def test_fresh_home_tag_resolves(lockrig) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "a tag on a fresh OCX_HOME")
    calls = resolve_calls(ws)
    assert calls and all("--remote" in c for c in calls), calls
    assert _pin(ws) == first[P]


def test_tag_lock_vendors_the_platform_digest(lockrig) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    a = ws.client("a")
    assert_ok(run_hub(a, H), "client a")
    vendored = f"{REGISTRY}/{lockrig.repo}@{first[P]}"
    mine = [c for c in set_calls(ws) if vendored in c]
    assert mine and all(f"-p {P}" in c and "--remote" not in c for c in mine), set_calls(ws)
    manifest = json.loads((a.external(SET) / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["platform"] == P
    assert manifest["available_platforms"] == ["any"]
    lockrig.push("1.0", "tool v2")
    b = ws.client("b")
    assert_ok(run_hub(b, H, lockfile="error"), "client b, tag moved: the root-digest check still passes")
    assert tool_report(b, H) == "tool v1"


def test_platform_outside_the_index_is_refused(lockrig) -> None:
    arm = "linux/arm64+libc.glibc"
    lockrig.push("1.0", "tool v1")
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0"), platforms=(P, arm)), {H: [P, arm]})
    res = hub_query(ws.client("a"), H)
    assert res.rc != 0 and f"platform '{arm}' is not served by the lock" in res.out, res.out[-2000:]
    assert set_calls(ws) == [], "no set was fetched"
    assert len(resolve_calls(ws)) == 1, "the check runs after the first platform's resolve, before the second"
    # A bare platform manifest names no index: ocx reports `any`, which lists no requested platform.
    leaf = lockrig.push("1.0", "tool v1")[P]
    ws2 = lockrig.workspace(pkg_decl(H, f"{REGISTRY}/{lockrig.repo}@{leaf}"), {H: [P]}, name="-bare")
    res = hub_query(ws2.client("a"), H)
    assert res.rc != 0 and f"platform '{P}' is not served by the lock (available: any)" in res.out, res.out[-2000:]
    assert set_calls(ws2) == []


def test_full_vendor_refusal_is_not_hinted_as_gone(lockrig) -> None:
    # The metadata claims `ghost`; the content holds `bin/other`: `--manifest-only` cannot tell, a full vendor refuses (exit 65).
    lockrig.push("1.0", "tool v1", exe="other", meta={"binaries": ["ghost"]})
    ws = _tag_ws(lockrig)
    res = ws.client("a").run("fetch", f"--repo=@{SET}", lockfile="update")
    assert res.rc != 0 and "(exit 65)" in res.out and "ghost" in res.out, res.out[-2000:]
    assert KEY in lock_facts(ws), "the extension's fact is written"
    assert "may be gone from the registry" not in res.out, res.out[-2000:]


def test_snapshot_refresh_invalidates_the_fact(lockrig) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0"), index='"//:index"'), {H: [P]}, index=True)
    assert_ok(hub_query(ws.client("a"), H), "client a")
    assert _pin(ws) == first[P]
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("hit"), H), "client hit, snapshot unchanged")
    assert resolve_calls(ws, n) == [], "control: an unchanged snapshot keeps the fact"
    second = lockrig.push("1.0", "tool v2")
    lockrig.refresh_index(ws)
    assert_ok(hub_query(ws.client("b"), H), "client b, snapshot refreshed")
    assert resolve_calls(ws, n), "a refreshed snapshot must resolve again"
    assert _pin(ws) == second[P] != first[P]


def test_set_fetch_leaves_the_snapshot_unchanged(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0"), index='"//:index"'), {H: [P]}, index=True)
    before = tree_bytes(ws.path / "index")
    a = ws.client("a")
    assert_ok(hub_query(a, H), "resolve")
    assert_ok(a.run("fetch", f"--repo=@{SET}", lockfile="update"), "set fetch")
    assert tree_bytes(ws.path / "index") == before
    # Without the tag's row the snapshot cannot answer: a frozen resolve fails, it does not ask the registry.
    root = ws.path / "index"
    rows = [f for f in root.rglob("*.json") if f.relative_to(root).as_posix().endswith(f"/p/{lockrig.repo}.json")]
    assert len(rows) == 1, rows
    rows[0].unlink()
    res = hub_query(ws.client("b"), H)
    assert res.rc != 0 and "has no entry for" in res.out and f"run bazel run @{H}//:update" in res.out, res.out[-2000:]


def test_offline_fresh_tag_names_the_fix(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    host = ws.client("host")
    assert_ok(host.run("build", "--nobuild", f"//:run_{H}", lockfile="update"), "modules and the first resolution, online")
    (ws.path / "MODULE.bazel.lock").unlink()
    res = offline(ws.client("offline"), host, f"//:run_{H}")
    out = res.stdout + res.stderr
    assert res.returncode != 0 and "bcr.bazel.build" not in out, out[-2000:]
    assert f"hint: MODULE.bazel.lock holds no digests for '{H}'; resolve the tag once online" in out, out[-2000:]


def test_old_fact_misses_once(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "client a")
    plant_fact(ws, KEY, lambda fact: {**fact, "v": 1})
    n = len(ws.ocx_calls())
    res = hub_query(ws.client("b"), H)
    assert_ok(res, "client b, v1 fact")
    assert f"rules_ocx: {H}: resolved again (the stored fact was from an older rules_ocx)" in res.out, res.out[-2000:]
    assert resolve_calls(ws, n), "a v1 fact is a miss"
    assert lock_facts(ws)[KEY]["v"] == 2
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("c"), H), "client c")
    assert resolve_calls(ws, n) == [], "the rewritten fact hits"


@pytest.mark.parametrize(("fault", "text"), [
    ("two_roots", f"rules_ocx: '{H}': ocx package vendor reported 2 selections or roots; a package needs exactly one"),
    ("index_digest", f"rules_ocx: the tag of '{H}' moved while it was resolved; run the update again"),
], ids=["x2-two-roots", "x3-two-indexes"])  # fmt: skip
def test_vendor_shape_errors(lockrig, fault: str, text: str) -> None:
    lockrig.push("1.0", "tool v1", platforms=(P, LOCK_MUSL))
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0"), platforms=(P, LOCK_MUSL)), {H: [P, LOCK_MUSL]}, fault=fault)
    res = hub_query(ws.client("a"), H)
    assert res.rc != 0 and text in res.out, res.out[-2000:]
    if fault == "index_digest":
        assert len(resolve_calls(ws)) == 4, "the check resolves the whole declaration once more, then fails"


def test_gone_platform_manifest_names_the_update(lockrig) -> None:
    leaf = lockrig.push("1.0", "tool v1")
    index = lockrig.index_digest("1.0")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "client a")
    lockrig.delete(index, leaf[P])
    res = ws.client("b").run("fetch", f"--repo=@{SET}", lockfile="error")
    assert res.rc != 0, res.out[-2000:]
    hint = f"hint: the platform manifest MODULE.bazel.lock pins for '{H}' may be gone from the registry; run bazel run @{H}//:update"
    assert hint in res.out, res.out[-2000:]


def test_result_lines(lockrig) -> None:
    first = lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    a = ws.client("a")
    first_run = hub_query(a, H)
    assert_ok(first_run, "first resolution")
    assert "->" not in first_run.out and "unchanged" not in first_run.out, "a first resolve replaces nothing"
    same = hub_query(a, H, f"--repo_env=RULES_OCX_UPDATE={H}")
    assert_ok(same, "switch, tag unmoved")
    assert f"rules_ocx: {H}: unchanged" in same.out, same.out[-2000:]
    second = lockrig.push("1.0", "tool v2")
    moved = hub_query(a, H, f"--repo_env=RULES_OCX_UPDATE={H},{H}")
    assert_ok(moved, "switch, tag moved")
    assert f"rules_ocx: {H} {P}: {first[P]} -> {second[P]}" in moved.out, moved.out[-2000:]


def test_refresh_and_off_modes(lockrig) -> None:
    lockrig.push("1.0", "tool v1", platforms=(P, LOCK_MUSL))
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0"), platforms=(P, LOCK_MUSL)), {H: [P, LOCK_MUSL]})
    assert_ok(hub_query(ws.client("a"), H), "client a")
    lock_text = (ws.path / "MODULE.bazel.lock").read_text(encoding="utf-8")
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("refresh"), H, lockfile="refresh"), "refresh")
    assert resolve_calls(ws, n) == [], "refresh uses the stored fact"
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("off"), H, lockfile="off"), "off")
    assert len(resolve_calls(ws, n)) == 2, "off resolves once per platform"
    assert (ws.path / "MODULE.bazel.lock").read_text(encoding="utf-8") == lock_text, "off writes nothing"


def _project_ws(lockrig):
    lockrig.push("1.0", "tool v1")
    decls = (
        'ocx.project(name = "proj", groups = ["default"], ocx_lock = "//:ocx.lock", ocx_toml = "//:ocx.toml", '
        f'platforms = ["{P}"])\n' + pkg_decl("tg", lockrig.ident("1.0"))
    )
    toml = '[tools]\ntool = "@REGISTRY@/rig/tool:1.0.0"\n'
    return lockrig.workspace(decls, {"proj": [P], "tg": [P]}, toml=toml)


def test_switch_naming_a_project_does_not_resolve(lockrig) -> None:
    ws = _project_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), "proj"), "client a, both declarations")
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("b"), "proj", "--repo_env=RULES_OCX_UPDATE=proj"), "switch naming the project")
    assert resolve_calls(ws, n) == [], "an unchanged project resolves nothing"
    n = len(ws.ocx_calls())
    assert_ok(hub_query(ws.client("c"), "proj", "--repo_env=RULES_OCX_UPDATE=proj,tg"), "switch naming the tag too")
    calls = resolve_calls(ws, n)
    assert calls and not [c for c in calls if "--project" in c], "control: the tag resolves, the project does not:\n" + "\n".join(calls)


def test_switch_leaves_no_trace_in_the_lock(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    res = hub_query(ws.client("a"), H, f"--repo_env=RULES_OCX_UPDATE={H}")
    assert_ok(res, "switch run")
    assert f"rules_ocx: RULES_OCX_UPDATE={H} is set;" in res.out, res.out[-2000:]
    assert "RULES_OCX_UPDATE" not in (ws.path / "MODULE.bazel.lock").read_text(encoding="utf-8")


def test_hub_tool_finds_its_record(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    a = ws.client("a")
    assert_ok(run_hub(a, H), "the hub's tool through its launcher")
    assert tool_report(a, H) == "tool v1"


# ---- The `update` targets (ADR 0003 § The `update` targets, § Publishing, § Error texts).

HB = "lb"
E3 = "rules_ocx: @rules_ocx//:update takes declaration names only; pass ocx update arguments to @<name>//:update"
E7 = "rules_ocx: bazel mod deps --lockfile_mode=update failed (exit {n}); no fact moved; the ocx.lock and snapshot files written above stay"


def _pin_of(ws, hub: str, platform: str = P) -> str:
    return lock_facts(ws)[f"package|{hub}"]["pins"][platform]


def _two_tags(lockrig):
    """Two tag declarations over two repositories, both resolved once; returns (workspace, second repository)."""
    repo_b = lockrig.repo + "-b"
    lockrig.push("1.0", "a v1")
    lockrig.push("1.0", "b v1", repo=repo_b)
    decls = pkg_decl(H, lockrig.ident("1.0")) + pkg_decl(HB, lockrig.ident("1.0", repo_b))
    ws = lockrig.workspace(decls, {H: [P], HB: [P]})
    assert_ok(hub_query(ws.client("a"), H), "first resolution of both declarations")
    return ws, repo_b


def _project_toml(lockrig, repo: str | None = None) -> str:
    return f'[tools]\ntool = "@REGISTRY@/{repo or lockrig.repo}:1.0"\n'


def _project_decl(hub: str = "proj") -> str:
    return (f'ocx.project(name = "{hub}", groups = ["default"], ocx_lock = "//:ocx.lock", ocx_toml = "//:ocx.toml", '
            f'platforms = ["{P}"])\n')  # fmt: skip


def _project_ws(lockrig, *, name: str = ""):
    """Only a project declaration, over this test's repository, resolved once."""
    lockrig.push("1.0", "tool v1")
    ws = lockrig.workspace(_project_decl(), {"proj": [P]}, toml=_project_toml(lockrig), name=name)
    assert_ok(hub_query(ws.client("a"), "proj"), "first resolution of the project")
    return ws


def _project_and_tag(lockrig, *, dir_name: str | None = None):
    """A project over a second repository and a tag over the first, both resolved once; returns (workspace, project repository)."""
    repo_b = lockrig.repo + "-b"
    lockrig.push("1.0", "a v1")
    leaf_b = lockrig.push("1.0", "b v1", repo=repo_b)
    decls = _project_decl() + pkg_decl("tg", lockrig.ident("1.0"))
    ws = lockrig.workspace(decls, {"proj": [P], "tg": [P]}, toml=_project_toml(lockrig, repo_b), dir_name=dir_name)
    assert_ok(hub_query(ws.client("a"), "proj"), "first resolution of both declarations")
    return ws, repo_b, leaf_b


def _settle(client, target: str) -> None:
    """Builds the update program once, so that `MODULE.bazel.lock` is what this client writes before a byte comparison."""
    assert_ok(client.run("build", target, "--spawn_strategy=local", lockfile="update"), f"build {target}")


def test_hub_update_moves_only_that_declaration(lockrig) -> None:
    ws, repo_b = _two_tags(lockrig)
    old = {h: _pin_of(ws, h) for h in (H, HB)}
    new_a = lockrig.push("1.0", "a v2")
    new_b = lockrig.push("1.0", "b v2", repo=repo_b)
    res = run_update(update_client(ws, "u"), f"@{H}//:update")
    assert_ok(res, f"bazel run @{H}//:update")
    assert _pin_of(ws, H) == new_a[P] != old[H]
    assert _pin_of(ws, HB) == old[HB] != new_b[P], "the other declaration's fact must stay"
    assert f"rules_ocx: {H} {P}: {old[H]} -> {new_a[P]}" in res.out, res.out[-2000:]


def test_update_writes_a_missing_fact_of_another_hub(lockrig) -> None:
    ws, repo_b = _two_tags(lockrig)
    drop_fact(ws, f"package|{HB}")
    new_a = lockrig.push("1.0", "a v2")
    new_b = lockrig.push("1.0", "b v2", repo=repo_b)
    # `off` makes the outer run write nothing: every fact that reaches the lock comes from the nested call.
    assert_ok(run_update(update_client(ws, "u"), f"@{H}//:update", lockfile="off"), f"bazel run @{H}//:update")
    assert _pin_of(ws, H) == new_a[P]
    assert _pin_of(ws, HB) == new_b[P], "a fact that misses is written by the nested call, whatever the switch names"


def test_rules_ocx_update_all_and_named(lockrig) -> None:
    ws, repo_b = _two_tags(lockrig)
    u = update_client(ws, "u")
    second = (lockrig.push("1.0", "a v2"), lockrig.push("1.0", "b v2", repo=repo_b))
    assert_ok(run_update(u, "@rules_ocx//:update"), "update of every declaration")
    assert (_pin_of(ws, H), _pin_of(ws, HB)) == (second[0][P], second[1][P])
    third = (lockrig.push("1.0", "a v3"), lockrig.push("1.0", "b v3", repo=repo_b))
    assert_ok(run_update(u, "@rules_ocx//:update", HB), f"update of {HB} only")
    assert _pin_of(ws, HB) == third[1][P]
    assert _pin_of(ws, H) == second[0][P] != third[0][P], "a declaration that is not named stays"


def test_project_update_writes_only_ocx_lock(lockrig) -> None:
    ws = _project_ws(lockrig)
    u = update_client(ws, "u")
    _settle(u, "@proj//:update")
    before = ws_bytes(ws)
    lockrig.push("1.0", "tool v2")
    assert_ok(run_update(u, "@proj//:update"), "bazel run @proj//:update")
    after = ws_bytes(ws)
    changed = {k for k in before.keys() | after.keys() if before.get(k) != after.get(k)}
    assert changed == {"ocx.lock", "MODULE.bazel.lock"}, changed
    assert after["ocx.toml"] == before["ocx.toml"]
    assert not list(ws.path.rglob(".ocx")), "the render of `ocx update` belongs in the scratch copy"


def test_update_selection_errors(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    pinned = f"{lockrig.ident('1.0')}@{lockrig.index_digest('1.0')}"
    ws = lockrig.workspace(pkg_decl(H, lockrig.ident("1.0")) + pkg_decl("lp", pinned), {H: [P], "lp": [P]})
    assert_ok(hub_query(ws.client("a"), H), "first resolution")
    u = update_client(ws, "u")
    _settle(u, "@rules_ocx//:update")
    lock_before, n = ws_bytes(ws), len(ws.ocx_calls())
    cases = [  # the order of the checks: E3, then E1; E2 for a package hub with arguments
        ("@rules_ocx//:update", ["--frozen"], E3),
        ("@rules_ocx//:update", ["nosuch", "--frozen"], E3),
        ("@rules_ocx//:update", ["nosuch"], f"rules_ocx: no ocx declaration is named 'nosuch'; known: {H}, lp"),
        (f"@{H}//:update", ["-g", "x"], f"rules_ocx: '{H}' is an ocx.package declaration; its update takes no arguments"),
    ]
    for target, args, text in cases:
        res = run_update(u, target, *args)
        assert res.rc == 64 and text in res.out, (target, args, res.rc, res.out[-1500:])
    res = run_update(u, "@lp//:update")
    assert_ok(res, "a pinned declaration is a notice")
    assert "rules_ocx: lp: pinned by digest in MODULE.bazel; edit the identifier to move it" in res.out, res.out[-1500:]
    assert ocx_work(ws, n) == [], "a refused selection makes no ocx call"
    assert ws_bytes(ws) == lock_before
    # E9 comes first: the program started by hand, outside `bazel run`, names no workspace.
    script = u.external("ocx_update") / "update.sh"
    proc = subprocess.run(["sh", str(script), "--frozen", "nosuch"], env={"PATH": "/usr/bin:/bin"}, capture_output=True,
                          text=True, timeout=60)  # fmt: skip
    assert proc.returncode == 64 and "rules_ocx: run this target with bazel run" in proc.stderr, proc.stderr


def _symlink_ocx_lock(ws, to) -> bytes:
    """Replaces the workspace `ocx.lock` by a symlink to `to`, which then holds its text; returns that text."""
    text = (ws.path / "ocx.lock").read_bytes()
    (ws.path / "ocx.lock").unlink()
    to.parent.mkdir(parents=True, exist_ok=True)
    to.write_bytes(text)
    (ws.path / "ocx.lock").symlink_to(to)
    return text


def test_update_refusals(lockrig) -> None:
    for case in ("e12", "e14", "e8"):
        ws = _project_ws(lockrig, name=f"-{case}")
        lock = ws.path / "ocx.lock"
        if case == "e8":
            u = update_client(ws, "u", bazel=str(ws.path.parent / "no-such-bazel"))
            want, text = "rules_ocx: no bazel found; put bazel on PATH or set RULES_OCX_BAZEL", lock.read_bytes()
        else:
            u = update_client(ws, "u")
            outside = case == "e12"
            target = ws.path.parent / f"{ws.test_id}-outside" / "ocx.lock" if outside else ws.path / "real.lock"
            want = ("resolves outside the workspace; refusing to write it" if outside
                    else "is a symlink; replace it with the file it points to before updating")  # fmt: skip
            text = _symlink_ocx_lock(ws, target)
        lockrig.push("1.0", f"tool {case}")  # the lock has something to move
        _settle(u, "@proj//:update")
        before, n = ws_bytes(ws), len(ws.ocx_calls())
        res = run_update(u, "@proj//:update")
        assert res.rc == 78 and want in res.out, (case, res.rc, res.out[-1500:])
        if case != "e8":
            assert f"rules_ocx: proj: {ws.path}/ocx.lock " in res.out, res.out[-1500:]
            assert lock.is_symlink() and target.read_bytes() == text, case
        assert lock.read_bytes() == text and ocx_work(ws, n) == [] and ws_bytes(ws) == before, case


def test_update_skips_a_dependency_snapshot(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    test_id = lockrig.id + "-dep"
    ws_dir = RUN / "ws" / test_id
    shutil.rmtree(ws_dir, ignore_errors=True)
    (ws_dir / "dep").mkdir(parents=True)
    (ws_dir / "MODULE.bazel").write_text(
        'module(name = "e5_root")\nbazel_dep(name = "dep", version = "0.0.0")\n'
        'local_path_override(module_name = "dep", path = "dep")\n'
        f'bazel_dep(name = "rules_ocx", version = "0.0.0")\nlocal_path_override(module_name = "rules_ocx", path = "{ROOT}")\n'
    )  # fmt: skip
    (ws_dir / "BUILD.bazel").write_text("")
    (ws_dir / ".bazelversion").write_text((ROOT / ".bazelversion").read_text())
    (ws_dir / "dep" / "MODULE.bazel").write_text(
        'module(name = "dep", version = "0.0.0")\nbazel_dep(name = "rules_ocx", version = "0.0.0")\n'
        'ocx = use_extension("@rules_ocx//ocx:extensions.bzl", "ocx")\n'
        + pkg_decl("dep_tool", lockrig.ident("1.0"), index='"//:index"') + 'use_repo(ocx, "dep_tool")\n'
    )  # fmt: skip
    (ws_dir / "dep" / "BUILD.bazel").write_text('exports_files(["index"])\n')
    ocx(ws_dir.parent / f"{test_id}-indexhome", "--index", str(ws_dir / "dep" / "index"), "index", "update", lockrig.ident("1.0"))
    counter = ws_dir / ".ocx-calls.log"
    ws = Workspace(ws_dir, test_id, counter, _counting_wrapper(ws_dir.parent / f"{test_id}-ocx", counter))
    lockrig.workspaces.append(ws)
    assert_ok(hub_query(ws.client("a"), "dep_tool"), "first resolution")
    snapshot, n = tree_bytes(ws_dir / "dep" / "index"), len(ws.ocx_calls())
    res = run_update(update_client(ws, "u"), "@rules_ocx//:update")
    assert_ok(res, "bazel run @rules_ocx//:update")
    e5 = "rules_ocx: dep_tool: its index snapshot is not in this workspace; update it in the module that holds it"
    assert e5 in res.out, res.out[-1500:]
    assert tree_bytes(ws_dir / "dep" / "index") == snapshot
    assert not (ws_dir / "index").exists(), "nothing is written into this workspace"
    assert ocx_work(ws, n) == []


def test_update_continues_after_an_ocx_failure(lockrig) -> None:
    ws, repo_b, leaf_b = _project_and_tag(lockrig)
    new_a = lockrig.push("1.0", "a v2")
    # The project's tool is gone from the registry: `ocx update` for it fails, the tag declaration still moves.
    lockrig.delete(lockrig.index_digest("1.0", repo_b), leaf_b[P], repo=repo_b)
    lock_before = (ws.path / "ocx.lock").read_bytes()
    res = run_update(update_client(ws, "u"), "@rules_ocx//:update")
    failed = re.search(r"rules_ocx: proj: ocx .* failed \(exit (\d+)\)", res.out)
    assert failed, res.out[-2000:]
    assert res.rc == int(failed[1]) != 0, "the exit code is the failing ocx run's"
    assert _pin_of(ws, "tg") == new_a[P], "the loop went on: the tag's fact moved"
    assert (ws.path / "ocx.lock").read_bytes() == lock_before


def test_update_reports_a_failed_nested_call(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "first resolution")
    first = _pin(ws)
    lockrig.push("1.0", "tool v2")
    res = run_update(update_client(ws, "u", fail_mod=2), f"@{H}//:update")
    assert res.rc == 2 and E7.format(n=2) in res.out, (res.rc, res.out[-2000:])
    assert _pin(ws) == first, "no fact moved"


def test_update_refuses_a_locked_output_base(lockrig) -> None:
    lockrig.push("1.0", "tool v1")
    ws = _tag_ws(lockrig)
    assert_ok(hub_query(ws.client("a"), H), "first resolution")
    (ws.path / "BUILD.bazel").write_text(
        (ws.path / "BUILD.bazel").read_text() + 'genrule(name = "hold", outs = ["hold.txt"], cmd = "sleep 900; touch $@")\n'
    )  # fmt: skip
    holder = ws.client("holder")
    u = update_client(ws, "u", nested=holder)
    _settle(u, f"@{H}//:update")
    lockrig.push("1.0", "tool v2")
    before, n = ws_bytes(ws), len(ws.ocx_calls())
    # The startup option is the one the program passes, so the holder's server and the program's calls agree.
    hold = holder.start("build", "//:hold", "--spawn_strategy=local", startup=("--noblock_for_lock",), lockfile="update")
    try:
        probe = [*holder.startup("--noblock_for_lock"), "info", "output_base"]
        deadline = time.monotonic() + 300
        while True:
            assert hold.poll() is None and time.monotonic() < deadline, "the holder never took the output-base lock"
            if subprocess.run(probe, cwd=ws.path, env=holder.env(), capture_output=True, timeout=120).returncode == 9:
                break
            time.sleep(0.5)
        res = run_update(u, f"@{H}//:update", timeout=240)  # without --noblock_for_lock this waits for the lock
    finally:
        hold.terminate()
        try:
            hold.wait(timeout=60)
        except subprocess.TimeoutExpired:
            hold.kill()
    e11 = "rules_ocx: the Bazel output base is locked (another command, or bazel --batch run); run the update again without --batch"
    assert res.rc == 75 and e11 in res.out, (res.rc, res.out[-2000:])
    assert ws_bytes(ws) == before and ocx_work(ws, n) == []


def test_update_in_a_workspace_path_with_a_space(lockrig) -> None:
    ws, repo_b, _ = _project_and_tag(lockrig, dir_name="a workspace")
    assert " " in str(ws.path)
    old_lock = (ws.path / "ocx.lock").read_bytes()
    new_a = lockrig.push("1.0", "a v2")
    lockrig.push("1.0", "b v2", repo=repo_b)
    res = run_update(update_client(ws, "u"), "@rules_ocx//:update")
    assert_ok(res, "bazel run @rules_ocx//:update in a path with a space")
    assert _pin_of(ws, "tg") == new_a[P]
    assert (ws.path / "ocx.lock").read_bytes() != old_lock
