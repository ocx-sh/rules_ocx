#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Point the Bazel runs of this checkout at the ocx build named in e2e/rbe/ocx-under-test.txt: a dev package of the
# ocx repository, pulled by digest with the ocx on PATH, signature-verified, SHA-256 taken from the pulled file.
# No pin file: no effect, the released ocx pin stays in force. Run by the `ci:*` and `deep:*` tasks and by the
# `ocx-under-test` composite action, so the logic exists once.
#
# Effects: a marked block in .bazelrc.user of the root and of every examples/* and e2e/* module (each workspace rc imports it): `--lockfile_mode=off` and the pair
# `--repo_env=OCX_INSTALL_BINARY[_SHA256]=...`, because the pair is not in the lockfile. Under GitHub Actions the
# pair is also appended to $GITHUB_ENV for later steps (the rig tasks read OCX_INSTALL_BINARY).
# The pin file is refused on the lane that writes the shared Bazel cache (a push to main), so a dev ocx never
# lands in that cache.
#
# Environment: OCX (the ocx to pull with, default `ocx`), GITHUB_TOKEN and GITHUB_ACTOR (pull credentials when
# the dev package is private), GITHUB_EVENT_NAME and GITHUB_REF (lane detection), OCX_UNDER_TEST_ROOT (the
# checkout to read the pin from; the self-test sets it).
#
# `--guard`: only the lane check, no pull. The lint task runs it, so a pin left in place fails on the default
# branch and in a merge group, and stays silent on a pull request and locally.
set -euo pipefail

root="${OCX_UNDER_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
pin="$root/e2e/rbe/ocx-under-test.txt"
if [[ ! -f "$pin" ]]; then
  [[ "${1:-}" == --guard ]] || echo "no e2e/rbe/ocx-under-test.txt: the released ocx pin stays in force"
  exit 0
fi
# The default branch writes the shared Bazel cache and a merge group is the last gate before it.
if [[ ( "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == refs/heads/main ) || "${GITHUB_EVENT_NAME:-}" == merge_group ]]; then
  echo "::error::e2e/rbe/ocx-under-test.txt is set on the default branch or in a merge group; remove it before merging" >&2
  exit 1
fi
if [[ "${1:-}" == --guard ]]; then
  exit 0
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
else
  # ocx 0.6.5 answers a 401 on ghcr.io's referrers endpoint with an error instead of retrying with the anonymous
  # challenge, so the signature lookup fails on a public package. A pull-scoped bearer token from ghcr.io's token
  # service is the documented OCX_AUTH_<REGISTRY>_TOKEN form and reads it; it lives in this process only.
  anon="$(curl -fsS --retry 3 'https://ghcr.io/token?scope=repository:ocx-sh/dev/cli:pull' | jq -er '.token' || true)"
  if [[ -z "$anon" ]]; then
    echo "::error::no anonymous pull token from ghcr.io and no GITHUB_TOKEN: the pull cannot be authenticated" >&2
    exit 1
  fi
  [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::add-mask::$anon"
  export OCX_AUTH_ghcr_io_TYPE=bearer OCX_AUTH_ghcr_io_TOKEN="$anon"
fi
# The report maps the identifier to the package root: flat in ocx 0.6.5, under `paths` from 0.6.6. A failed pull
# prints an error document instead, so read the key by identifier, never the first entry.
#
# The deep tier runs this script once per task. ocx 0.6.5 fails a second pull of a package whose manifest it
# already holds locally (ghcr.io's referrers endpoint answers "Not authorized"), so the first run records the
# binary it verified and later runs reuse it; the SHA-256 below is always recomputed from the file.
memo="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ocx-under-test.memo"
binary=""
if [[ -f "$memo" ]]; then
  IFS=$'\t' read -r memo_id memo_binary < "$memo" || true
  if [[ "${memo_id:-}" == "$identifier" && -f "${memo_binary:-}" ]]; then
    binary="$memo_binary"
  fi
fi
if [[ -z "$binary" ]]; then
  # A policy-covered pull verifies the signature before it downloads and fails closed.
  status=0
  report="$("${OCX:-ocx}" --config "$config" --format json package pull "$identifier")" || status=$?
  pulled="$(printf '%s' "$report" | jq -r --arg id "$identifier" '(.paths // .)[$id] // empty' 2> /dev/null || true)"
  if [[ "$status" -ne 0 || -z "$pulled" ]]; then
    detail="$(printf '%s' "$report" | jq -r '.error.message // empty' 2> /dev/null || true)"
    echo "::error::ocx package pull of $identifier (exit $status) gave no package root; expected a JSON report mapping the identifier to a directory${detail:+: $detail}" >&2
    exit 1
  fi
  binary="$(find "$pulled/content" -type f \( -name ocx -o -name ocx.exe \) -print -quit)"
  if [[ -n "$binary" ]]; then
    printf '%s\t%s\n' "$identifier" "$binary" > "$memo"
  fi
fi
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

begin="# ocx-under-test begin"
end="# ocx-under-test end"
kept="$scratch/rc.kept"
# Every Bazel workspace the tasks build from: the root and each example module or e2e module with its own
# MODULE.bazel (each imports its own .bazelrc.user).
workspaces=("$root")
for module in "$root"/examples/*/MODULE.bazel "$root"/e2e/*/MODULE.bazel; do
  [[ -f "$module" ]] && workspaces+=("$(dirname "$module")")
done
# Windows: a short output root is standing practice for the CI legs, as it is for any Bazel build on Windows. It
# keeps a test's working directory (its runfiles tree) and the paths a tool opens below it under MAX_PATH (260).
# The launcher starts a long program path itself (`\\?\`), but a long working directory and tools opening their
# own files below a long directory still fail. Users set the line themselves; see docs/guides/cross-platform.md.
short_root=()
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) short_root=("startup --output_user_root=C:/b") ;;
esac
for workspace in "${workspaces[@]}"; do
  rc="$workspace/.bazelrc.user"
  if [[ -f "$rc" ]]; then
    awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' "$rc" > "$kept"
  else
    : > "$kept"
  fi
  {
    cat "$kept"
    echo "$begin"
    [[ "${#short_root[@]}" -eq 0 ]] || echo "${short_root[0]}"
    echo "common --lockfile_mode=off"
    echo "common --repo_env=OCX_INSTALL_BINARY=$binary"
    echo "common --repo_env=OCX_INSTALL_BINARY_SHA256=$sha"
    echo "$end"
  } > "$rc"
done
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "OCX_INSTALL_BINARY=$binary"
    echo "OCX_INSTALL_BINARY_SHA256=$sha"
  } >> "$GITHUB_ENV"
fi
# The pull above already verified the signature against the policy; this prints who signed, from the same
# registry data, so the log names the identity that was trusted.
case "$(uname -s)" in
  Linux) host_os=linux ;;
  Darwin) host_os=darwin ;;
  *) host_os=windows ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) host_arch=arm64 ;;
  *) host_arch=amd64 ;;
esac
signer="$("${OCX:-ocx}" --config "$config" --format json package verify -p "$host_os/$host_arch" "$identifier" 2> /dev/null |
  jq -er '(.data // .) | select(.certificate_identity != null) | "\(.certificate_identity) (issuer \(.certificate_oidc_issuer))"' 2> /dev/null || true)"
echo "ocx under test: signed by ${signer:-<identity not reported by this ocx; the pull verified it against the release.yml policy>}"
echo "ocx under test: $identifier (sha256 $sha)"
