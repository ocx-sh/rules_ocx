#!/usr/bin/env bash
set -euo pipefail

"$SHELLCHECK_BIN" --version | grep -q "version:"
"$SHFMT_BIN" --version >/dev/null

# The report contains shellcheck's complaint about the unquoted variable.
grep -q "SC2086" "$REPORT"
echo "project example OK"
