#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Bump rules_ocx to an ocx CLI release: snapshot + pin + CI, in lockstep.

Run with --help first; do not read this source to use it.

Writes dist/dist.json, ocx/private/versions.bzl and the setup-ocx pins in
.github/workflows/*.yml. Validates the invariant that dist:check enforces
(pinned version present for all 8 targets, sha256 intact) plus one it does
not: every artifact filename must carry an archive extension that
manifest.bzl's archive_type() actually maps.
"""

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

DIST_URL = "https://setup.ocx.sh/dist.json"
EXPECTED_TARGETS = 8
# Keep in sync with archive_type() in ocx/private/manifest.bzl.
KNOWN_EXTS = (".zip", ".tar.gz", ".tar.xz")

REPO = Path(__file__).resolve().parents[4]
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


def current_pin():
    m = PIN_RE.search(VERSIONS.read_text())
    if not m:
        die(f"DEFAULT_OCX_VERSION not found in {VERSIONS}")
    return m.group(2)


def fetch_snapshot():
    # setup.ocx.sh 403s the default Python-urllib agent; identify ourselves.
    req = urllib.request.Request(DIST_URL, headers={"User-Agent": "rules-ocx-update-dist"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
    except Exception as e:  # noqa: BLE001 - report any network/HTTP failure the same way
        die(f"could not fetch {DIST_URL}: {e}")
    try:
        json.loads(body)
    except json.JSONDecodeError as e:
        die(f"{DIST_URL} returned invalid JSON: {e}")
    DIST.write_bytes(body)
    return json.loads(body)


def load_snapshot():
    return json.loads(DIST.read_text())


def newest_stable(manifest):
    latest = (manifest.get("latest") or {}).get("version")
    if latest:
        return latest
    stable = [r["version"] for r in manifest["releases"] if r.get("channel") == "stable"]
    if not stable:
        die("snapshot has no stable releases and no 'latest' field")
    return max(stable, key=lambda v: tuple(int(x) for x in v.split(".")))


def rows_for(manifest, version):
    return [r for r in manifest["releases"] if r["version"] == version]


def validate(manifest, version):
    """Fails loudly on anything that would break @ocx_tool for this version."""
    rows = rows_for(manifest, version)
    if len(rows) != EXPECTED_TARGETS:
        die(
            f"expected {EXPECTED_TARGETS} targets for {version}, got {len(rows)} — "
            f"the release may still be publishing; retry or pass --version"
        )
    for r in rows:
        if len(r.get("sha256", "")) != 64:
            die(f"{version} {r['target']}: sha256 is not 64 hex chars")
        if ext_of(r["filename"]) is None:
            die(
                f"{version} {r['target']}: filename '{r['filename']}' has no extension "
                f"known to archive_type() in ocx/private/manifest.bzl (known: "
                f"{', '.join(KNOWN_EXTS)}). Teach archive_type() the new format first — "
                f"it silently falls back to tar.xz, which would fail at extraction."
            )
    return rows


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
    ap.add_argument(
        "--version",
        help="exact ocx version to pin (default: the snapshot's latest stable)",
    )
    ap.add_argument(
        "--check",
        action="store_true",
        help="validate the committed snapshot against the current pin; write nothing",
    )
    args = ap.parse_args()

    if args.check:
        manifest = load_snapshot()
        pin = current_pin()
        rows = validate(manifest, pin)
        exts = sorted({ext_of(r["filename"]) for r in rows})
        print(f"OK: {pin} x {len(rows)} targets, archives {exts}")
        return

    before = current_pin()
    manifest = fetch_snapshot()
    version = args.version or newest_stable(manifest)
    rows = validate(manifest, version)

    old_exts = sorted({ext_of(r["filename"]) for r in rows_for(manifest, before)}) if before != version else []
    new_exts = sorted({ext_of(r["filename"]) for r in rows})

    pin_changed = write_pin(version)
    ci = write_ci_pins(version)

    print(f"snapshot: refreshed from {DIST_URL}")
    print(f"pin:      {before} -> {version}" if pin_changed else f"pin:      {version} (unchanged)")
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
