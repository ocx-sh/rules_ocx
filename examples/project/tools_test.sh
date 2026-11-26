#!/usr/bin/env bash
set -euo pipefail

grep -q "version:" <<<"$("$SHELLCHECK_BIN" --version)"
"$SHFMT_BIN" --version >/dev/null

# The repository rule ran the same tool while Bazel fetched.
grep -q "version:" "$FETCH_VERSION"

# The report contains shellcheck's complaint about the unquoted variable.
grep -q "SC2086" "$REPORT"
echo "project example OK"
