#!/usr/bin/env bash
set -euo pipefail

# Run a tool and, when it fails, say which one, with what exit code and what it printed: a launcher that cannot
# start its target reports on stderr, and a command substitution inside `grep -q` would hide that.
run() {
    local out status=0
    out="$("$@" 2>&1)" || status=$?
    if [ "$status" -ne 0 ]; then
        echo "FAILED (exit $status): $*" >&2
        echo "$out" >&2
        exit 1
    fi
    printf '%s\n' "$out"
}

run "$SHELLCHECK_BIN" --version | grep -q "version:"
run "$SHFMT_BIN" --version >/dev/null

# The repository rule ran the same tool while Bazel fetched.
grep -q "version:" "$FETCH_VERSION"

# The report contains shellcheck's complaint about the unquoted variable.
grep -q "SC2086" "$REPORT" || {
    echo "SC2086 not in the report:" >&2
    cat "$REPORT" >&2
    exit 1
}
echo "project example OK"
