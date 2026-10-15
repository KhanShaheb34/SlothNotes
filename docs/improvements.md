# Sloth 2.1 review and improvements

The review covered the AppKit workspace, editor, persistence, attachments, search/tag indexing, iCloud exchange, and the Bear migration path. The changes preserve the existing JSON library format and keep Bear read-only.

## Visual and interaction changes

- Warm paper and graphite themes share a consistent coral accent; selected notes have a subtle tint and accent edge.
- More compact note rows include tag context, reusable date formatters, and a clearer pinned state.
- Buttons have hover/pressed feedback. Nested tags indent by depth.
- The formatting toolbar fits the minimum window size and has its own space, so it cannot cover editable text or save status.
- Note/section/sort preferences survive relaunch. Switching notes preserves selection and reading position.
- Wiki links open matching notes in Sloth, including archived notes. Web and email links are interactive; unsupported URL schemes remain inert. Markdown remains portable.
- Search waits briefly for a typing pause; active note rows stay in place while editing.

## Responsiveness and correctness

| Finding | Change |
| --- | --- |
| Every key encoded, reread, decoded, and rewrote the entire library and backup | Serial background autosave after 300 ms idle, with checkpoints during continuous typing and explicit lifecycle flush |
| Sidebar repeatedly sorted/parsed the library and recreated controls | Cached metadata, indexes and section counts; reuse controls and update their counts |
| Every editor change reprojected/restyled and forced layout of the whole note | Reproject/restyle touched paragraphs; full parse only for structural fence changes; visible layout on demand |
| Undo retained full copies of large notes | Ordinary edits retain only their changed text |
| Scroll drawing read file metadata and decoded images | Cache card details; decode bounded thumbnails on two background workers, reserving image dimensions |
| Editor/import/export disagreed on attachment Markdown | Shared parser covers escaped labels, angle URLs, titles, and fenced examples |
| Idle sync reread every revision and rehashed every attachment | Cache verified files using inode, size, modification and change timestamps; still detect changed bytes and collisions |
| Idle sync rebuilt the current note | Compare attachment identities and refresh only changed previews |
| Complex tags/fences could misindex notes or crash | Preserve Bear closed tags, reject empty path components, match fence closers consistently |
| Incoming updates during marked-text composition could corrupt undo | Defer sync application until composition ends; commit composition before switching or quitting |
| File operations could block typing | Run file import/export on a serial background queue and apply results to the captured destination safely |

## Measured performance

Release builds on this Mac, using synthetic data and isolated libraries:

| Workload | Before | After |
| --- | ---: | ---: |
| Edit an 89,461-character / 1,000-line note, median | 151.74 ms | 0.60 ms |
| Same editor workload, 95th percentile | 198.51 ms | 0.63 ms |
| Load the same note | 148.33 ms | 46.13 ms |
| Ten sidebar/filter passes, 2,000 notes | 29,065 ms | 78.28 ms |
| Thirty model typing updates, 2,000 notes | 979 ms | under 1 ms |

The model typing measurement covers caller-thread work; persistence now happens separately. A final durable save of that synthetic library takes about 19 ms. These microbenchmarks do not claim measured end-to-end click latency or a particular display frame rate.

Reproduce editor measurements with `scripts/benchmark-editor.sh`; model benchmarks run when `SLOTH_BENCHMARK=1` is set for the optimized model test binary.

## Verification

The final build passes **554 assertions** (109 model, 278 editor, 58 attachment, 55 sync, 18 workspace, 36 background-file) and **11 migration safety tests**. Regression checks cover text/source parity, Unicode and IME composition, undo/redo, checkbox behavior, attachment import/export, file integrity, autosave/flush/failure recovery, sync conflicts and cache invalidation, native workspace layout, and migration preservation/idempotency.

Native AppKit view snapshots are generated from an isolated demo library by `Tests/WorkspaceTests.swift`. Light, dark, and minimum-width variants were reviewed. The computer-use bridge was unavailable during this review, so these are rendered native-view tests rather than a live mouse/keyboard walkthrough.

A real second-Mac iCloud round trip remains untested. Sync history is retained indefinitely; verified-file caching reduces repeated reads but does not compact history.

## Migration result

On 2026-10-15, 118 Bear documents were copied into Sloth: 36 active, 50 archived, and 32 in Trash. All 28 attachment records were retained through 23 unique byte-verified files. The 8 pre-existing Sloth notes remain, for 126 total. There were no unreadable/encrypted documents, missing files, or conflict copies. A separate Sloth backup and import receipt were retained. Bear source hashes and modification times matched before and after the import. A later background database-file update changed the SQLite bytes; a fresh independent snapshot verified that all 118 logical note records and attachment hashes still matched exactly. The runtime parser also verified all 88 source tag relationships and every imported attachment link.

The imported library is local. An attempted explicit iCloud update was stopped by automatic approval review before execution because uploading these imported private documents requires specific approval. Sloth was left closed; its existing iCloud preference remains enabled. No claim is made that the imported library has uploaded.
