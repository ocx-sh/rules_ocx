#!/usr/bin/env bash
set -euo pipefail

# V-27c: the darwin/arm64 launcher reaches this workspace byte for byte, so it ships with a valid ad-hoc
# signature and starts on Apple Silicon. Positive: `codesign --verify` passes and the launcher runs to its own
# exit 78 (it finds no sidecar beside it). Control A: a copy with one byte changed no longer verifies. Control B:
# a copy with its signature removed is refused at start. The hosted runner does not kill a *modified* page of an
# ad-hoc linker-signed binary (the page hash is checked lazily, if at all), so that exit code is printed and
# never asserted. Every number the verdict rests on is printed, so a failed run names its own cause.
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

run() {
    set +e
    "$1" --version >/dev/null 2>&1
    local status=$?
    set -e
    echo "$status"
}
intact="$(run "$work/intact")"
flipped="$(run "$work/flipped")"
echo "codesign --verify: intact $verify_intact, flipped $verify_flipped"
echo "run: intact exit $intact, flipped exit $flipped (printed only: the kernel's page check is not asserted)"

# Positive: valid signature, and the launcher itself ran (exit 78).
test "$verify_intact" -eq 0
test "$intact" -eq 78
# Control A (deterministic): the changed copy does not verify.
test "$verify_flipped" -ne 0

# Control B: without a signature an arm64 binary is refused at start (SIGKILL, 137, "Killed: 9"). Not yet
# observed on a hosted runner, so the verdict below is last and the log shows what happened first.
cp -L "$JQ_BIN" "$work/stripped"
chmod +x "$work/stripped"
codesign --remove-signature "$work/stripped"
echo "--- codesign -dvvv stripped"
codesign -dvvv "$work/stripped" 2>&1 || true
stripped="$(run "$work/stripped")"
echo "run: stripped exit $stripped (expected 137)"
test "$stripped" -ne 78
echo "launcher signature OK"
