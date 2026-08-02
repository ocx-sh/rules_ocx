#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Specification tests for the supply-chain guards in bump_ocx.py.

Run: python3 scripts/bump_ocx_test.py

setup.ocx.sh is the one input this repo cannot verify out of band: it names
the versions, the artifacts and the sha256 that @ocx_tool will execute. These
tests pin the four guards that keep that server from choosing what we pin —
F1 (per-row: stable channel, hex sha256, a url that really resolves to the
release host, a mapped archive extension — on the pinned version and on every
row a refresh adds), F1b (direction), F2 (additions only, no duplicate
(version, target)), F3 (no write before the guards run). No network, no
writes; every fixture is inline.
"""

import contextlib
import hashlib
import io
import json
import pathlib
import shutil
import sys
import tempfile
import urllib.request

import bump_ocx

# The 8 targets dist:check requires a pinned version to cover.
TARGETS = (
    "aarch64-apple-darwin",
    "aarch64-pc-windows-msvc",
    "aarch64-unknown-linux-gnu",
    "aarch64-unknown-linux-musl",
    "x86_64-apple-darwin",
    "x86_64-pc-windows-msvc",
    "x86_64-unknown-linux-gnu",
    "x86_64-unknown-linux-musl",
)

# Every field of a shared row that a rewrite could move (F2). The key is
# (version, target), so those two are excluded.
ROW_FIELDS = ("sha256", "url", "filename", "tag", "channel")


def row(version, target, channel="stable"):
    """One dist.json release row, shaped like the committed snapshot."""
    filename = f"ocx-{target}.tar.gz"
    return {
        "version": version,
        "channel": channel,
        "tag": f"v{version}",
        "target": target,
        "filename": filename,
        # Realistic-looking and distinct per row, so a tampered value differs.
        "sha256": hashlib.sha256(f"{version}/{target}".encode()).hexdigest(),
        "url": f"https://github.com/ocx-sh/ocx/releases/download/v{version}/{filename}",
    }


def manifest(*versions, channel="stable", latest_channel="stable", latest_next=None):
    """A dist.json-shaped manifest carrying all 8 targets per version."""
    return {
        "schema": 1,
        "latest": {"version": versions[-1], "channel": latest_channel},
        "latest_next": latest_next,
        "releases": [row(v, t, channel) for v in versions for t in TARGETS],
    }


def dies(fn, *args, why="this input"):
    """Calls fn(*args), asserts it die()d, returns the exit message."""
    try:
        fn(*args)
    except SystemExit as e:
        return str(e.code)
    raise AssertionError(f"{fn.__name__} accepted {why}; expected die()")


@contextlib.contextmanager
def served(body):
    """Serves `body` to the next urlopen(); keeps the tests off the network."""
    real = urllib.request.urlopen
    urllib.request.urlopen = lambda req, timeout=None: io.BytesIO(body)
    try:
        yield
    finally:
        urllib.request.urlopen = real


@contextlib.contextmanager
def sandbox(pin, committed, argv, ci_pin=None):
    """Runs main() against a throwaway repo: the committed snapshot, the pin
    and the workflows all live in a tmpdir, so a bump writes nothing real.
    `ci_pin` defaults to `pin`; pass a different one when the test has to tell
    "left alone" apart from "rewritten to the value it already had"."""
    tmp = pathlib.Path(tempfile.mkdtemp())
    (tmp / "dist.json").write_text(json.dumps(committed))
    (tmp / "versions.bzl").write_text(f'DEFAULT_OCX_VERSION = "{pin}"\n')
    (tmp / "workflows").mkdir()
    (tmp / "workflows" / "ci.yml").write_text(
        f'      - uses: ocx-sh/setup-ocx@v1\n        with:\n          version: "{ci_pin or pin}"\n'
    )
    saved = (bump_ocx.DIST, bump_ocx.VERSIONS, bump_ocx.WORKFLOWS, sys.argv)
    bump_ocx.DIST = tmp / "dist.json"
    bump_ocx.VERSIONS = tmp / "versions.bzl"
    bump_ocx.WORKFLOWS = tmp / "workflows"
    sys.argv = ["bump_ocx.py", *argv]
    try:
        with contextlib.redirect_stdout(io.StringIO()):  # main()'s report is not the assertion
            yield tmp
    finally:
        bump_ocx.DIST, bump_ocx.VERSIONS, bump_ocx.WORKFLOWS, sys.argv = saved
        shutil.rmtree(tmp, ignore_errors=True)


@contextlib.contextmanager
def recording(*names):
    """Records which of the named module functions actually get called."""
    calls = []
    saved = {n: getattr(bump_ocx, n) for n in names}

    def spy(name, fn):
        def wrapped(*args, **kw):
            calls.append(name)
            return fn(*args, **kw)

        return wrapped

    for n, fn in saved.items():
        setattr(bump_ocx, n, spy(n, fn))
    try:
        yield calls
    finally:
        for n, fn in saved.items():
            setattr(bump_ocx, n, fn)


@contextlib.contextmanager
def snapshot_untouched():
    """Fails if the body of the block writes bump_ocx.DIST.

    DIST is repointed at a copy: a write-first regression is exactly what this
    guards, so it must not be able to destroy the real 184-row snapshot while
    proving the point. The assertions live in `finally` — a body that raises
    still has to answer for the file it left behind, otherwise the regression
    surfaces as some unrelated error instead of "was rewritten".
    """
    tmp = pathlib.Path(tempfile.mkdtemp())
    dist = tmp / "dist.json"
    dist.write_bytes(bump_ocx.DIST.read_bytes())
    before, mtime = dist.read_bytes(), dist.stat().st_mtime_ns
    saved, bump_ocx.DIST = bump_ocx.DIST, dist
    try:
        try:
            yield
        finally:
            assert dist.read_bytes() == before, f"{dist} was rewritten"
            assert dist.stat().st_mtime_ns == mtime, f"{dist} was touched"
    finally:
        bump_ocx.DIST = saved
        shutil.rmtree(tmp, ignore_errors=True)


# --- F1: the manifest server must not choose the channel we pin -------------


def test_f1_latest_pointer_must_be_stable():
    """F1(a): auto-select trusts manifest.latest — a prerelease pointer there
    would silently move the pin onto a beta."""
    bump_ocx.assert_latest_stable(manifest("0.5.2"))
    for ch in ("beta", "rc", "nightly", "next"):
        dies(bump_ocx.assert_latest_stable, manifest("0.5.3", latest_channel=ch), why=f"latest.channel={ch}")


def test_f1_latest_pointer_without_a_channel_is_refused():
    """F1(a), fail-closed: an absent channel is not evidence of stable."""
    m = manifest("0.5.2")
    del m["latest"]["channel"]
    dies(bump_ocx.assert_latest_stable, m, why="a latest pointer with no channel")


def test_f1_latest_next_does_not_block_a_stable_latest():
    """F1(a): only `latest` feeds auto-select — a prerelease parked in
    latest_next is normal upstream traffic. Refusing it would be an
    over-refusal; *following* it would be the vulnerability, so both halves
    are asserted."""
    m = manifest("0.5.1", "0.5.2", latest_next={"version": "0.6.0", "channel": "beta"})
    bump_ocx.assert_latest_stable(m)
    assert bump_ocx.newest_stable(m) == "0.5.2", "auto-select must ignore latest_next"


def test_f1_an_absent_latest_pointer_falls_back_instead_of_dying():
    """F1(a): with no pointer there is nothing to distrust — newest_stable()
    filters `releases` by channel instead, which is the safer path. Making
    this branch die() would break a manifest that simply has no `latest`."""
    m = manifest("0.5.1", "0.5.2")
    del m["latest"]
    bump_ocx.assert_latest_stable(m)
    assert bump_ocx.newest_stable(m) == "0.5.2"


def test_f1_validate_refuses_a_non_stable_row():
    """F1(b): the per-row channel check runs on auto-select, on --version and
    on --check, so it also catches a beta the operator named by hand."""
    good = manifest("0.5.2")
    assert len(bump_ocx.validate(good, "0.5.2")) == len(TARGETS)

    one_beta = manifest("0.5.2")
    one_beta["releases"][3]["channel"] = "beta"
    dies(bump_ocx.validate, one_beta, "0.5.2", why="a release with one beta row")

    all_beta = manifest("0.6.0", channel="beta")
    dies(bump_ocx.validate, all_beta, "0.6.0", why="a wholly beta release")


def test_f1_validate_refuses_a_sha256_that_is_not_lowercase_hex():
    """F1(b): a length check is not a hex check — "z"*64 passes it, and a
    64-element list passes it too and then reaches download_and_extract as a
    non-string."""
    for bad in ("z" * 64, "A" * 64, ["0"] * 64, None, "abc"):
        m = manifest("0.5.2")
        m["releases"][1]["sha256"] = bad
        dies(bump_ocx.validate, m, "0.5.2", why=f"sha256={bad!r}")


def test_f1_validate_refuses_an_artifact_url_off_the_release_host():
    """F1(b): artifact_url() in ocx/private/manifest.bzl returns row["url"]
    verbatim, so a fabricated row names both the host and the hash. Mirrors go
    through OCX_INSTALL_MIRROR_URL, which rewrites at download time.

    startswith() is not a host check. github.com normalises dot segments
    server-side, so the traversal below matches the artifact prefix and still
    returns another repository's release asset (verified live: it 302s to the
    same asset the direct url does, with and without curl --path-as-is, and
    through urllib) — anyone can create a repo and a release, so it reaches
    attacker-chosen bytes under the sha256 from the same row. The separator
    characters go with it: a prefix match also waves through CRLF, tabs, NUL,
    a query string and a fragment.
    """
    good = f"{bump_ocx.ARTIFACT_PREFIX}v0.5.2/ocx-x86_64-unknown-linux-gnu.tar.gz"
    assert len(bump_ocx.validate(manifest("0.5.2"), "0.5.2")) == len(TARGETS), "the real URL shape must pass"
    for bad in (
        "https://evil.example/v0.5.2/ocx.tar.gz",
        "https://github.com.evil.example/ocx-sh/ocx/releases/download/v0.5.2/ocx.tar.gz",
        "https://github.com@evil.example/ocx-sh/ocx/releases/download/v0.5.2/ocx.tar.gz",
        "https://GITHUB.COM/ocx-sh/ocx/releases/download/v0.5.2/ocx.tar.gz",
        "http://github.com/ocx-sh/ocx/releases/download/v0.5.2/ocx.tar.gz",
        # The PoC: 200 OK, another repository's asset, prefix intact.
        f"{bump_ocx.ARTIFACT_PREFIX}../../../../attacker/evil/releases/download/v1/ocx.tar.gz",
        f"{bump_ocx.ARTIFACT_PREFIX}%2e%2e/%2e%2e/%2e%2e/%2e%2e/attacker/evil/releases/download/v1/ocx.tar.gz",
        f"{good}\r\nX-Injected: 1",
        f"{good}\tocx.tar.gz",
        f"{good}\0",
        f"{good}?redirect=https://evil.example/ocx.tar.gz",
        f"{good}#https://evil.example",
        None,
        123,
        [good],
    ):
        m = manifest("0.5.2")
        m["releases"][2]["url"] = bad
        dies(bump_ocx.validate, m, "0.5.2", why=f"url={bad!r}")


def test_f1_validate_refuses_a_filename_it_cannot_type():
    """F1(b): archive_type() falls back to tar.xz, so an unmapped extension
    fails at extraction rather than at download — and a row with no filename
    at all has to die() with a message, not KeyError out of the guard."""
    for bad in ("ocx.tar.bz2", "ocx", None, 7, ["ocx.tar.gz"]):
        m = manifest("0.5.2")
        m["releases"][4]["filename"] = bad
        dies(bump_ocx.validate, m, "0.5.2", why=f"filename={bad!r}")

    missing = manifest("0.5.2")
    del missing["releases"][4]["filename"]
    dies(bump_ocx.validate, missing, "0.5.2", why="a row with no filename at all")


# --- F1b: the pin only ever moves forward -----------------------------------


def test_f1b_pin_only_moves_forward():
    """F1b: comparison is by version_key(), not string order — 0.5.10 is
    newer than 0.5.9, and a lexicographic guard gets both cases wrong."""
    bump_ocx.assert_forward("0.5.2", "0.5.3")
    bump_ocx.assert_forward("0.5.9", "0.5.10")
    bump_ocx.assert_forward("0.6.0", "0.10.0")

    dies(bump_ocx.assert_forward, "0.5.2", "0.5.2", why="a no-op bump")
    dies(bump_ocx.assert_forward, "0.5.3", "0.5.2", why="a rollback")
    dies(bump_ocx.assert_forward, "0.5.10", "0.5.9", why="a rollback string compare would accept")


# --- F2: a refresh may only add rows ----------------------------------------


def test_f2_additions_are_the_only_permitted_change():
    """F2: no change, a new version, and a new target for a known version are
    all legitimate — the guard must not over-refuse a normal upstream day."""
    base = manifest("0.5.1", "0.5.2")
    bump_ocx.assert_additions_only(base, base)
    bump_ocx.assert_additions_only(base, manifest("0.5.1", "0.5.2", "0.5.3"))

    new_target = manifest("0.5.1", "0.5.2")
    new_target["releases"].append(row("0.5.2", "riscv64gc-unknown-linux-gnu"))
    bump_ocx.assert_additions_only(base, new_target)


def test_f2_rewritten_row_is_refused():
    """F2: sha256 is the value download_and_extract enforces against, but any
    field moving under an already-committed (version, target) is a rewrite."""
    base = manifest("0.5.1", "0.5.2")
    for field in ROW_FIELDS:
        tampered = manifest("0.5.1", "0.5.2")
        tampered["releases"][0][field] = "0" * 64 if field == "sha256" else "rewritten"
        assert tampered["releases"][0][field] != base["releases"][0][field]
        dies(bump_ocx.assert_additions_only, base, tampered, why=f"a rewritten {field}")


def test_f2_dropped_row_is_refused_and_named():
    """F2: a version disappearing upstream must not silently vanish from our
    snapshot, and the message has to name the rows that went, not just the
    versions — one target of a live release can drop on its own."""
    base = manifest("0.5.1", "0.5.2")
    msg = dies(bump_ocx.assert_additions_only, base, manifest("0.5.2"), why="a dropped 0.5.1")
    assert "0.5.1" in msg, f"die() message must name the dropped version; got: {msg}"

    partial = manifest("0.5.1", "0.5.2")
    gone = partial["releases"].pop(3)  # one target of 0.5.1, the rest still there
    msg = dies(bump_ocx.assert_additions_only, base, partial, why="one dropped target")
    assert f"{gone['version']} {gone['target']}" in msg, f"must name the dropped row; got: {msg}"


def test_f2_a_duplicate_row_is_refused_on_both_sides():
    """F2, the bypass: indexing by (version, target) keeps the LAST row per
    key, but select_release() in ocx/private/manifest.bzl returns the FIRST.
    Serve the poisoned row first and the honest row last and a last-wins index
    compares the honest one, passes, and commits both — after which
    @ocx_tool resolves the attacker's host and sha256. .gitattributes marks
    dist/dist.json linguist-generated, so no reviewer sees the extra row.
    """
    base = manifest("0.5.1", "0.5.2")
    honest = base["releases"][0]
    poison = dict(honest, sha256="d" * 64, url="https://evil.example/v0.5.1/ocx.tar.gz")

    incoming = manifest("0.5.1", "0.5.2")
    incoming["releases"].insert(0, poison)  # poison first, honest still present
    assert incoming["releases"][1] == honest, "the honest row must still be there to shadow"
    msg = dies(bump_ocx.assert_additions_only, base, incoming, why="a poison-first duplicate row")
    assert "twice" in msg, f"die() must name the duplication; got: {msg}"

    # Committed side too: a duplicate that ever landed compares equal to
    # itself on every later refresh, so it would stay invisible forever.
    dies(bump_ocx.assert_additions_only, incoming, base, why="a duplicate already committed")


def test_f2_a_new_upstream_column_is_refused():
    """F2: rows are compared over the union of their fields, so a column
    appearing upstream trips the guard — the likeliest real trigger, and
    deliberate: a new column changes what an already-committed row means."""
    base = manifest("0.5.1", "0.5.2")
    widened = manifest("0.5.1", "0.5.2")
    for r in widened["releases"]:
        r["signature"] = "MEUCIQ..."
    msg = dies(bump_ocx.assert_additions_only, base, widened, why="a new column on every row")
    assert "signature" in msg, f"die() must name the new field; got: {msg}"


def test_f2_added_rows_face_the_same_per_row_bar():
    """F2 x F1(b): validate() only ever inspects the rows of the version being
    pinned, but the *whole* manifest is written. ocx.download(version = ...)
    lets a consumer select any row in it, and no Starlark checks the host or
    the channel — so a refresh of 0.5.3 must not be able to smuggle in rows
    nobody validated. The count check stays scoped to the pinned version
    (upstream mid-publish is not an attack); everything else is not.
    """
    base = manifest("0.5.1", "0.5.2")
    bump_ocx.assert_additions_only(base, manifest("0.5.1", "0.5.2", "0.5.3"))  # a clean addition still passes

    for field, bad in (
        ("channel", "nightly"),
        ("sha256", "z" * 64),
        ("url", "https://evil.example/v0.5.3/ocx.tar.gz"),
        ("url", f"{bump_ocx.ARTIFACT_PREFIX}../../../../attacker/evil/releases/download/v1/ocx.tar.gz"),
        ("filename", "ocx.tar.bz2"),
    ):
        incoming = manifest("0.5.1", "0.5.2", "0.5.3")
        for r in incoming["releases"]:
            if r["version"] == "0.5.3":
                r[field] = bad
        msg = dies(bump_ocx.assert_additions_only, base, incoming, why=f"an added row with {field}={bad!r}")
        assert "0.5.3" in msg, f"die() must name the offending row; got: {msg}"


def test_f2_a_malformed_manifest_dies_instead_of_tracebacking():
    """F2: setup.ocx.sh serving something only manifest-shaped-ish is a
    failure the operator has to act on, so it exits with a message rather
    than a KeyError/AttributeError out of the guard's internals."""
    base = manifest("0.5.2")
    broken = (
        {"schema": 1},  # no releases at all
        {"releases": {}},  # an object where the list belongs
        {"releases": [{"version": "0.5.2"}]},  # a row with no target
        {"releases": [], "latest": "0.5.2"},  # latest as a bare string
    )
    for m in broken:
        dies(bump_ocx.assert_additions_only, base, m, why=f"incoming {m!r}")
        dies(bump_ocx.assert_additions_only, m, base, why=f"committed {m!r}")


# --- F3: nothing is written before the guards have run ----------------------


def test_f3_fetch_snapshot_parses_without_writing():
    """F3: fetch returns (body, manifest) for the caller to validate; the
    write happens last, after every guard passes."""
    body = json.dumps(manifest("0.5.2")).encode()
    with snapshot_untouched(), served(body):
        got_body, got_manifest = bump_ocx.fetch_snapshot()
    assert got_body == body, "fetch_snapshot must return the raw bytes to write"
    assert got_manifest["latest"]["version"] == "0.5.2"


def test_f3_unparseable_response_leaves_the_snapshot_intact():
    """F3: the failure that most wants a write-first implementation — an
    error page served in place of the manifest must leave disk untouched."""
    with snapshot_untouched(), served(b"<html>503 Service Unavailable</html>"):
        dies(bump_ocx.fetch_snapshot, why="an HTML error page")


# --- wiring: a guard that main() never calls protects nothing ---------------

GUARDS = ("assert_latest_stable", "assert_forward", "assert_additions_only", "validate")


def test_wiring_every_guard_runs_on_the_auto_select_path():
    """F1/F1b/F2: the default `task dist:update`-style run is the path the
    scheduled update-dist.yml takes, so every guard has to fire on it."""
    committed = manifest("0.5.1", "0.5.2")
    with sandbox("0.5.2", committed, argv=[]), served(json.dumps(manifest("0.5.1", "0.5.2", "0.5.3")).encode()):
        with recording(*GUARDS) as calls:
            bump_ocx.main()
    assert set(calls) == set(GUARDS), f"guards not called by main(): {sorted(set(GUARDS) - set(calls))}"


def test_wiring_explicit_version_skips_auto_select_but_keeps_the_row_guards():
    """--version is the operator choosing the version by hand, so both guards
    that only exist to police the *automatic* choice are off: the forward-only
    check and the `latest` channel check. What must stay on is everything that
    inspects the rows themselves — per-row validate() and additions-only."""
    committed = manifest("0.5.1", "0.5.2")
    with sandbox("0.5.2", committed, argv=["--version", "0.5.1"]), served(json.dumps(committed).encode()):
        with recording(*GUARDS) as calls:
            bump_ocx.main()
    assert "assert_forward" not in calls, "--version must bypass the forward guard"
    assert "assert_latest_stable" not in calls, "--version does not consult the latest pointer"
    assert {"validate", "assert_additions_only"} <= set(calls), f"guards skipped: {calls}"


def test_wiring_check_path_validates_the_committed_snapshot():
    """F1(b): --check is offline and writes nothing, but it is where CI notices
    that a committed row has drifted off the stable channel — or that a
    duplicate got into the file by some route other than a refresh."""
    tainted = manifest("0.5.2")
    tainted["releases"][0]["channel"] = "nightly"
    with sandbox("0.5.2", tainted, argv=["--check"]):
        dies(bump_ocx.main, why="a committed nightly row under --check")

    dup = manifest("0.5.2")
    dup["releases"].insert(0, dict(dup["releases"][0], sha256="d" * 64))
    with sandbox("0.5.2", dup, argv=["--check"]):
        msg = dies(bump_ocx.main, why="a duplicate row hand-landed in the committed snapshot")
    assert "twice" in msg, f"--check must name the duplication; got: {msg}"


def test_wiring_check_on_an_unreadable_snapshot_dies_instead_of_tracebacking():
    """The module docstring promises die(); a truncated or half-merged
    dist/dist.json is a plausible way to arrive here, and a JSONDecodeError
    traceback gives the operator nothing to do about it."""
    with sandbox("0.5.2", manifest("0.5.2"), argv=["--check"]) as tmp:
        (tmp / "dist.json").write_text('{"releases": [')
        msg = dies(bump_ocx.main, why="a truncated committed snapshot")
    assert "git checkout" in msg, f"must name the way back to a good file; got: {msg}"


def test_wiring_snapshot_only_writes_the_snapshot_and_leaves_the_pin():
    """F3: the write lands after the guards, and `task dist:update` relies on
    --snapshot-only being a refresh rather than a silent bump — of the pin or
    of the CI pins, which are what CI dogfoods.

    The pin, the CI pin and the incoming latest are three different versions
    deliberately: with the CI pin equal to the pin, --snapshot-only writing the
    CI pins anyway would rewrite "0.5.2" as "0.5.2" and this test would pass
    over the regression. Incoming 0.5.3 is mid-publish (4 of 8 targets) for the
    same reason — it is what a refresh legitimately meets on a release day, and
    it is only tolerable because --snapshot-only validates the version that is
    *pinned*, not the newest one it happens to fetch.
    """
    committed = manifest("0.5.1", "0.5.2")
    mid_publish = manifest("0.5.1", "0.5.2", "0.5.3")
    mid_publish["releases"] = [
        r for r in mid_publish["releases"] if r["version"] != "0.5.3" or r["target"] in TARGETS[:4]
    ]
    incoming = json.dumps(mid_publish).encode()
    with sandbox("0.5.2", committed, argv=["--snapshot-only"], ci_pin="0.4.9") as tmp, served(incoming):
        bump_ocx.main()
        assert (tmp / "dist.json").read_bytes() == incoming, "--snapshot-only must write the fetched bytes"
        assert 'DEFAULT_OCX_VERSION = "0.5.2"' in (tmp / "versions.bzl").read_text(), "--snapshot-only must not move the pin"
        ci = (tmp / "workflows" / "ci.yml").read_text()
        assert '"0.4.9"' in ci, f"--snapshot-only must leave the CI pins alone; got: {ci}"


def test_wiring_a_scheduled_run_with_nothing_new_upstream_exits_clean():
    """The cron's steady state, every day upstream does not release: latest
    equals the pin. That is a no-op refresh, not "refusing to move the pin
    0.5.2 -> 0.5.2" — assert_forward only guards an actual move, so the
    scheduled job must not die on it (a die() here raises SystemExit, which
    this suite counts as a failure)."""
    committed = manifest("0.5.1", "0.5.2")
    with sandbox("0.5.2", committed, argv=[]) as tmp, served(json.dumps(committed).encode()):
        bump_ocx.main()
        assert 'DEFAULT_OCX_VERSION = "0.5.2"' in (tmp / "versions.bzl").read_text(), "the pin must stay put"


def test_wiring_a_poisoned_added_row_blocks_both_write_paths():
    """F2 end-to-end. 8 rows of a version nobody pins — channel nightly,
    "z"*64, an off-host url — used to land in the committed snapshot on both
    write paths, because validate() only ever inspects the pinned version and
    --check then re-validates only the pin, so they persisted. dist/dist.json
    is `linguist-generated`, so GitHub collapses the diff that carries them.
    Neither path may write."""
    committed = manifest("0.5.1", "0.5.2")
    poisoned = manifest("0.5.1", "0.5.2", "0.5.3")
    for r in poisoned["releases"]:
        if r["version"] == "0.5.3":
            r.update(channel="nightly", sha256="z" * 64, url="https://evil.example/v0.5.3/ocx.tar.gz")
    body = json.dumps(poisoned).encode()
    for argv in (["--snapshot-only"], []):
        with sandbox("0.5.2", committed, argv=argv) as tmp, served(body):
            before = (tmp / "dist.json").read_bytes()
            dies(bump_ocx.main, why=f"a poisoned added row under {argv or ['(auto-bump)']}")
            assert (tmp / "dist.json").read_bytes() == before, f"{argv or '(auto-bump)'} wrote the poisoned manifest"


def test_wiring_the_bump_path_writes_the_fetched_bytes_verbatim():
    """F3: dist/dist.json is 184 rows of security boundary. Re-serialising it
    through json.dumps would reformat every line and make the one diff that
    matters — a changed sha256 — unreadable. Byte-for-byte, on the bump path
    as well as under --snapshot-only."""
    committed = manifest("0.5.1", "0.5.2")
    # Indented and newline-terminated: a json.dumps round-trip loses both.
    incoming = json.dumps(manifest("0.5.1", "0.5.2", "0.5.3"), indent=4).encode() + b"\n"
    with sandbox("0.5.2", committed, argv=[]) as tmp, served(incoming):
        bump_ocx.main()
        assert (tmp / "dist.json").read_bytes() == incoming, "the bump path must write the fetched bytes"
        assert 'DEFAULT_OCX_VERSION = "0.5.3"' in (tmp / "versions.bzl").read_text(), "the bump must move the pin"
        assert '"0.5.3"' in (tmp / "workflows" / "ci.yml").read_text(), "the bump must move the CI pins"


# --- helper: version_key already has a body; these must pass today ----------


def test_version_key_orders_numerically_and_dies_on_junk():
    """Underpins F1b. A non-numeric component exits with a message rather
    than raising a raw ValueError at the caller."""
    assert bump_ocx.version_key("0.5.2") == (0, 5, 2)
    assert bump_ocx.version_key("0.5.10") > bump_ocx.version_key("0.5.9")
    dies(bump_ocx.version_key, "0.6.0-beta1", why="a non-numeric component")
    dies(bump_ocx.version_key, "", why="an empty version")


def test_version_key_die_covers_what_isdigit_would_wave_through():
    """The docstring promises die(), so no input may reach a raw exception —
    and none may parse to a number that is not what it looks like. isdigit()
    accepts superscripts (ValueError at int()) and Arabic-Indic digits (which
    parse silently); a non-string arrives from manifest["latest"]["version"]."""
    assert dies(bump_ocx.version_key, "0.5.²", why="a superscript component")
    assert dies(bump_ocx.version_key, "٥.٥.٢", why="Arabic-Indic digits")
    assert dies(bump_ocx.version_key, None, why="a non-string version")
    assert dies(bump_ocx.version_key, ["0", "5", "2"], why="a list version")
    assert dies(bump_ocx.version_key, 5, why="an int version")


def main():
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    failures = []
    for t in tests:
        try:
            t()
        except (Exception, SystemExit) as e:  # SystemExit: an over-eager die()
            failures.append(f"{t.__name__}: {type(e).__name__}: {e}")
    for f in failures:
        print(f"FAIL {f}", file=sys.stderr)
    print(f"bump_ocx guards: {len(tests) - len(failures)}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
