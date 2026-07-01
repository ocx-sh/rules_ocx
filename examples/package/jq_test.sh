#!/usr/bin/env bash
set -euo pipefail

# Floating, frozen-index, digest-pinned, and lazy repos all provision a
# working jq (the lazy launcher materializes on this first execution).
test "$("$JQ_BIN" -r .greeting "$PRETTY_JSON")" = "hello"
test "$("$JQ_FROZEN_BIN" -r .greeting "$PRETTY_JSON")" = "hello"
test "$("$JQ_PINNED_BIN" -r .target "$PRETTY_JSON")" = "bazel"
test "$("$JQ_LAZY_BIN" -r .greeting "$PRETTY_JSON")" = "hello"

# The genrule output was produced by the provisioned jq.
grep -q '"greeting"' "$PRETTY_JSON"
echo "package example OK"
