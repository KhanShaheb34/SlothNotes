#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module_cache="$project_dir/.build/module-cache"
test_binary="$project_dir/.build/BearREAModelTests"
test_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/bear-rea-tests.XXXXXX")"
trap 'rm -rf "$test_data_dir"' EXIT

mkdir -p "$module_cache"
swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  -framework Foundation \
  "$project_dir/Sources/BearClone/NoteStore.swift" \
  "$project_dir/Tests/ModelTests.swift" \
  -o "$test_binary"

BEAR_REA_DATA_DIR="$test_data_dir" "$test_binary"

swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  "$project_dir/Sources/BearClone/MarkdownEditor.swift" \
  "$project_dir/Sources/BearClone/AttachmentStore.swift" \
  "$project_dir/Tests/EditorTests.swift" \
  -o "$project_dir/.build/BearREAEditorTests"
"$project_dir/.build/BearREAEditorTests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir/Sources/BearClone/AttachmentStore.swift" "$project_dir/Tests/AttachmentTests.swift" \
  -o "$project_dir/.build/SlothAttachmentTests"
"$project_dir/.build/SlothAttachmentTests"

swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir/Sources/BearClone/NoteStore.swift" "$project_dir/Sources/BearClone/AttachmentStore.swift" \
  "$project_dir/Sources/BearClone/CloudSync.swift" \
  "$project_dir/Tests/SyncTests.swift" -o "$project_dir/.build/SlothSyncTests"
"$project_dir/.build/SlothSyncTests"

swiftc -swift-version 5 -D SLOTH_TESTING -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir"/Sources/BearClone/*.swift "$project_dir/Tests/WorkspaceTests.swift" \
  -o "$project_dir/.build/SlothWorkspaceTests"
"$project_dir/.build/SlothWorkspaceTests" "$project_dir/.build/visual-review"

swiftc -swift-version 5 -D SLOTH_TESTING -target "$(uname -m)-apple-macosx13.0" -parse-as-library \
  -module-cache-path "$module_cache" -framework AppKit \
  "$project_dir"/Sources/BearClone/*.swift "$project_dir/Tests/FileOperationTests.swift" \
  -o "$project_dir/.build/SlothFileOperationTests"
"$project_dir/.build/SlothFileOperationTests"

python3 -m unittest discover -s "$project_dir/Tests" -p 'test_bear_migration.py'
