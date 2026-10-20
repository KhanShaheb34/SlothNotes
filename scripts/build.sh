#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$project_dir/build/Sloth.app"
contents_dir="$app_bundle/Contents"
module_cache="$project_dir/.build/module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  printf 'Swift is required. Install the Xcode command line tools with: xcode-select --install\n' >&2
  exit 1
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$module_cache"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
if [[ -f "$project_dir/Resources/Sloth.icns" ]]; then
  cp "$project_dir/Resources/Sloth.icns" "$contents_dir/Resources/Sloth.icns"
fi

swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library \
  -O \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework Foundation \
  "$project_dir"/Sources/Sloth/*.swift \
  -o "$contents_dir/MacOS/Sloth"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$app_bundle"
fi

printf 'Built %s\n' "$app_bundle"
