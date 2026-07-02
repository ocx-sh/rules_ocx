#!/usr/bin/env bash
set -euo pipefail

# The composed env's path entries are absolute ocx store dirs holding the
# linux/arm64 leaves — not Bazel inputs, read straight from the shared store
# (the same model the eager launchers use).
found=""
for dir in $ARM64_PATH_DIRS; do
    if [ -e "$dir/shellcheck" ]; then
        found="$dir/shellcheck"
    fi
done
if [ -z "$found" ]; then
    echo "no shellcheck among: $ARM64_PATH_DIRS" >&2
    exit 1
fi

# -L: entrypoint dirs may symlink into the content store.
desc="$(file -bL "$found")"
echo "$found -> $desc"
echo "$desc" | grep -E "ELF.*(aarch64|ARM)" >/dev/null || {
    echo "expected an aarch64 ELF" >&2
    exit 1
}
echo "cross-platform project env OK"
