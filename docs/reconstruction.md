# Sloth: reconstruction scope and evidence

Sloth is an independent Swift/AppKit app that began as a recreation of a useful local subset of Bear. Version 2.0.0 uses the name Sloth, bundle ID `local.sloth.app`, an [original generated sloth icon](icon-design.md), visual tasks, local attachments, and optional [iCloud Drive exchange](icloud.md). The historical source folder remains `Sources/BearClone`; the built app is `build/Sloth.app`.

This is not Bear's recovered source, a complete compatibility implementation, or a claim of pixel-perfect parity. No proprietary Bear font/image files were copied, and no private Bear notes or database files were copied into app content or test fixtures. The editor uses macOS system fonts and SF Symbols.

## Inspected artifact

The installed application was Bear **3.0.1 (14853)**, bundle identifier `net.shinyfrog.bear`, at `/Applications/Bear.app`. Its bundle metadata specifies macOS 12.4 as the original app's minimum version. This reconstruction separately targets macOS 13.

REA inspected the `arm64` slice of the universal Mach-O executable `/Applications/Bear.app/Contents/MacOS/Bear`. The available architectures were `arm64` and `x86_64`. The recorded subject SHA-256 is:

```text
4a4249fa6e32f16cb5e61a6fce830a4a1e73bc4b4b20d9eb3ac3f8747cc4b7f1
```

The saved [REA evidence export](evidence/bear-rea.json) contains five records from Hopper, macOS native inspection, and the REA workflow/artifact graph providers. Evidence IDs below refer to exact records in that file.

## Static evidence ledger

1. **Bundle identity — `inspect_plist`.** Confirms version, build, executable, bundle ID, and original minimum OS. Evidence: `ev_582c9547eb47b8e89ca3547469ed1bba41540d9ec6ec29b9ef9271ae4eced13a`.

2. **Binary overview — `binary_overview`.** The derived Hopper overview reports 39,089 procedures, 20,891 strings, and five segments. These are static analysis inventory counts, not a recovered design specification. Evidence: `ev_1f7dc8791af33fdfd4b07957d041be85dc8dac2ddf00f963675b8d795755ea60`.

3. **Named behaviors — `search_procedures`.** The case-insensitive expression `SFNote.*(archive|trash|pin)|SFMain.*(split|sidebar)` returned 71 symbols. These include split-view visibility/layout methods, note pin/unpin and archive/unarchive methods, and sidebar controller accessors. Names support the selected feature scope but do not prove runtime behavior or all user-facing semantics. Evidence: `ev_36c89819dcd1d9da195b249a99a8fd05225cfc182a2fde5eb89a9878d2ee7ac6`.

4. **Partial Interface Builder archive graph — `decode_interface_builder`.** The call was bounded to 8 documents, 500 objects, and 500 connections. The resulting graph has 500 nodes, 281 edges, and `truncated: true`. The eight decoded documents are from `MDTextKitUI.framework`: two AutoComplete scenes, EditorMenus, four EditorPanels scenes/controllers, and a FileMetadata controller. Six document records report complete recognized hierarchies; two report incomplete hierarchies. These are not a complete decode of Bear's main window or all its menus. Many remaining archives were omitted by the document limit. Evidence: `ev_548f88bff3fc67120740c8be1b24cc00e627762f6789738e6bc011fae2e15e75`.

   REA explicitly limits this result to recognized keyed-archive objects and connections. Private or unrecognized fields remain unknown; selectors do not establish matching binary implementations. Constraints, runtime visibility, dynamically created UI, and pixel geometry are not inferred from the archive graph.

5. **Three-pane layout method — `analyze_function`.** Hopper analyzed `-[SFMainSplitViewController showTagsNotesAndEditorControllers:]` at `0x10000ee58`. Its pseudocode checks `isAnimating`, obtains the tag-list and note-list split items, calls `collapseSplitViewItems:collapsed:animated:`, and calls `setTopToolbarExpanded:animated:` on the notes controller. This supports a controller-based, multi-pane layout model. The unresolved `collapsed` argument appears as address `0x1004fe370`; it was not treated as a decoded Boolean or complete layout specification. Hopper also reports that its public Python API does not expose complete function body ranges. Evidence: `ev_e213822ab20662c2ec73d846bc627e96ff8a992c44e01a8df9de2d3ea7867d16`.

Separate read-only resource inspection is documented in [resource-observations.md](resource-observations.md). That document records literal theme colors, packaged font names, nib/localization strings, and app-supplied onboarding feature descriptions. Those observations do not establish active preferences or runtime visibility.

## Earlier Bear REA live verification

Live computer-use observation is separate from REA's static records. The exported REA JSON has empty `captures`, `environments`, and `scenarios` arrays; it contains no screenshot capture or executed scenario evidence. Runtime observations and rebuild screenshots must therefore be identified separately, not attributed to one of the static evidence IDs above.

During live CUA inspection, the original Bear app's View menu exposed Notes, Untagged, Todo, Today, Locked, Pinned, Archive, Trash, and “Show Tags, Notes and Editor.” Invoking that layout showed a dark graphite sidebar, white list/editor, pinned indicators, a bottom floating formatting toolbar, and top information/more controls. The app had initially been in a fullscreen editor-only layout. No original-app screenshots were saved, to avoid retaining private note content. These observations establish the visible layout and menu labels in that session, not the complete behavior of each command.

The earlier Bear REA reconstruction was separately launched and both light and dark three-pane windows visually checked. A newly created verification note was edited, searched via its parent nested tag, pinned, and recovered with the exact content after quitting and reopening the app. Archive, restore, and moving the verification note into the read-only Trash view were exercised through the native UI. At that point the verification note remained recoverable in the reconstruction's Trash. Markdown export was exercised with the native save dialog and its bytes matched the stored Markdown exactly. The original Bear window was returned to its initial editor-only layout.

That earlier build succeeded as an arm64 Mach-O app, and `codesign --verify --deep --strict` passed for its ad hoc signature. Its test runner passed **50 model assertions** and **43 editor assertions**, covering persistence/recovery, filters, Unicode, formatting, undo/redo, read-only behavior, and checkbox toggling with code-fence exclusions. A live click on an unchecked todo visibly checked it; Command-Z restored it. These are historical results for Bear REA, not evidence that all Sloth v2 changes have passed those same live routes.

The model test script uses an isolated temporary data directory. Build success, local model tests, and a visible native window establish different things; none establishes full behavioral or visual parity with Bear.

## Sloth v2 implementation and validation

The integrated test suite passed **247 assertions**: **55 model**, **84 native editor**, **58 attachment**, and **50 sync**, after attachment previews moved to a dedicated `QLPreviewView` window. The attachment tests include the regression where ImageIO could classify a PDF as an image; PDFs now remain document attachments. The sync tests use isolated temporary folders representing devices, including controller apply/reject/disable checks. These tests do not prove Apple server delivery or a real second-device round trip. [icloud.md](icloud.md) details coordination requirements, revision ancestry, conflict copies, missing-file retries, and retained history.

Current Sloth v2 live checks, separate from those tests:

- Rounded unchecked tasks and blank tasks were visually checked against the supplied reference; clicking a task checked it, and Undo restored it.
- The Sloth source PNG was imported, displayed inline, copied into the local attachment library, and still rendered after relaunch. Opening it displayed a dedicated Quick Look preview window with its original name. Closing the final preview returned focus to the same editor note; the closed preview controller is released.
- A native Markdown export preserved the exact stored Markdown and copied the referenced image with identical bytes.
- All seven notes in the earlier Bear REA recreation's local library migrated with exact contents.
- iCloud Drive was enabled through settings. The UI reported a completed folder update; eight revision files and two attachments were present, and a local checkpoint was saved. A separate macOS `URLResourceValues` inspection under normal process access reported ten ubiquitous items, ten uploaded items, and zero reported upload errors. This records macOS's upload status at that time; no real second Mac was tested.

The final PDF file-card UI check remains unverified: native automation could highlight the PDF in the file picker, but Open remained disabled, and native mouse/keyboard actions intermittently returned unavailable-window errors. The picker was cancelled and the app returned to the editor. The file picker explicitly allows all file types; automated import tests verify genuine PDFs remain file-link Markdown, including PDFs with misleading image extensions. This is a live-verification limitation, not a claim that PDF import was completed in the final UI build.

The app uses its own `~/Library/Application Support/Sloth/` directory for `notes.json`, attachment files, and local sync state. If that directory is absent, first launch copies the earlier `Bear REA` recreation's local library and selected preferences. The old library is retained; on copy failure the app reports the error and uses that earlier library. This migration never accesses the actual Bear database. `SLOTH_DATA_DIR` overrides the local directory, with `BEAR_REA_DATA_DIR` retained as a fallback alias.

Current implemented scope:

- Three-pane native window with sidebar, searchable/sortable note list, and editable Markdown; sidebar and focus-mode toggles.
- Notes, Today, Todo, Untagged, Archive, and Trash sections; pinned notes; duplicate, archive, trash, and restore actions.
- Inline `#tags` and slash-separated nested tags. Search combines terms and quoted phrases, with `#tag`, `@todo`, `@untagged`, and `@pinned` filters.
- Lightweight Markdown styling and format insertion for headings, bold, italic, strikethrough, links, code, quotes, and lists. Todo markers render as native visual checkboxes, while the saved document remains Markdown. Task clicks, continuation/exit with Return, and editing participate in undo/redo.
- Image previews and file cards backed by copied local attachments, added through a file picker, paste, or drag and drop. Quick Look previews attached documents. Markdown import brings permitted relative attachments into the library; export writes Markdown plus the referenced attachment files.
- Red Graphite and Dark Graphite-inspired themes; editor text-size adjustment.
- Word/character counts, estimated reading time, and a clickable outline limited to the first nine Markdown headings.
- UTF-8 Markdown/plain-text import and Markdown export; local JSON persistence in Sloth's own directory.
- Optional iCloud Drive folder exchange for notes and attachments, with immutable revisions and deterministic conflict copies. A completed folder exchange is not confirmation of upload or delivery to another Mac.

This does not implement a private CloudKit database, a mobile client, note encryption, OCR, Bear's full rich-attachment behavior, complete CommonMark rendering, Bear's full search language, multiword `#tag names#`, tag management/folding, backlinks, a note-history browser, additional windows, all export formats, or all original themes. Sloth retains sync revisions but does not expose them as Bear-style history. The local data format is independent of Bear's database.
