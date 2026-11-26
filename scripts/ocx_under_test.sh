#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Point the Bazel runs of this checkout at the ocx build named in e2e/rbe/ocx-under-test.txt: a dev package of the
# ocx repository, pulled by digest with the ocx on PATH, signature-verified, SHA-256 taken from the pulled file.
# No pin file: no effect, the released ocx pin stays in force. Run by the `ci:*` and `deep:*` tasks and by the
# `ocx-under-test` composite action, so the logic exists once.
#
# Effects: a marked block in .bazelrc.user (the workspace rc imports it): `--lockfile_mode=off` and the pair
# `--repo_env=OCX_INSTALL_BINARY[_SHA256]=...`, because the pair is not in the lockfile. Under GitHub Actions the
# pair is also appended to $GITHUB_ENV for later steps (the rig tasks read OCX_INSTALL_BINARY).
# The pin file is refused on the lane that writes the shared Bazel cache (a push to main), so a dev ocx never
# lands in that cache.
#
# Environment: OCX (the ocx to pull with, default `ocx`), GITHUB_TOKEN and GITHUB_ACTOR (pull credentials when
# the dev package is private), GITHUB_EVENT_NAME and GITHUB_REF (cache-write lane detection).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/e2e/rbe/ocx-under-test.txt"
if [[ ! -f "$pin" ]]; then
  echo "no e2e/rbe/ocx-under-test.txt: the released ocx pin stays in force"
  exit 0
fi
if [[ "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == refs/heads/main ]]; then
  echo "::error::e2e/rbe/ocx-under-test.txt is set on the lane that writes the shared Bazel cache; remove it before merging" >&2
  exit 1
fi

# `|| true`: a comment-only file must reach the format check below, not die on pipefail.
identifier="$(grep -v '^[[:space:]]*\(#.*\)\?$' "$pin" | head -n 1 | tr -d '[:space:]' || true)"
# Only the dev package of the ocx repository, addressed by digest.
if [[ ! "$identifier" =~ ^ghcr\.io/ocx-sh/dev/cli(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::e2e/rbe/ocx-under-test.txt must hold ghcr.io/ocx-sh/dev/cli[:tag]@sha256:<hex>" >&2
  exit 1
fi

scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ocx-under-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# The dev build is signed by release.yml of the ocx repository on whichever branch was dispatched; the ref varies,
# the workflow and the OIDC issuer do not. Trade-off: `refs/heads/.+` means anyone with push access to the ocx
# repository can produce a build this step trusts.
config="$scratch/ocx.toml"
cat > "$config" <<'TOML'
[[trust.policy]]
scope = "ghcr.io/ocx-sh/dev/*"
signers = [
  { kind = "keyless", identity_regexp = "^https://github\\.com/ocx-sh/ocx/\\.github/workflows/release\\.yml@refs/heads/.+$", oidc_issuer = "https://token.actions.githubusercontent.com" },
]
TOML

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export OCX_AUTH_ghcr_io_USER="${GITHUB_ACTOR:-token}"
  export OCX_AUTH_ghcr_io_TOKEN="$GITHUB_TOKEN"
fi
# A policy-covered pull verifies the signature before it downloads and fails closed.
pulled="$("${OCX:-ocx}" --config "$config" --format json package pull "$identifier" | jq -er '.paths | to_entries[0].value')"
binary="$(find "$pulled/content" -type f \( -name ocx -o -name ocx.exe \) -print -quit)"
if [[ -z "$binary" ]]; then
  echo "::error::no ocx binary in the pulled package" >&2
  exit 1
fi
if command -v sha256sum > /dev/null 2>&1; then
  sha="$(sha256sum "$binary" | cut -d' ' -f1)"
else
  sha="$(shasum -a 256 "$binary" | cut -d' ' -f1)"
fi
if command -v cygpath > /dev/null 2>&1; then
  binary="$(cygpath -m "$binary")"
fi

rc="$root/.bazelrc.user"
begin="# ocx-under-test begin"
end="# ocx-under-test end"
kept="$scratch/rc.kept"
if [[ -f "$rc" ]]; then
  awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$rc" > "$kept"
else
  : > "$kept"
fi
{
  cat "$kept"
  echo "$begin"
  echo "common --lockfile_mode=off"
  echo "common --repo_env=OCX_INSTALL_BINARY=$binary"
  echo "common --repo_env=OCX_INSTALL_BINARY_SHA256=$sha"
  echo "$end"
} > "$rc"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "OCX_INSTALL_BINARY=$binary"
    echo "OCX_INSTALL_BINARY_SHA256=$sha"
  } >> "$GITHUB_ENV"
fi
echo "ocx under test: $identifier (sha256 $sha)"
