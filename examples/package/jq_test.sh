#!/usr/bin/env bash
set -euo pipefail

# Both the floating and the digest-pinned repo provision a working jq.
test "$("$JQ_BIN" -r .greeting "$PRETTY_JSON")" = "hello"
test "$("$JQ_PINNED_BIN" -r .target "$PRETTY_JSON")" = "bazel"

# The genrule output was produced by the provisioned jq.
grep -q '"greeting"' "$PRETTY_JSON"
echo "package example OK"
