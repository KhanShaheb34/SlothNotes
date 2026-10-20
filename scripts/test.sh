#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module_cache="$project_dir/.build/module-cache"
test_binary="$project_dir/.build/SlothModelTests"
test_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/sloth-tests.XXXXXX")"
trap 'rm -rf "$test_data_dir"' EXIT

mkdir -p "$module_cache"
swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  -framework Foundation \
  "$project_dir/Sources/Sloth/MarkdownTagSyntax.swift" \
  "$project_dir/Sources/Sloth/NoteStore.swift" \
  "$project_dir/Tests/ModelTests.swift" \
  -o "$test_binary"

SLOTH_DATA_DIR="$test_data_dir" "$test_binary"

swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  "$project_dir/Sources/Sloth/MarkdownTagSyntax.swift" \
  "$project_dir/Sources/Sloth/MarkdownSyntaxHighlighter.swift" \
  "$project_dir/Sources/Sloth/MarkdownEditor.swift" \
  "$project_dir/Sources/Sloth/MarkdownLayoutManager.swift" \
  "$project_dir/Sources/Sloth/MarkdownTable.swift" \
  "$project_dir/Sources/Sloth/MarkdownPresentation.swift" \
  "$project_dir/Sources/Sloth/AttachmentStore.swift" \
  "$project_dir/Tests/EditorTests.swift" \
  -o "$project_dir/.build/SlothEditorTests"

for suite in MarkdownPresentation MarkdownLayout EditorPresentation MarkdownTable EditorTable MarkdownSyntaxHighlighter; do
  swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
    -module-cache-path "$module_cache" -framework AppKit \
    "$project_dir/Sources/Sloth/MarkdownTagSyntax.swift" \
    "$project_dir/Sources/Sloth/MarkdownSyntaxHighlighter.swift" \
    "$project_dir/Sources/Sloth/MarkdownEditor.swift" \
    "$project_dir/Sources/Sloth/MarkdownLayoutManager.swift" \
    "$project_dir/Sources/Sloth/MarkdownTable.swift" \
    "$project_dir/Sources/Sloth/MarkdownPresentation.swift" \
    "$project_dir/Sources/Sloth/AttachmentStore.swift" \
    "$project_dir/Tests/${suite}Tests.swift" -o "$project_dir/.build/Sloth${suite}Tests"
  "$project_dir/.build/Sloth${suite}Tests"
done
"$project_dir/.build/SlothEditorTests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir/Sources/Sloth/AttachmentStore.swift" "$project_dir/Tests/AttachmentTests.swift" \
  -o "$project_dir/.build/SlothAttachmentTests"
"$project_dir/.build/SlothAttachmentTests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir/Sources/Sloth/MarkdownTagSyntax.swift" \
  "$project_dir/Sources/Sloth/NoteStore.swift" "$project_dir/Sources/Sloth/AttachmentStore.swift" \
  "$project_dir/Sources/Sloth/CloudSync.swift" \
  "$project_dir/Tests/SyncTests.swift" -o "$project_dir/.build/SlothSyncTests"
"$project_dir/.build/SlothSyncTests"

swiftc -swift-version 5 -D SLOTH_TESTING -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir"/Sources/Sloth/*.swift "$project_dir/Tests/WorkspaceTests.swift" \
  -o "$project_dir/.build/SlothWorkspaceTests"
"$project_dir/.build/SlothWorkspaceTests" "$project_dir/.build/visual-review"

swiftc -swift-version 5 -D SLOTH_TESTING -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir"/Sources/Sloth/*.swift "$project_dir/Tests/FileOperationTests.swift" \
  -o "$project_dir/.build/SlothFileOperationTests"
"$project_dir/.build/SlothFileOperationTests"

python3 -m unittest discover -s "$project_dir/Tests" -p 'test_bear_migration.py'
