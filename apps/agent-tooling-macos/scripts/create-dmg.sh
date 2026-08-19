#!/bin/bash

set -euo pipefail

source_app=${1:-}
destination_dmg=${2:-}
signing_identity=${AGENT_TOOLING_CODE_SIGN_IDENTITY:-}

if [[ ! -d "$source_app" || "$source_app" != *.app ]]; then
  printf 'Usage: create-dmg.sh /path/to/App.app /path/to/App.dmg\n' >&2
  exit 64
fi
if [[ -z "$destination_dmg" || "$destination_dmg" != *.dmg || "$(dirname "$destination_dmg")" == "/" ]]; then
  printf 'Destination must be an explicit .dmg path\n' >&2
  exit 64
fi
if [[ -L "$destination_dmg" ]]; then
  printf 'Refusing to replace a symlink destination: %s\n' "$destination_dmg" >&2
  exit 64
fi
if [[ -e "$destination_dmg" && ! -f "$destination_dmg" ]]; then
  printf 'Refusing to replace a non-file destination: %s\n' "$destination_dmg" >&2
  exit 64
fi

destination_parent=$(dirname "$destination_dmg")
if [[ -L "$destination_parent" ]]; then
  printf 'Refusing to write through a symlink directory: %s\n' "$destination_parent" >&2
  exit 64
fi
mkdir -p "$destination_parent"

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-tooling-dmg.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
volume_root="$staging_root/volume"
temporary_dmg="$staging_root/Agent-Tooling.dmg"
mkdir -p "$volume_root"

ditto "$source_app" "$volume_root/Agent Tooling.app"
ln -s /Applications "$volume_root/Applications"

hdiutil create \
  -volname "Agent Tooling" \
  -srcfolder "$volume_root" \
  -format UDZO \
  -ov \
  "$temporary_dmg"

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$temporary_dmg"
fi

hdiutil verify "$temporary_dmg"
mv -f "$temporary_dmg" "$destination_dmg"

printf '%s\n' "$destination_dmg"
