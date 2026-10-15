# Sloth

Sloth is an independent native macOS note-taking app built with Swift and AppKit. It began as a REA-guided recreation of Bear's core experience and now has its own identity, original sloth icon, visual tasks, local attachments, and optional iCloud Drive synchronization. It does not recover or use Bear's original source code.

## Run

Requires macOS 13 or later and the Swift compiler provided by Xcode or the Xcode command line tools. No package dependencies are required.

```sh
./scripts/run.sh
```

The script builds and opens `build/Sloth.app` (version 2.1.0, bundle ID `local.sloth.app`). To build without launching:

```sh
./scripts/build.sh
```

The bundle is ad hoc signed locally when `codesign` is available. It is not notarized or distributed through the App Store.

## Features

- Three-pane native window with refined light/dark themes, sidebar and focus-mode toggles, and restored reading positions.
- Editable Markdown with lightweight native styling, formatting commands, visual task checkboxes, and undo/redo. Return continues a task list; Return on an empty task exits it.
- Inline image previews and file cards, with image/file insertion through the paperclip, drag and drop, or paste; Quick Look previews for attached files.
- Search, inline `#tags`, Bear-style closed tags, slash-separated nested tag navigation, and clickable `[[wiki links]]`.
- Pinned notes, sorting, duplicate, archive, trash, and restore.
- Light/dark themes, text-size adjustment, note statistics, and a clickable outline of the first nine headings.
- Markdown import and export with referenced attachment files, plus keyboard shortcuts in the menu bar.
- Local persistence and optional iCloud Drive exchange of notes and attachments between Macs running Sloth.

Enable iCloud Drive in Sloth's settings on each Mac using the same Apple Account. Sloth keeps its working library locally and exchanges files through `iCloud Drive/Sloth`. A successful folder update does not confirm Apple server delivery or receipt on another Mac. See [iCloud Drive behavior, conflicts, and limits](docs/icloud.md).

The [reconstruction scope and evidence ledger](docs/reconstruction.md) preserves the REA investigation and separates earlier verification from Sloth v2 validation. The [icon design notes](docs/icon-design.md) describe Sloth's original artwork. Sloth does not provide a private CloudKit database, an iPhone/iPad client, note encryption, OCR, or complete Bear Markdown/search compatibility. It is not affiliated with Bear or Shiny Frog.

See the [2.1 visual and performance review](docs/improvements.md) for changes, measured benchmarks, and validation limits.

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

On first launch, if the Sloth folder does not yet exist, Sloth copies the earlier **Bear REA recreation's** local library into its new folder and retains the earlier copy. If that migration fails, it reports the problem and continues using the earlier recreation's library. The running app does not access Bear's database. An explicit, separate [read-only migration tool](docs/bear-migration.md) can snapshot Bear and copy its notes and attachments into Sloth, preserving the source.

Typing saves on a background queue after a short pause, with checkpoints during continuous typing and a durable flush on quit. Notes are local JSON and attachments are copied files; Sloth does not encrypt them. Back up the entire library folder. With iCloud Drive enabled, additional revision and attachment files are exchanged in your iCloud Drive Sloth folder.

For an isolated store, set `SLOTH_DATA_DIR` to a directory and launch the executable directly. The earlier `BEAR_REA_DATA_DIR` name remains a fallback alias; `SLOTH_DATA_DIR` takes precedence.

```sh
./scripts/build.sh
SLOTH_DATA_DIR="/tmp/sloth-demo" "./build/Sloth.app/Contents/MacOS/Sloth"
```

## Tests

```sh
./scripts/test.sh
```

The final suite passes 554 assertions plus 11 migration safety tests. The integrated test runner covers models, native editor behavior, attachment import/export, and folder-based synchronization using isolated temporary data. Native workspace tests and migration tests provide additional layout and preservation checks. See [the improvement review](docs/improvements.md) and [migration documentation](docs/bear-migration.md).

Sync tests simulate devices on local folders. Separate live iCloud validation found 10 items that macOS reported as uploaded with no upload errors; a real second Mac has not been tested. The tests require normal access to macOS's file coordination service; see [the sync validation notes](docs/icloud.md#validation-and-limits).
