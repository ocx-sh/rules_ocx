#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
set -euo pipefail

"$SHELLCHECK_BIN" --version | grep -q "version:"
"$ACTIONLINT_BIN" -version >/dev/null
"$BUILDIFIER_BIN" --version | grep -q "buildifier version"
echo "dev_tools launchers OK"
