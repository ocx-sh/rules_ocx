#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
set -euo pipefail

grep -q "version:" <<<"$("$SHELLCHECK_BIN" --version)"
"$ACTIONLINT_BIN" -version >/dev/null
grep -q "buildifier version" <<<"$("$BUILDIFIER_BIN" --version)"
echo "dev_tools launchers OK"
