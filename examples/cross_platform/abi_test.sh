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

# $(rlocationpaths ...) is space-separated: every file of the set, packages and
# launchers alike. Collect each file that is a jq executable, as a path on disk.
binaries() {
    for f in $1; do
        case "$(basename "$f")" in
            jq | jq.exe) rlocation "$f" ;;
        esac
    done
}

# Bytes of a file as lowercase hex without separators: `bytes FILE SKIP COUNT`.
bytes() {
    od -An -tx1 -v -j "$2" -N "$3" "$1" | tr -d ' \n'
}

# ELF: magic at 0, e_machine (little endian) at 18; 0xb7 is aarch64.
is_elf_aarch64() {
    [ "$(bytes "$1" 0 4)" = "7f454c46" ] && [ "$(bytes "$1" 18 2)" = "b700" ]
}

# PE: "MZ" at 0, the offset of the PE header at 60, then "PE\0\0" and the machine; 0x8664 is amd64.
is_pe_amd64() {
    [ "$(bytes "$1" 0 2)" = "4d5a" ] || return 1
    local o
    o=$(("0x$(bytes "$1" 62 2 | sed 's/\(..\)\(..\)/\2\1/')" * 65536 + "0x$(bytes "$1" 60 2 | sed 's/\(..\)\(..\)/\2\1/')"))
    [ "$(bytes "$1" "$o" 6)" = "504500006486" ]
}

assert_abi() {
    local check="$2" found=0 f
    for f in $(binaries "$1"); do
        "$check" "$f" || {
            echo "$f is not what $check expects" >&2
            return 1
        }
        echo "$f: $check"
        found=$((found + 1))
    done
    # A set holds the package binary and its launcher.
    if [ "$found" -lt 2 ]; then
        echo "expected the binary and its launcher, found $found in: $1" >&2
        return 1
    fi
}

assert_abi "$JQ_LINUX_ARM64" is_elf_aarch64
assert_abi "$JQ_WINDOWS_AMD64" is_pe_amd64

# Control: the checks tell the two apart.
set -- $(binaries "$JQ_LINUX_ARM64")
if is_pe_amd64 "$1"; then
    echo "an ELF file passed as a PE file" >&2
    exit 1
fi
echo "cross-platform ABI assertions OK"
