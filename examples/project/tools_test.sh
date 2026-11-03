#!/usr/bin/env bash
set -euo pipefail

grep -q "version:" <<<"$("$SHELLCHECK_BIN" --version)"
"$SHFMT_BIN" --version >/dev/null

# Lazy launcher: materializes via `ocx exec` on first execution.
grep -q "version:" <<<"$("$SHELLCHECK_LAZY_BIN" --version)"

# The report contains shellcheck's complaint about the unquoted variable.
grep -q "SC2086" "$REPORT"
echo "project example OK"
