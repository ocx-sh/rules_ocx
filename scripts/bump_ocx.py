#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Bump rules_ocx to an ocx CLI release: snapshot + pin + CI, in lockstep.

Run with --help first; do not read this source to use it.

Writes dist/dist.json; unless --snapshot-only, also ocx/private/versions.bzl
and the setup-ocx pins in .github/workflows/*.yml. Per-row validation (also
what --check runs, and what `task dist:check` is) requires the pinned version
to be present for all 8 targets, each with channel "stable", a
64-lowercase-hex sha256, an artifact URL on the ocx release host, and an
archive extension that manifest.bzl's archive_type() actually maps. A refresh
additionally requires that the incoming manifest only *adds* rows to the
committed one, and holds every added row to that same per-row bar.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import unquote, urlsplit

DIST_URL = "https://setup.ocx.sh/dist.json"
EXPECTED_TARGETS = 8
# Keep in sync with archive_type() in ocx/private/manifest.bzl.
KNOWN_EXTS = (".zip", ".tar.gz", ".tar.xz")
# artifact_url() in manifest.bzl returns row["url"] verbatim, so these two are
# the only thing standing between a fabricated row and an attacker-chosen host.
# Mirrors are unaffected: OCX_INSTALL_MIRROR_URL rewrites at download time.
ARTIFACT_HOST = "github.com"
ARTIFACT_PATH = "/ocx-sh/ocx/releases/download/"
ARTIFACT_PREFIX = f"https://{ARTIFACT_HOST}{ARTIFACT_PATH}"
RELEASE_PAGE = "https://github.com/ocx-sh/ocx/releases"
SHA256_RE = re.compile(r"[0-9a-f]{64}")

REPO = Path(__file__).resolve().parents[1]
DIST = REPO / "dist" / "dist.json"
VERSIONS = REPO / "ocx" / "private" / "versions.bzl"
WORKFLOWS = REPO / ".github" / "workflows"

PIN_RE = re.compile(r'(DEFAULT_OCX_VERSION = ")([^"]+)(")')


def die(msg):
    sys.exit(f"error: {msg}")


def ext_of(filename):
    for e in KNOWN_EXTS:
        if filename.endswith(e):
            return e
    return None


def on_release_host(u):
    """True only for a URL that really resolves to the ocx release host.

    startswith(ARTIFACT_PREFIX) is not a host check: GitHub normalises dot
    segments server-side, so a url of
    ".../releases/download/../../../../attacker/evil/releases/download/v1/ocx.tar.gz"
    matches the prefix and still serves *another repository's* release asset
    (verified live: the traversal 302s to the same asset the direct url does,
    with and without curl --path-as-is). Anyone can create a repo and a
    release, so that is attacker-chosen bytes with an attacker-chosen sha256
    from the same row. Parse into components instead, and refuse the separator
    characters a prefix match also waves through.
    """
    if not isinstance(u, str) or any(c in u for c in "\r\n\t\0"):
        return False
    try:
        p = urlsplit(u)
    except ValueError:  # e.g. a malformed IPv6 literal
        return False
    return bool(
        p.scheme == "https"
        and p.netloc == ARTIFACT_HOST  # netloc, not hostname: userinfo must not pass
        and not p.query
        and not p.fragment
        and p.path.startswith(ARTIFACT_PATH)
        # unquoted: %2e%2e is a dot segment to anything that normalises.
        and ".." not in unquote(p.path).split("/")
    )


def version_key(v):
    """Parses "x.y.z" into an integer tuple for comparison; die()s on anything
    that is not ASCII dotted-decimal instead of raising. isdigit() is not the
    check: it accepts superscripts ("0.5.²" -> raw ValueError) and
    isdecimal() alone accepts Arabic-Indic digits ("٥.٥.٢"
    parses silently to (5, 5, 2)). A non-string reaches here from
    manifest["latest"]["version"].
    """
    if not isinstance(v, str) or not all(p.isascii() and p.isdecimal() for p in v.split(".")):
        die(f"{v!r} is not a dotted-numeric version (e.g. '0.5.2')")
    return tuple(int(p) for p in v.split("."))


def current_pin():
    m = PIN_RE.search(VERSIONS.read_text())
    if not m:
        die(f"DEFAULT_OCX_VERSION not found in {VERSIONS}")
    return m.group(2)


def fetch_snapshot():
    """Fetches and parses the upstream manifest; does not write
    dist/dist.json. Returns (body, manifest): the raw bytes for the caller
    to write and the parsed dict for the caller to validate. The caller
    must run every guard against `manifest` first — the write happens
    last, only once validation passes.
    """
    # setup.ocx.sh 403s the default Python-urllib agent; identify ourselves.
    req = urllib.request.Request(DIST_URL, headers={"User-Agent": "rules-ocx-update-dist"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
    except Exception as e:  # noqa: BLE001 - report any network/HTTP failure the same way
        die(f"could not fetch {DIST_URL}: {e}")
    try:
        manifest = json.loads(body)
    except json.JSONDecodeError as e:
        die(f"{DIST_URL} returned invalid JSON: {e}")
    return body, manifest


def load_snapshot():
    try:
        return json.loads(DIST.read_text())
    except (OSError, json.JSONDecodeError) as e:
        die(f"{DIST} is missing or not valid JSON ({e}) — restore it with `git checkout -- {DIST}`, then re-run")


def newest_stable(manifest):
    latest = (manifest.get("latest") or {}).get("version")
    if latest:
        return latest
    stable = [r["version"] for r in manifest["releases"] if r.get("channel") == "stable"]
    if not stable:
        die("snapshot has no stable releases and no 'latest' field")
    return max(stable, key=version_key)


def rows_for(manifest, version):
    return [r for r in manifest["releases"] if r["version"] == version]


def check_row(r, where):
    """Fails loudly on one release row that would break @ocx_tool or point it
    at bytes we never vouched for. `where` names the row in the message.
    Every field is read with .get() — a malformed row must die() with something
    the operator can act on, not a KeyError out of this function's internals.
    Calls die() on failure.
    """
    if r.get("channel") != "stable":
        die(
            f"{where}: channel is {r.get('channel', '<missing>')!r}, not 'stable' — "
            f"rules_ocx ships stable ocx releases only. Wait for the stable release, "
            f"or name an older stable with --version <x.y.z>."
        )
    if not isinstance(r.get("sha256"), str) or not SHA256_RE.fullmatch(r["sha256"]):
        die(
            f"{where}: sha256 is {r.get('sha256')!r}, not 64 lowercase hex chars — "
            f"that value is what download_and_extract enforces. Check {DIST_URL} "
            f"against {RELEASE_PAGE} before shipping this row."
        )
    if not on_release_host(r.get("url")):
        die(
            f"{where}: url {r.get('url')!r} does not resolve to {ARTIFACT_PREFIX} — "
            f"artifact_url() in ocx/private/manifest.bzl uses it verbatim, and a prefix "
            f"match is no defence (github.com normalises '..' server-side). Mirrors "
            f"belong in OCX_INSTALL_MIRROR_URL; if the release host really moved, change "
            f"ARTIFACT_HOST/ARTIFACT_PATH in this script deliberately."
        )
    filename = r.get("filename")
    if not isinstance(filename, str) or ext_of(filename) is None:
        die(
            f"{where}: filename {filename!r} has no extension known to archive_type() "
            f"in ocx/private/manifest.bzl (known: {', '.join(KNOWN_EXTS)}). Teach "
            f"archive_type() the new format first — it silently falls back to tar.xz, "
            f"which would fail at extraction."
        )


def validate(manifest, version):
    """Fails loudly on anything that would break @ocx_tool for this version.
    The target-count check is deliberately scoped to `version`: an
    unconditional one would false-fire while upstream is mid-publish.
    check_row() is not scoped — assert_additions_only() runs it over every row
    a refresh adds, because those ship in the same file and any of them can be
    selected with ocx.download(version = ...).
    """
    rows = rows_for(manifest, version)
    if len(rows) != EXPECTED_TARGETS:
        die(
            f"expected {EXPECTED_TARGETS} targets for {version}, got {len(rows)} — "
            f"the release may still be publishing; retry or pass --version"
        )
    for r in rows:
        check_row(r, f"{version} {r['target']}")
    return rows


def assert_latest_stable(manifest):
    """Refuses a manifest whose "latest" pointer is not channel "stable" —
    the auto-selected version must never come from a beta/rc/nightly
    pointer. Only called on the auto-select path (no explicit --version).
    Calls die() on failure.
    """
    latest = manifest.get("latest")
    if not latest:
        # No pointer to trust; newest_stable() falls back to filtering
        # `releases` by channel, which is the safer path anyway.
        return
    if latest.get("channel") != "stable":
        die(
            f"{DIST_URL} 'latest' points at {latest.get('version', '?')} on channel "
            f"{latest.get('channel', '<missing>')!r}, not 'stable' — auto-select follows "
            f"that pointer. Read the ocx changelog, then pin by hand with --version <x.y.z>."
        )


def assert_forward(before, target):
    """Refuses a `target` version that is not strictly greater than `before`,
    compared as integer tuples, so the pin can never move backwards. Only
    guards the auto-selected version — an explicit --version on the command
    line bypasses this check. Calls die() on failure.
    """
    if version_key(target) <= version_key(before):
        die(
            f"refusing to move the pin {before} -> {target}: the snapshot's latest stable "
            f"is not newer than the current pin. Pass --version {target} to pin it anyway."
        )


def index_rows(manifest, where):
    """Indexes a manifest's releases by (version, target), after checking that
    the manifest is shaped like one at all. Refuses a duplicate key: a dict
    keeps the LAST row per key, but select_release() in
    ocx/private/manifest.bzl returns the FIRST — so a second row would be
    invisible to every guard below and still be what @ocx_tool downloads.
    Calls die() on failure.
    """
    rows = manifest.get("releases")
    if not isinstance(rows, list):
        die(f"{where} has no 'releases' list ({type(rows).__name__}) — refusing to guess its shape")
    latest = manifest.get("latest")
    if latest is not None and not isinstance(latest, dict):
        die(f"{where} has a non-object 'latest' ({latest!r}) — refusing to guess its shape")
    out = {}
    for r in rows:
        if not isinstance(r, dict) or not all(isinstance(r.get(f), str) for f in ("version", "target")):
            die(f"{where} has a release row without a string version and target: {r!r}")
        key = (r["version"], r["target"])
        if key in out:
            die(
                f"{where}: {key[0]} {key[1]} appears twice — select_release() takes the "
                f"first match, so a duplicate row shadows a committed sha256. Check "
                f"{RELEASE_PAGE}/tag/{r.get('tag', '?')} and, if the duplicate is already "
                f"committed, `git log -p -- dist/dist.json` for when it landed. Never edit rows "
                f"by hand."
            )
        out[key] = r
    return out


def assert_additions_only(committed, incoming):
    """Refuses a snapshot update unless the only change is new rows. A
    (version, target) row present in both `committed` and `incoming` that
    differs in any field is a hard failure — the sha256 column is the
    security boundary this guards. A row present in `committed` but absent
    from `incoming` is also a hard failure; the die() message must name
    the dropped rows. Every *added* row is put through check_row(), because
    validate() only ever sees the version being pinned while the whole
    manifest gets written. Calls die() on failure.
    """
    # Indexed, not comprehended: both sides are checked for duplicate keys.
    # `committed` too — a duplicate that ever landed would otherwise be
    # permanently invisible, since it compares equal to itself every refresh.
    old = index_rows(committed, DIST)
    new = index_rows(incoming, DIST_URL)

    dropped = sorted(f"{v} {t}" for v, t in old if (v, t) not in new)
    if dropped:
        die(
            f"refusing the refresh: rows for {', '.join(dropped)} are committed in {DIST} "
            f"but absent from {DIST_URL} — a released row must not disappear. Check "
            f"{RELEASE_PAGE} for a deleted or re-cut release before anything else; "
            f"never drop rows by hand."
        )

    # Compared over the union of fields, so a column appearing upstream also
    # trips this — deliberate: a new column changes what a row means.
    for key, was in old.items():
        now = new[key]
        moved = sorted(f for f in set(was) | set(now) if was.get(f) != now.get(f))
        if moved:
            fields = ", ".join(f"{f}: {was.get(f)!r} -> {now.get(f)!r}" for f in moved)
            die(
                f"refusing the refresh: {key[0]} {key[1]} was rewritten upstream ({fields}) — "
                f"a committed row is immutable, and its sha256 is what download_and_extract "
                f"enforces. Compare {RELEASE_PAGE}/tag/{was.get('tag', '?')} with the "
                f"committed row (`git show HEAD:dist/dist.json`); never edit rows by hand."
            )

    # Only the *pinned* version reaches validate(), but the whole manifest is
    # written, and ocx.download(version = ...) lets a consumer select any row
    # in it — so an added row has to clear the same per-row bar.
    for key in sorted(set(new) - set(old)):
        check_row(new[key], f"{key[0]} {key[1]} (new in {DIST_URL})")


def write_pin(version):
    text = VERSIONS.read_text()
    new = PIN_RE.sub(rf"\g<1>{version}\g<3>", text, count=1)
    changed = new != text
    if changed:
        VERSIONS.write_text(new)
    return changed


def write_ci_pins(version):
    """Repins `ocx-sh/setup-ocx` steps so CI dogfoods the version we ship."""
    touched = []
    for wf in sorted(WORKFLOWS.glob("*.yml")):
        lines = wf.read_text().splitlines(keepends=True)
        hits = 0
        for i, line in enumerate(lines):
            if "ocx-sh/setup-ocx@" not in line:
                continue
            # The version key follows the `uses:` line within the step's `with:`.
            for j in range(i + 1, min(i + 4, len(lines))):
                body = lines[j].rstrip("\r\n")
                eol = lines[j][len(body):]  # preserve the line ending verbatim
                m = re.match(r'(\s*version:\s*)"([^"]+)"(.*)$', body)
                if m:
                    if m.group(2) != version:
                        lines[j] = f'{m.group(1)}"{version}"{m.group(3)}{eol}'
                        hits += 1
                    break
        if hits:
            wf.write_text("".join(lines))
            touched.append(f"{wf.name} ({hits})")
    return touched


def main():
    ap = argparse.ArgumentParser(
        description="Bump the ocx CLI snapshot, pin and CI pins in lockstep.",
    )
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--version",
        help="exact ocx version to pin (default: the snapshot's latest stable). "
        "Bypasses the auto-select guards — neither the forward-only check nor "
        "the 'latest' channel check applies; the per-row and additions-only "
        "checks still do",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="validate the committed snapshot against the current pin; write nothing",
    )
    mode.add_argument(
        "--snapshot-only",
        action="store_true",
        help="refresh dist/dist.json only — additions-only checked, pin untouched",
    )
    args = ap.parse_args()

    if args.check:
        manifest = load_snapshot()
        pin = current_pin()
        index_rows(manifest, DIST)  # a duplicate row hand-landed in the snapshot
        rows = validate(manifest, pin)
        exts = sorted({ext_of(r["filename"]) for r in rows})
        print(f"OK: {pin} x {len(rows)} targets, archives {exts}")
        return

    before = current_pin()
    committed = load_snapshot()
    body, manifest = fetch_snapshot()

    # Guards first: nothing is written until every one of them passes.
    assert_additions_only(committed, manifest)
    if args.snapshot_only:
        version = before  # a refresh, not a bump — the pin stays put
    elif args.version:
        version = args.version
    else:
        assert_latest_stable(manifest)
        version = newest_stable(manifest)
        if version != before:
            assert_forward(before, version)
    rows = validate(manifest, version)

    old_exts = sorted({ext_of(r["filename"]) for r in rows_for(manifest, before)}) if before != version else []
    new_exts = sorted({ext_of(r["filename"]) for r in rows})

    # Raw bytes, never json.dumps: reformatting a 184-row security-boundary
    # file would make every future diff unreadable.
    DIST.write_bytes(body)
    pin_changed = not args.snapshot_only and write_pin(version)
    ci = [] if args.snapshot_only else write_ci_pins(version)

    print(f"snapshot: {DIST} refreshed from {DIST_URL}")
    print(f"pin:      {before} -> {version}" if pin_changed else f"pin:      {version} (unchanged)")
    if args.snapshot_only:
        print("ci pins:  untouched (--snapshot-only)")
    else:
        print(f"ci pins:  {', '.join(ci)}" if ci else "ci pins:  already current")
    print(f"targets:  {len(rows)}, archives {new_exts}")
    if old_exts and old_exts != new_exts:
        print(
            f"\nNOTE: archive format changed {old_exts} -> {new_exts}. Confirm "
            f"archive_type() in ocx/private/manifest.bzl maps every new extension "
            f"and that its docstring names the right cutover version."
        )


if __name__ == "__main__":
    main()
