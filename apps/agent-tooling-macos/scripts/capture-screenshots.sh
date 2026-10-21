#!/usr/bin/env bash
# Render the app's real views with isolated test services and sample data.
set -euo pipefail
app_root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$app_root/../../docs/images"}
mkdir -p "$output"
output=$(cd "$output" && pwd)
cd "$app_root"
AGENT_TOOLING_DOCUMENTATION_OUTPUT="$output" \
  swift test --disable-sandbox --filter DocumentationScreenshotsTests
