#!/usr/bin/env bash
set -euo pipefail

# V-27c: the darwin launcher reaches this workspace byte for byte, so its ad-hoc signature is intact and it
# starts on Apple Silicon (an unsigned arm64 binary is killed with SIGKILL before `main`). The control is a copy
# with one byte changed: its signature no longer verifies and the kernel kills it. Every number the verdict rests
# on is printed, so a failed run names its own cause.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -L "$JQ_BIN" "$work/intact"
cp -L "$JQ_BIN" "$work/flipped"
chmod +x "$work/intact" "$work/flipped"

# The entry point (LC_MAIN `entryoff`, a file offset in __TEXT) is code the launcher always runs, so the page
# holding it is validated before the first instruction of `main`. The changed byte is the only difference.
offset="$(otool -l "$work/flipped" | awk '/cmd LC_MAIN/ {main = 1} main && $1 == "entryoff" {print $2; exit}')"
test -n "$offset"
byte="$(dd if="$work/flipped" bs=1 skip="$offset" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
changed=$(((byte + 1) % 256))
# The byte is binary: build the octal escape, then let printf expand it.
# shellcheck disable=SC2059
printf "$(printf '\\%03o' "$changed")" | dd of="$work/flipped" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null
echo "launcher: $(wc -c < "$work/intact" | tr -d ' ') bytes; entryoff=$offset; byte $byte -> $changed"
cmp -l "$work/intact" "$work/flipped" || true
if cmp -s "$work/intact" "$work/flipped"; then
    echo "the control byte was not changed" >&2
    exit 1
fi

echo "--- codesign -dvvv intact"
codesign -dvvv "$work/intact" 2>&1 || true
echo "--- codesign -dvvv flipped"
codesign -dvvv "$work/flipped" 2>&1 || true

# What rules_ocx can prove without the kernel: the shipped blob verifies, the changed copy does not.
verify_intact=0
codesign --verify --verbose=2 "$work/intact" || verify_intact=$?
verify_flipped=0
codesign --verify --verbose=2 "$work/flipped" || verify_flipped=$?

set +e
"$work/intact" --version >/dev/null 2>&1
intact=$?
"$work/flipped" --version >/dev/null 2>&1
flipped=$?
set -e
echo "codesign --verify: intact $verify_intact, flipped $verify_flipped"
echo "run: intact exit $intact, flipped exit $flipped (SIGKILL is 137)"

# The intact copy starts: it finds no sidecar beside it and exits 78 itself.
test "$verify_intact" -eq 0
test "$intact" -eq 78
# The control: the changed copy is invalid and is killed.
test "$verify_flipped" -ne 0
test "$flipped" -eq 137
echo "launcher signature OK"
