#!/usr/bin/env bash
# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

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

run "$(rlocation "$SHELLCHECK_BIN")" --version | grep -q "version:"
run "$(rlocation "$SHFMT_BIN")" --version >/dev/null

# The repository rule ran the same tool while Bazel fetched.
grep -q "version:" "$(rlocation "$FETCH_VERSION")"

# The report contains shellcheck's complaint about the unquoted variable.
report_file="$(rlocation "$REPORT")"
grep -q "SC2086" "$report_file" || {
    echo "SC2086 not in the report:" >&2
    cat "$report_file" >&2
    exit 1
}
echo "project example OK"
