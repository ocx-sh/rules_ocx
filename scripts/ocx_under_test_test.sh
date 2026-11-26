#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Self-test of `ocx_under_test.sh --guard`: a pin file fails on the default branch and in a merge group, and is
# silent on a pull request, on any other ref and locally. Each refusal case has a green twin, so a guard that
# always fails (or never does) is caught.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ocx-under-test-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/pinned/e2e/rbe" "$scratch/clean/e2e/rbe"
echo "ghcr.io/ocx-sh/dev/cli:x@sha256:$(printf '0%.0s' {1..64})" > "$scratch/pinned/e2e/rbe/ocx-under-test.txt"

failures=0
# guard <root> <event> <ref> <want exit> <want silent stdout+stderr: yes|no>
guard() {
  local out status=0
  out="$(env -i PATH="$PATH" OCX_UNDER_TEST_ROOT="$scratch/$1" GITHUB_EVENT_NAME="$2" GITHUB_REF="$3" bash "$here/ocx_under_test.sh" --guard 2>&1)" || status=$?
  if [[ "$status" -ne "$4" ]] || { [[ "$5" == yes ]] && [[ -n "$out" ]]; }; then
    echo "FAIL: root=$1 event=$2 ref=$3: exit $status (want $4), output: $out" >&2
    failures=$((failures + 1))
  fi
}

guard pinned push refs/heads/main 1 no
guard pinned merge_group refs/heads/gh-readonly-queue/main/pr-1-abc 1 no
guard pinned pull_request refs/pull/1/merge 0 yes
guard pinned push refs/heads/feature 0 yes
guard pinned "" "" 0 yes
guard clean push refs/heads/main 0 yes
guard clean merge_group refs/heads/gh-readonly-queue/main/pr-1-abc 0 yes

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi
echo "ocx_under_test.sh --guard: 7 cases ok"
