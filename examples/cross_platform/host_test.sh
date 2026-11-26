#!/usr/bin/env bash
set -euo pipefail

# The hub tool is the launcher of the set for the platform this test runs on.
out="$("$JQ_BIN" --version)"
echo "$out"
echo "$out" | grep -q "^jq-"
echo "host launcher OK"
