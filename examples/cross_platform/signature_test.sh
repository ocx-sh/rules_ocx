#!/usr/bin/env bash
set -euo pipefail

# V-27c: the darwin/arm64 launcher reaches this workspace byte for byte, so it ships with a valid ad-hoc
# signature. Positive: `codesign --verify` passes and the launcher runs to its own exit 78 (no sidecar beside
# it). Control A: a copy with one byte changed fails `codesign --verify`. Control B: a copy after
# `codesign --remove-signature` fails `codesign --verify`. Only `codesign` is asserted. The hosted macOS arm64
# runner starts an unsigned arm64 binary (observed: exit 78, not 137), so it does not enforce code signatures,
# and the run exit codes of the changed and the unsigned copy say nothing about the launcher. They are printed,
# never asserted: do not add a kill assertion.
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
echo "run: intact exit $intact, flipped exit $flipped (printed only: this host may not enforce code signatures)"

# Positive: valid signature, and the launcher itself ran (exit 78).
test "$verify_intact" -eq 0
test "$intact" -eq 78
# Control A (deterministic): the changed copy does not verify.
test "$verify_flipped" -ne 0

# Control B: a copy without its signature does not verify. Assert on verify, not on the run.
cp -L "$JQ_BIN" "$work/stripped"
chmod +x "$work/stripped"
codesign --remove-signature "$work/stripped"
echo "--- codesign -dvvv stripped"
codesign -dvvv "$work/stripped" 2>&1 || true
verify_stripped=0
codesign --verify --verbose=2 "$work/stripped" || verify_stripped=$?
stripped="$(run "$work/stripped")"
echo "codesign --verify: stripped $verify_stripped"
echo "run: stripped exit $stripped (printed only)"
echo "note: if the unsigned copy runs, this host does not enforce code signatures, so the run results say nothing about the launcher"
test "$verify_stripped" -ne 0
echo "launcher signature OK"
