#!/bin/bash

set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)
app_root=$(dirname "$script_directory")
scratch_path=${AGENT_TOOLING_BUILD_PATH:-"$app_root/.build/native"}
configuration=${AGENT_TOOLING_CONFIGURATION:-debug}
bundle_path=${1:-"$app_root/.build/Agent Tooling.app"}
signing_identity=${AGENT_TOOLING_CODE_SIGN_IDENTITY:--}
release_version=${AGENT_TOOLING_VERSION:-}
build_number=${AGENT_TOOLING_BUILD_NUMBER:-}

if [[ "$bundle_path" != *.app || "$(dirname "$bundle_path")" == "/" ]]; then
  printf 'Destination must be an explicit .app path: %s\n' "$bundle_path" >&2
  exit 64
fi
if [[ -L "$bundle_path" ]]; then
  printf 'Refusing to replace a symlink destination: %s\n' "$bundle_path" >&2
  exit 64
fi
if [[ -e "$bundle_path" && ! -d "$bundle_path" ]]; then
  printf 'Refusing to replace a non-directory destination: %s\n' "$bundle_path" >&2
  exit 64
fi
bundle_parent=$(dirname "$bundle_path")
if [[ -L "$bundle_parent" ]]; then
  printf 'Refusing to write through a symlink directory: %s\n' "$bundle_parent" >&2
  exit 64
fi
if [[ -n "$release_version" && ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'AGENT_TOOLING_VERSION must contain three numeric components: %s\n' "$release_version" >&2
  exit 64
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]+$ ]]; then
  printf 'AGENT_TOOLING_BUILD_NUMBER must be numeric: %s\n' "$build_number" >&2
  exit 64
fi

cd "$app_root"

swift build \
  --disable-sandbox \
  --configuration "$configuration" \
  --scratch-path "$scratch_path"

binary_directory=$(swift build \
  --disable-sandbox \
  --configuration "$configuration" \
  --scratch-path "$scratch_path" \
  --show-bin-path)

assembly_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-tooling-package.XXXXXX")
assembled_bundle="$assembly_root/Agent Tooling.app"
trap 'rm -rf "$assembly_root"' EXIT

mkdir -p "$assembled_bundle/Contents/MacOS" "$assembled_bundle/Contents/Resources"
ditto "$binary_directory/AgentTooling" "$assembled_bundle/Contents/MacOS/AgentTooling"
if [[ -d "$binary_directory/AgentTooling_AgentToolingApp.bundle" ]]; then
  ditto \
    "$binary_directory/AgentTooling_AgentToolingApp.bundle" \
    "$assembled_bundle/Contents/Resources/AgentTooling_AgentToolingApp.bundle"
fi
ditto "$app_root/Resources/Info.plist" "$assembled_bundle/Contents/Info.plist"
ditto "$app_root/Resources/AppIcon.icns" "$assembled_bundle/Contents/Resources/AppIcon.icns"

if [[ -n "$release_version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$assembled_bundle/Contents/Info.plist"
fi
if [[ -n "$build_number" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$assembled_bundle/Contents/Info.plist"
fi

chmod +x "$assembled_bundle/Contents/MacOS/AgentTooling"

signing_arguments=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  signing_arguments+=(--options runtime --timestamp)
fi
codesign "${signing_arguments[@]}" "$assembled_bundle"
codesign --verify --deep --strict "$assembled_bundle"

mkdir -p "$bundle_parent"
replacement_root=$(mktemp -d "$bundle_parent/.agent-tooling-install.XXXXXX")
replacement_bundle="$replacement_root/Agent Tooling.app"
trap 'rm -rf "$assembly_root" "$replacement_root"' EXIT
ditto "$assembled_bundle" "$replacement_bundle"
codesign --verify --deep --strict "$replacement_bundle"

previous_bundle=""
if [[ -d "$bundle_path" ]]; then
  previous_bundle="$replacement_root/previous.app"
  mv "$bundle_path" "$previous_bundle"
fi
if ! mv "$replacement_bundle" "$bundle_path"; then
  if [[ -n "$previous_bundle" && -d "$previous_bundle" ]]; then
    mv "$previous_bundle" "$bundle_path"
  fi
  printf 'Could not install the assembled app at %s\n' "$bundle_path" >&2
  exit 1
fi
rm -rf "$replacement_root"
touch "$bundle_path"

printf '%s\n' "$bundle_path"
