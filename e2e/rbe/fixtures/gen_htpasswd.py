# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Writes a per-run zot htpasswd file and the matching credentials file; never committed.

Usage: gen_htpasswd.py <state-dir>
Creates <state-dir>/htpasswd (bcrypt, what zot reads) and <state-dir>/credentials.json
({"user": ..., "password": ...}). A fresh random password every run.
"""

from __future__ import annotations

import json
import secrets
import sys
from pathlib import Path

import bcrypt

USER = "rig"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    state = Path(argv[1])
    state.mkdir(parents=True, exist_ok=True)
    password = secrets.token_urlsafe(24)
    digest = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=10)).decode()
    (state / "htpasswd").write_text(f"{USER}:{digest}\n", encoding="utf-8")
    creds = state / "credentials.json"
    creds.write_text(json.dumps({"user": USER, "password": password}), encoding="utf-8")
    creds.chmod(0o600)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
