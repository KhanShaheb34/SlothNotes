# iCloud Drive in Sloth

Sloth can exchange notes and attachments through `iCloud Drive/Sloth` between Macs running this app. Enable **iCloud Drive** in Sloth's settings on each Mac, using the same Apple Account. macOS must already have iCloud Drive enabled. Sloth keeps the working library in its local Application Support directory, so editing and saving work without a network connection.

This is ordinary iCloud Drive document synchronization. It does not use a private CloudKit database, a paid Apple developer provisioning profile, or fake iCloud entitlements. The app is locally ad hoc signed. It does not provide a separate iPhone or iPad client.

## What the status means

- **iCloud Drive folder updated** means the folder exchange and the local save completed. It is not confirmation that Apple's servers uploaded the files or that another Mac received them.
- **Waiting for iCloud Drive to download…** means a cloud placeholder is not available locally. Sloth requests its download and retries.
- An unavailable folder, corrupt revision, attachment collision, or file access failure is reported without replacing local notes.
- The app checks every 15 seconds while enabled. **Sync Now** requests an immediate check. Disabling the setting stops new checks; a file operation already in progress can finish.

macOS manages upload scheduling, network outages, storage quotas and account access. Finder's iCloud status is the place to check upload/download problems. A disconnected Mac may still accept writes into its local iCloud Drive folder. Sloth deliberately does not describe that as confirmed delivery.

## Conflict and recovery behavior

Each saved cloud version is an immutable JSON file under `Sloth/revisions/<note-id>/`. Revisions contain the note's text, dates and pin/archive/trash state, plus their parent revision identifiers. Each identifier is a SHA-256 digest of canonical note contents and parents. Local checkpoints record only versions successfully applied to the local library.

When devices edit the same note before seeing each other's changes, Sloth retains one version as the original and creates a clearly titled **(conflict copy)** for each different concurrent version. The copy includes the complete original text and remains visible even if the conflicting state was trashed or archived. IDs and resolution are deterministic, so another device recognizes the same conflict copies. Timestamps select the main version, with a digest tie breaker; clock differences cannot discard the other text.

A missing cloud revision never authorizes dropping a local note. Sloth republishes a local version whose applied cloud head is missing, retaining other visible branches. Trash is soft state and propagates; deleting an item from the local array is not a cloud purge. No history cleanup or remote hard deletion is performed.

Attachments use immutable UUID filenames in `Sloth/attachments/`. Sloth copies missing files in both directions, verifies same-name bytes, refuses symbolic links and never overwrites a different file. A complete attachment is copied before a referencing note is published. Missing referenced attachments prevent that update from being applied and cause a retry. The editor, export and sync use the same Markdown attachment parser, so code examples do not become file requests.

The UI snapshots local notes before background work and applies a returned update only if that exact snapshot is still current. A newer edit or failed local save leaves the local library intact and schedules a retry. The checkpoint advances only after the local save succeeds. Original Bear storage is never used.

## Validation and limits

`Tests/SyncTests.swift` passed 50 assertions as part of the integrated 247-assertion suite. It exercises isolated temporary folders representing multiple Macs: two-way changes, offline concurrent edits and deterministic conflict copies, restart ancestry, trash/restore, attachment delivery and collision preservation, missing cloud history, unavailable folders, malformed revisions, code examples, symbolic-link rejection, and controller apply/reject/disable behavior. These are transport and merge tests; they do not prove Apple server delivery or a real second-device round trip.

The tests use `NSFileCoordinator`, which needs access to macOS's file coordination service. In the Codex shell sandbox that service can return Cocoa error 512; the same isolated tests pass when run with normal macOS process access. Tests never access the real iCloud Drive directory.

Separate live validation enabled iCloud Drive through Sloth's settings and observed **iCloud Drive folder updated**. Eight revision files and two attachments were present in the real Sloth iCloud Drive directory, and the local checkpoint had been saved. A subsequent `URLResourceValues` inspection with normal macOS process access reported **10 ubiquitous items, 10 uploaded items, and 0 upload errors**. This is macOS-reported upload status for those files at the inspection time, beyond the app's folder-update message. Receipt, reopening, and conflict handling on a real second Mac have not been tested.

History and attachment files are retained indefinitely. The app scans revision history during each check and does not yet compact it. Avoid manually editing or removing its history. Sloth's sync directory is visible in Finder and is not encrypted by Sloth; Apple controls the account's iCloud protection.

Apple references: [NSFileCoordinator coordinated access](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:writingitemat:options:error:byaccessor:)) and [requesting an iCloud item download](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)).
