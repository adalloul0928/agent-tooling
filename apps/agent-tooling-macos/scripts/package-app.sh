#!/bin/bash

set -euo pipefail

script_directory=$(cd "$(dirname "$0")" && pwd -P)
app_root=$(dirname "$script_directory")
source_license="$app_root/../../LICENSE"
scratch_path=${AGENT_TOOLING_BUILD_PATH:-"$app_root/.build/native"}
configuration=${AGENT_TOOLING_CONFIGURATION:-release}
bundle_path=${1:-"$app_root/.build/Agent Tooling.app"}
signing_identity=${AGENT_TOOLING_CODE_SIGN_IDENTITY:--}
release_version=${AGENT_TOOLING_VERSION:-}
build_number=${AGENT_TOOLING_BUILD_NUMBER:-}

if [[ ! -s "$source_license" ]]; then
  printf 'The repository LICENSE is required for packaging.\n' >&2
  exit 66
fi
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

mkdir -p "$scratch_path"
scratch_path=$(cd "$scratch_path" && pwd -P)
build_arguments=(
  --disable-sandbox
  --configuration "$configuration"
  --scratch-path "$scratch_path"
)
for mapping in "$app_root=/source/AgentTooling" "$scratch_path=/build/AgentTooling"; do
  build_arguments+=(
    -Xswiftc -file-prefix-map -Xswiftc "$mapping"
    -Xswiftc -debug-prefix-map -Xswiftc "$mapping"
    -Xcc "-ffile-prefix-map=$mapping"
    -Xcc "-fdebug-prefix-map=$mapping"
  )
done
swift build "${build_arguments[@]}"

binary_directory=$(swift build "${build_arguments[@]}" --show-bin-path)

assembly_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-tooling-package.XXXXXX")
assembled_bundle="$assembly_root/Agent Tooling.app"
trap 'rm -rf "$assembly_root"' EXIT

mkdir -p "$assembled_bundle/Contents/MacOS" "$assembled_bundle/Contents/Helpers" "$assembled_bundle/Contents/Resources"
ditto "$binary_directory/AgentTooling" "$assembled_bundle/Contents/MacOS/AgentTooling"
ditto "$binary_directory/agent-tooling" "$assembled_bundle/Contents/Helpers/agent-tooling"
ditto "$binary_directory/agent-tooling-mcp" "$assembled_bundle/Contents/Helpers/agent-tooling-mcp"
for executable in \
  "$assembled_bundle/Contents/MacOS/AgentTooling" \
  "$assembled_bundle/Contents/Helpers/agent-tooling" \
  "$assembled_bundle/Contents/Helpers/agent-tooling-mcp"; do
  strip -S "$executable"
  for local_path in "$app_root" "$scratch_path" "$HOME/"; do
    if LC_ALL=C grep -aFq "$local_path" "$executable"; then
      printf 'Refusing to package %s: embedded local build path.\n' "$(basename "$executable")" >&2
      exit 65
    fi
  done
done
if [[ -d "$binary_directory/AgentTooling_AgentToolingApp.bundle" ]]; then
  ditto \
    "$binary_directory/AgentTooling_AgentToolingApp.bundle" \
    "$assembled_bundle/Contents/Resources/AgentTooling_AgentToolingApp.bundle"
fi
ditto "$app_root/Resources/Info.plist" "$assembled_bundle/Contents/Info.plist"
ditto "$app_root/Resources/AppIcon.icns" "$assembled_bundle/Contents/Resources/AppIcon.icns"
ditto "$source_license" "$assembled_bundle/Contents/Resources/LICENSE.txt"
cmp -s "$source_license" "$assembled_bundle/Contents/Resources/LICENSE.txt"

if [[ -n "$release_version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$assembled_bundle/Contents/Info.plist"
fi
if [[ -n "$build_number" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$assembled_bundle/Contents/Info.plist"
fi

chmod +x "$assembled_bundle/Contents/MacOS/AgentTooling"
chmod +x "$assembled_bundle/Contents/Helpers/agent-tooling"
chmod +x "$assembled_bundle/Contents/Helpers/agent-tooling-mcp"

signing_arguments=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  signing_arguments+=(--options runtime --timestamp)
fi
codesign "${signing_arguments[@]}" \
  --identifier dev.agenttooling.app.cli \
  "$assembled_bundle/Contents/Helpers/agent-tooling"
codesign "${signing_arguments[@]}" \
  --identifier dev.agenttooling.app.mcp \
  "$assembled_bundle/Contents/Helpers/agent-tooling-mcp"
codesign "${signing_arguments[@]}" "$assembled_bundle"
codesign --verify --deep --strict "$assembled_bundle"
"$assembled_bundle/Contents/MacOS/AgentTooling" --verify-resources

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
