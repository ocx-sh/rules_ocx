#!/usr/bin/env bash
# Linux only (sha256sum, stat -c).
# A local ocx (OCX_INSTALL_BINARY + OCX_INSTALL_BINARY_SHA256) is hash-checked, version-checked against the floor,
# copied, and immune to later edits of its source file.
#
# Env: OCX_E2E_OUTPUT_USER_ROOT (Bazel output_user_root; default: a temp dir),
#      BAZEL (Bazel binary; default: bazel), HOME as the caller wants it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bazel_bin="${BAZEL:-bazel}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="${OCX_E2E_OUTPUT_USER_ROOT:-$work/bazel}"

fake="$work/ocx"
printf '#!/bin/sh\necho "ocx 9.9.9-fake-one"\n' > "$fake"
chmod +x "$fake"
good_sha="$(sha256sum "$fake" | cut -d' ' -f1)"
bad_sha="$(printf '%064d' 0)"

bz() {
  local sha="$1"
  shift
  (cd "$here" && "$bazel_bin" --ignore_all_rc_files --output_user_root="$root" "$@" \
    --lockfile_mode=off \
    --repo_env=OCX_INSTALL_BINARY="$fake" \
    --repo_env=OCX_INSTALL_BINARY_SHA256="$sha")
}

fail() {
  echo "RED: $*" >&2
  exit 1
}

# 1. wrong hash: the fetch fails and names the hash.
if out="$(bz "$bad_sha" build //:version 2>&1)"; then
  fail "build succeeded with a wrong OCX_INSTALL_BINARY_SHA256"
fi
grep -q "$bad_sha" <<<"$out" || fail "failure does not name the wanted hash: $out"
grep -qi "checksum" <<<"$out" || fail "failure is not a checksum mismatch: $out"
echo "GREEN: wrong hash fails the fetch and names the hash"

# 2. right hash: the binary runs.
bz "$good_sha" build //:version
out_file="$(cd "$here" && "$bazel_bin" --ignore_all_rc_files --output_user_root="$root" info bazel-bin)/version.txt"
grep -q "9.9.9-fake-one" "$out_file" || fail "@ocx_tool//:ocx did not print the fake version"
echo "GREEN: right hash builds and the fake ocx ran"

# 3. the fetched file is a copy, not a link to the source.
base="$(cd "$here" && "$bazel_bin" --ignore_all_rc_files --output_user_root="$root" info output_base)"
copy="$(find "$base/external" -path '*ocx_tool/local/ocx' -print -quit)"
[ -n "$copy" ] || fail "fetched copy not found under $base/external"
[ ! -L "$copy" ] || fail "fetched copy is a symlink"
[ "$(readlink -f "$copy")" != "$(readlink -f "$fake")" ] || fail "fetched copy resolves to the source file"
[ "$(stat -c %i "$copy")" != "$(stat -c %i "$fake")" ] || fail "fetched copy is a hard link to the source"
echo "GREEN: fetched ocx is a distinct copy"

# 4. edit the source (env unchanged): the output stays.
printf '#!/bin/sh\necho "ocx 9.9.9-fake-two"\n' > "$fake"
bz "$good_sha" build //:version
grep -q "9.9.9-fake-one" "$out_file" || fail "editing the source file changed the build output"
echo "GREEN: editing the source file leaves the output unchanged"

# 5. control: a new hash does refetch, so step 4 was not vacuous.
new_sha="$(sha256sum "$fake" | cut -d' ' -f1)"
bz "$new_sha" build //:version
grep -q "9.9.9-fake-two" "$out_file" || fail "a changed hash did not refetch the binary"
echo "GREEN: a changed hash refetches (control for the previous step)"

# 6. a binary below the floor: the fetch fails and names the floor and the variable.
printf '#!/bin/sh\necho "0.0.1"\n' > "$fake"
low_sha="$(sha256sum "$fake" | cut -d' ' -f1)"
if out="$(bz "$low_sha" build //:version 2>&1)"; then
  fail "build succeeded with a binary below the floor"
fi
grep -q "OCX_INSTALL_BINARY is ocx 0.0.1" <<<"$out" || fail "failure does not name the variable and the version: $out"
grep -q "needs ocx [0-9.]* or newer" <<<"$out" || fail "failure does not name the floor: $out"
echo "GREEN: a binary below the floor fails the fetch and names OCX_INSTALL_BINARY"

# 7. a binary whose `ocx version` prints no version.
printf '#!/bin/sh\necho "not a version"\n' > "$fake"
junk_sha="$(sha256sum "$fake" | cut -d' ' -f1)"
if out="$(bz "$junk_sha" build //:version 2>&1)"; then
  fail "build succeeded with a binary that prints no version"
fi
grep -q "OCX_INSTALL_BINARY did not report a version" <<<"$out" || fail "failure is not the unreadable-version message: $out"
echo "GREEN: unreadable version output fails the fetch and names OCX_INSTALL_BINARY"
