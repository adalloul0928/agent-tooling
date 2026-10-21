#!/bin/bash

set -euo pipefail

disk_image=${1:-}
if [[ ! -f "$disk_image" || "$disk_image" != *.dmg ]]; then
  printf 'Usage: verify-dmg.sh /path/to/Agent-Tooling.dmg\n' >&2
  exit 64
fi

hdiutil verify "$disk_image"
mount_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-tooling-dmg-check.XXXXXX")
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_root" -quiet || return
  fi
  rmdir "$mount_root"
}
trap cleanup EXIT

hdiutil attach "$disk_image" -readonly -nobrowse -mountpoint "$mount_root" -quiet
mounted=true
app="$mount_root/Agent Tooling.app"
test -d "$app"
test -L "$mount_root/Applications"
test "$(readlink "$mount_root/Applications")" = /Applications
test -x "$app/Contents/Helpers/agent-tooling"
test -x "$app/Contents/Helpers/agent-tooling-mcp"
test -s "$app/Contents/Resources/LICENSE.txt"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/AgentTooling" --verify-resources
printf 'Verified disk image and packaged app: %s\n' "$disk_image"
