#!/usr/bin/env bash
set -euo pipefail

# $(locations ...) is space-separated; the jq package content is the binary
# (plus docs), so find the jq file among them.
find_binary() {
    for f in $1; do
        case "$(basename "$f")" in
            jq | jq.exe) echo "$f" && return 0 ;;
        esac
    done
    echo "no jq binary among: $1" >&2
    return 1
}

assert_abi() {
    # -L: runfiles are symlinks into the ocx store.
    desc="$(file -bL "$1")"
    echo "$1 -> $desc"
    echo "$desc" | grep -E "$2" >/dev/null || {
        echo "expected ABI matching '$2'" >&2
        return 1
    }
}

assert_abi "$(find_binary "$JQ_LINUX_ARM64")" "ELF.*(aarch64|ARM)"
assert_abi "$(find_binary "$JQ_WINDOWS_AMD64")" "PE32\+"
echo "cross-platform ABI assertions OK"
