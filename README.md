# Sloth

Sloth is an independent native macOS note-taking app built with Swift and AppKit. It began as a REA-guided recreation of Bear's core experience and now has its own identity, original sloth icon, visual tasks, local attachments, and optional iCloud Drive synchronization. It does not recover or use Bear's original source code.

## Run

Requires macOS 13 or later and the Swift compiler provided by Xcode or the Xcode command line tools. No package dependencies are required.

```sh
./scripts/run.sh
```

The script builds and opens `build/Sloth.app` (version 2.0.0, bundle ID `local.sloth.app`). To build without launching:

```sh
./scripts/build.sh
```

The bundle is ad hoc signed locally when `codesign` is available. It is not notarized or distributed through the App Store.

## Features

- Three-pane native window with sidebar and focus-mode toggles.
- Editable Markdown with lightweight native styling, formatting commands, visual task checkboxes, and undo/redo. Return continues a task list; Return on an empty task exits it.
- Inline image previews and file cards, with image/file insertion through the paperclip, drag and drop, or paste; Quick Look previews for attached files.
- Search, inline `#tags`, and slash-separated nested tag navigation.
- Pinned notes, sorting, duplicate, archive, trash, and restore.
- Light/dark themes, text-size adjustment, note statistics, and a clickable outline of the first nine headings.
- Markdown import and export with referenced attachment files, plus keyboard shortcuts in the menu bar.
- Local persistence and optional iCloud Drive exchange of notes and attachments between Macs running Sloth.

Enable iCloud Drive in Sloth's settings on each Mac using the same Apple Account. Sloth keeps its working library locally and exchanges files through `iCloud Drive/Sloth`. A successful folder update does not confirm Apple server delivery or receipt on another Mac. See [iCloud Drive behavior, conflicts, and limits](docs/icloud.md).

The [reconstruction scope and evidence ledger](docs/reconstruction.md) preserves the REA investigation and separates earlier verification from Sloth v2 validation. The [icon design notes](docs/icon-design.md) describe Sloth's original artwork. Sloth does not provide a private CloudKit database, an iPhone/iPad client, note encryption, OCR, or complete Bear Markdown/search compatibility. It is not affiliated with Bear or Shiny Frog.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New note | ⌘N |
| Search notes | ⇧⌘F |
| Toggle sidebar / focus mode | ⌘1 / ⌘2 |
| Show styles bar | ⇧⌘Y |
| Note information | ⌥⌘I |
| Bold / italic | ⌘B / ⌘I |
| Pin or unpin | ⇧⌘P |
| Duplicate | ⌘D |
| Archive | ⇧⌘A |
| Move to Trash | ⌘Delete |
| Switch theme | ⇧⌘D |
| Import / export Markdown | ⇧⌘I / ⇧⌘E |
| Add images or files | ⌥⌘A |

Search accepts plain terms, quoted phrases, `#tag`, `@todo`, `@untagged`, and `@pinned`. Multiple terms must all match. Restore is available from the Note menu and a note's context menu.

## Notes and privacy

By default, the app stores its own notes at:

```text
~/Library/Application Support/Sloth/notes.json
~/Library/Application Support/Sloth/attachments/
```

On first launch, if the Sloth folder does not yet exist, Sloth copies the earlier **Bear REA recreation's** local library into its new folder and retains the earlier copy. If that migration fails, it reports the problem and continues using the earlier recreation's library. It never reads, migrates, or modifies the installed Bear app's database.

Notes are local JSON and attachments are copied files; Sloth does not encrypt them. Back up the entire library folder. With iCloud Drive enabled, additional revision and attachment files are exchanged in your iCloud Drive Sloth folder.

For an isolated store, set `SLOTH_DATA_DIR` to a directory and launch the executable directly. The earlier `BEAR_REA_DATA_DIR` name remains a fallback alias; `SLOTH_DATA_DIR` takes precedence.

```sh
./scripts/build.sh
SLOTH_DATA_DIR="/tmp/sloth-demo" "./build/Sloth.app/Contents/MacOS/Sloth"
```

## Tests

```sh
./scripts/test.sh
```

The integrated test runner passed **247 assertions**: 55 model, 84 editor, 58 attachment, and 50 sync. It covers models, native editor behavior, attachment import/export, and folder-based synchronization using isolated temporary data. Current live validation—including task toggling/undo, attachment persistence and preview, exact export, and migration—is recorded separately in [docs/reconstruction.md](docs/reconstruction.md).

Sync tests simulate devices on local folders. Separate live iCloud validation found 10 items that macOS reported as uploaded with no upload errors; a real second Mac has not been tested. The tests require normal access to macOS's file coordination service; see [the sync validation notes](docs/icloud.md#validation-and-limits).
