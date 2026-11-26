#!/usr/bin/env bash
set -euo pipefail

# Apple Silicon kills a binary whose ad-hoc signature no longer matches its
# bytes. The launcher must reach this workspace byte for byte: a copy that
# still carries its signature is not killed, a copy with one changed byte is.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -L "$JQ_BIN" "$work/intact"
cp -L "$JQ_BIN" "$work/flipped"
chmod +x "$work/intact" "$work/flipped"

# Change one byte inside the first signed pages. It is the only difference.
offset=20000
byte="$(dd if="$work/flipped" bs=1 skip="$offset" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
changed=$(((byte + 1) % 256))
printf "$(printf '\\%03o' "$changed")" | dd of="$work/flipped" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null
if cmp -s "$work/intact" "$work/flipped"; then
    echo "the control byte was not changed" >&2
    exit 1
fi

set +e
"$work/intact" --version >/dev/null 2>&1
intact=$?
"$work/flipped" --version >/dev/null 2>&1
flipped=$?
set -e
echo "intact exit $intact, flipped exit $flipped"

# The intact copy starts (it finds no sidecar beside it and exits 78); only
# the changed copy is killed. SIGKILL is 137 in a shell.
test "$intact" -ne 137
test "$flipped" -eq 137
echo "launcher signature OK"
