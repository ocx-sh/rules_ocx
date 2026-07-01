#!/usr/bin/env bash
set -euo pipefail

# Floating, frozen-index, and digest-pinned repos all provision a working jq.
test "$("$JQ_BIN" -r .greeting "$PRETTY_JSON")" = "hello"
test "$("$JQ_FROZEN_BIN" -r .greeting "$PRETTY_JSON")" = "hello"
test "$("$JQ_PINNED_BIN" -r .target "$PRETTY_JSON")" = "bazel"

# The genrule output was produced by the provisioned jq.
grep -q '"greeting"' "$PRETTY_JSON"
echo "package example OK"
