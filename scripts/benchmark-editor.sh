#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$project_dir/.build/module-cache"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$project_dir/.build/module-cache" -framework AppKit \
  "$project_dir/Sources/Sloth/MarkdownEditor.swift" "$project_dir/Sources/Sloth/AttachmentStore.swift" \
  "$project_dir/Tests/EditorBenchmark.swift" -o "$project_dir/.build/SlothEditorBenchmark"
"$project_dir/.build/SlothEditorBenchmark"
