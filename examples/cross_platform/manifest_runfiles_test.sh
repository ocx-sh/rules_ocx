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

# An action of a configuration without runfiles trees starts the launcher, once by
# its path and once by its bare name through PATH. Where no tree exists (Windows
# without `--enable_runfiles`, or local execution elsewhere), the launcher finds
# its root through the runfiles manifest Bazel writes beside it: the manifest has
# a line for the record, and the record sits beside Bazel's copy of the launcher.
check() {
    local status
    status="$(rlocation "$2")"
    echo "--- $1"
    cat "$status"
    grep -q "^jq-" "$status" || { echo "$1: jq printed no version" >&2; return 1; }
    grep -q "^exit=0$" "$status" || { echo "$1: the launcher did not exit 0" >&2; return 1; }
    # A sandboxed action stages a tree, and only the tree: nothing beside the launcher to check.
    if grep -q "^tree=no$" "$status"; then
        grep -q '^beside=.*[.]launch$' "$status" || { echo "$1: no record beside the launcher" >&2; return 1; }
        grep -q '^manifest=' "$status" || { echo "$1: no tree and no runfiles manifest" >&2; return 1; }
        # A line is `<key> <absolute target>`; the record's key and target both end in `.launch`.
        grep -Eq '^launch_line=.*[.]launch ((/|[A-Za-z]:[/\\]).*)[.]launch$' "$status" \
            || { echo "$1: the manifest has no line for the record" >&2; return 1; }
    fi
}
check "by path" "$BY_PATH"
check "by bare name" "$BY_NAME"
echo "launcher without a runfiles tree OK"
