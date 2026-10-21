#!/bin/bash

set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)
source_app=${1:-}
destination_dmg=${2:-}
signing_identity=${AGENT_TOOLING_CODE_SIGN_IDENTITY:-}
# DS_Store.template places these items and finds the picture by this volume
# name and path, so none of them can change without regenerating it with
# render-dmg-layout.swift.
volume_name="Agent Tooling"
app_name="Agent Tooling.app"

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
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'The app version must contain three numeric components: %s\n' "$app_version" >&2
  exit 65
fi
# The picture's name carries its version. With another version's image
# already mounted as "Agent Tooling", this one mounts as "Agent Tooling 1",
# and the template's alias looks on that volume first; it holds no file of
# this name, so the alias goes on to this volume's own picture.
background_name="background-$app_version.tiff"

destination_parent=$(dirname "$destination_dmg")
if [[ -L "$destination_parent" ]]; then
  printf 'Refusing to write through a symlink directory: %s\n' "$destination_parent" >&2
  exit 64
fi
codesign --verify --deep --strict "$source_app"
if [[ ! -s "$source_app/Contents/Resources/LICENSE.txt" ]]; then
  printf 'The app bundle must contain LICENSE.txt.\n' >&2
  exit 65
fi
"$source_app/Contents/MacOS/AgentTooling" --verify-resources
mkdir -p "$destination_parent"

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-tooling-dmg.XXXXXX")
mount_point="$staging_root/volume"
writable_dmg="$staging_root/Agent-Tooling-rw.dmg"
temporary_dmg="$staging_root/Agent-Tooling.dmg"
attached=0

detach_volume() {
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$mount_point" -quiet; then
      attached=0
      return 0
    fi
    sleep "$attempt"
  done
  hdiutil detach "$mount_point" -force -quiet
  attached=0
}
cleanup() {
  if ((attached)); then
    hdiutil detach "$mount_point" -force -quiet || true
  fi
  rm -rf "$staging_root"
}
trap cleanup EXIT

# Generate the matching artwork and layout without embedding text metadata.
picture_directory="$staging_root/picture"
swift "$script_directory/render-dmg-layout.swift" picture "$app_version" "$picture_directory"
if ! LC_ALL=C grep -Fqa "/.background/$background_name" "$picture_directory/DS_Store.template"; then
  printf 'The disk image layout does not point at %s: %s\n' "$background_name" "$picture_directory/DS_Store.template" >&2
  exit 65
fi

# Finder picks the 1x or 2x picture from one TIFF. It is made here, not on the
# volume, because tiffutil writes through a temporary folder.
tiffutil -cathidpicheck \
  "$picture_directory/background.png" \
  "$picture_directory/background@2x.png" \
  -out "$staging_root/background.tiff"

# A read-write volume, laid out, then compressed. Its first two items are the
# picture's folder and the picture, which is where the template's alias looks
# for them; Finder's layout, the app and the Applications link follow.
app_kilobytes=$(du -sk "$source_app" | cut -f1)
image_megabytes=$((app_kilobytes * 5 / 4 / 1024 + 16))
# HFS+, not APFS: the template's background alias names an H+ volume and
# catalog IDs 18 and 19.
hdiutil create -size "${image_megabytes}m" -fs HFS+ -volname "$volume_name" -ov "$writable_dmg"
hdiutil attach "$writable_dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$mount_point" -quiet
attached=1

mkdir "$mount_point/.background"
cp -X "$staging_root/background.tiff" "$mount_point/.background/$background_name"
cp -X "$picture_directory/DS_Store.template" "$mount_point/.DS_Store"
ditto "$source_app" "$mount_point/$app_name"
ln -s /Applications "$mount_point/Applications"
codesign --verify --deep --strict "$mount_point/$app_name"
detach_volume

hdiutil convert "$writable_dmg" -format UDZO -o "$temporary_dmg"

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$temporary_dmg"
fi

"$script_directory/verify-dmg.sh" "$temporary_dmg"
mv -f "$temporary_dmg" "$destination_dmg"

printf '%s\n' "$destination_dmg"
