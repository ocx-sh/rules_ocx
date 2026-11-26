# Copyright 2026 The OCX Authors
# SPDX-License-Identifier: Apache-2.0
"""Replaces the baseline table in RESULTS.md with the one run_baseline.py wrote.

Usage: fold_baseline.py <baseline.json> <RESULTS.md>
Reads <baseline>.md beside the JSON and writes it between the `baseline:begin` and `baseline:end` markers.
Stdlib only.
"""

from __future__ import annotations

import sys
from pathlib import Path

BEGIN, END = "<!-- baseline:begin -->", "<!-- baseline:end -->"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 64
    table = Path(argv[1]).with_suffix(".md").read_text(encoding="utf-8")
    results = Path(argv[2])
    text = results.read_text(encoding="utf-8")
    head, sep, rest = text.partition(BEGIN)
    _, sep2, tail = rest.partition(END)
    if not (sep and sep2):
        print(f"{results}: markers {BEGIN} / {END} not found", file=sys.stderr)
        return 65
    results.write_text(f"{head}{BEGIN}\n{table}{END}{tail}", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
