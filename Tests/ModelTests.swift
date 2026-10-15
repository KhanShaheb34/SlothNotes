import Foundation

@main
enum ModelTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    /// Opt in with SLOTH_BENCHMARK=1; no timing thresholds make correctness
    /// dependent on CPU load. Compile with -O when comparing release behavior.
    static func benchmark(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = (0..<2_000).map { index in
            Note(text: "# Note \(index)\n\n" + String(repeating: "A note about careful design and a quiet morning. ", count: 20) + "\n- [ ] Task\n#work/design #personal")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(notes).write(to: directory.appendingPathComponent("notes.json"))
        let store = NoteStore(directory: directory, seed: false)
        let sidebarStart = Date()
        for _ in 0..<10 {
            _ = store.tags
            for section in ["all", "today", "todo", "untagged", "archive", "trash", "tag:work"] {
                _ = store.filtered(section: section)
            }
        }
        let sidebarMilliseconds = Date().timeIntervalSince(sidebarStart) * 1_000
        let typingStart = Date()
        for index in 0..<30 {
            store.update(id: notes[0].id, text: notes[0].text + String(repeating: "x", count: index + 1))
        }
        let typingMilliseconds = Date().timeIntervalSince(typingStart) * 1_000
        let flushStart = Date()
        expect(store.flush(), "Benchmark final revision flush succeeds")
        let flushMilliseconds = Date().timeIntervalSince(flushStart) * 1_000
        let reloaded = NoteStore(directory: directory, seed: false)
        expect(reloaded.notes.count == 2_000 && reloaded.note(id: notes[0].id)?.text == store.note(id: notes[0].id)?.text, "Benchmark saves every note and the final edit")
        print(String(format: "2,000 notes: ten sidebar/filter passes %.2f ms; thirty typing updates %.2f ms; final durable flush %.2f ms.", sidebarMilliseconds, typingMilliseconds, flushMilliseconds))
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BearRea-model-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let note = Note(text: "# A **small** thought\n\nAn idea to keep.\n- [ ] Buy tea\n#Work/design #work/design #বাংলা/ভাবনা `#literal`\n```\n#code\n```")
        expect(note.title == "A small thought", "Readable Markdown title")
        expect(note.preview.hasPrefix("An idea to keep. Buy tea"), "Preview excludes heading and checklist syntax")
        expect(note.tags == ["Work/design", "বাংলা/ভাবনা"], "Unicode nested tags deduplicate and skip code")
        expect(note.hasTodo, "Unchecked checklist detection")
        expect(!Note(text: "- [x] Done").hasTodo, "Completed checklist is not a todo")
        expect(!Note(text: "# Example\n```markdown\n- [ ] Literal task\n```\n").hasTodo, "Tasks inside fenced code are not actionable")
        expect(Note(text: "# Example\n```markdown\n#literal\n").tags.isEmpty, "An unfinished code fence does not index tags")
        expect(Note(text: "~~~markdown\n#literal\n~~~\n#actual").tags == ["actual"], "Tilde fences do not index tags")
        expect(Note(text: "#\"quoted\"# #two words# #work/design").tags == ["\"quoted\"", "two words", "work/design"], "Closed Bear tags preserve quotes, spaces, and ordinary nested tags")
        expect(Note(text: "# Heading #\n## Another heading ##\n`#inline tag#`\n```\n#fenced tag#\n```\n#actual").tags == ["actual"], "Closed tag parsing excludes headings and code")
        expect(Note(text: "#/# #///# #work//ideas# #/work# #work/# #work/ /ideas#").tags.isEmpty, "Closed tag paths with empty components stay literal")
        expect(Note(text: "#work/ideas# #\"quoted\"#").tags == ["work/ideas", "\"quoted\""], "Valid closed paths and quoted labels remain indexed")
        let longerFence = Note(text: "~~~swift\n#literal\n- [ ] Hidden\n~~~~\n#actual\n- [ ] Visible")
        expect(longerFence.tags == ["actual"] && longerFence.hasTodo, "Longer matching fence restores tag and task indexing")
        let mismatchedFence = Note(text: "````swift\n~~~\n#literal\n```\n- [ ] Still hidden\n`````\n#actual")
        expect(mismatchedFence.tags == ["actual"] && !mismatchedFence.hasTodo, "Mismatched and shorter fences do not close a code block")
        let escapedHashes = Note(text: ##"C\#language appears in this sentence, and C\#examples appear again."## + "\n#clippings/books")
        expect(escapedHashes.tags == ["clippings/books"], "Escaped C-sharp prose cannot become a giant closed tag")
        expect(Note(text: ##"\#hidden \\#visible \\\#also-hidden"##).tags == ["visible"], "Odd backslashes escape hashes while even backslashes retain tags")
        expect(Note(text: "#first is ordinary prose before #second").tags == ["first", "second"], "An ordinary hashtag cannot terminate an earlier closed tag")
        expect(Note(text: "#two words# #\"quoted\"# #বাংলা/ভাবনা").tags == ["two words", "\"quoted\"", "বাংলা/ভাবনা"], "Closing boundary keeps quoted, multiword, and Unicode tags intact")
        expect(Note().title == "Untitled note", "Empty title fallback")
        expect(Note(text: "# ").title == "Untitled note", "Empty Markdown heading uses title fallback")
        expect(Note(text: "hello café world's").wordCount == 3, "Unicode words and apostrophes")
        expect(Note(text: "🐻é").characterCount == 2, "Grapheme character count")

        let store = NoteStore(directory: directory, seed: false)
        expect(store.notes.isEmpty, "Unseeded store starts empty")
        expect(store.lastError == nil, "Fresh persistence succeeds")
        let first = store.create(text: "# Alpha\n\nA red fox.\n- [ ] Explore\n#work/design")
        let second = store.create(text: "# Beta\n\nA blue bird.\n#work/research")
        let third = store.create(text: "# Untagged\n\nA quiet evening.")
        expect(store.filtered(section: "all").count == 3, "Create notes")
        expect(store.filtered(section: "tag:work").count == 2, "Parent tags include descendants")
        expect(store.filtered(section: "tag:WORK/design").map(\.id) == [first.id], "Case-insensitive tag matching")
        expect(store.filtered(section: "untagged").map(\.id) == [third.id], "Untagged section")
        expect(store.filtered(section: "todo").map(\.id) == [first.id], "Todo section")
        expect(store.filtered(section: "today").count == 3, "Today section")
        expect(store.filtered(section: "all", query: "red fox").map(\.id) == [first.id], "AND search terms")
        expect(store.filtered(section: "all", query: "red bird").isEmpty, "Search does not OR tokens")
        expect(store.filtered(section: "all", query: "\"red fox\" #work @todo").map(\.id) == [first.id], "Phrase, tag, and todo search compose")
        expect(store.filtered(section: "all", query: "@untagged").map(\.id) == [third.id], "Untagged search")
        store.togglePin(id: first.id)
        expect(store.filtered(section: "all").first?.id == first.id, "Pinned notes sort first")
        expect(store.filtered(section: "all", query: "@pinned").map(\.id) == [first.id], "Pinned search")
        store.togglePin(id: first.id)
        expect(store.filtered(section: "all", sort: "title").map(\.title) == ["Alpha", "Beta", "Untagged"], "Alphabetical sorting")

        store.archive(id: second.id)
        expect(store.filtered(section: "all").count == 2, "Archive removes from active notes")
        expect(store.filtered(section: "archive").map(\.id) == [second.id], "Archive section")
        expect(!store.tags.contains("work/research"), "Archived tags leave active sidebar")
        store.trash(id: second.id)
        expect(store.filtered(section: "archive").isEmpty, "Trash removes from archive")
        expect(store.filtered(section: "trash").map(\.id) == [second.id], "Trash section")
        store.restore(id: second.id)
        expect(store.filtered(section: "all").count == 3, "Restore returns note to active notes")
        let duplicate = store.duplicate(id: first.id)
        expect(duplicate?.id != first.id && duplicate?.text == first.text, "Duplicate keeps text and receives new identity")
        store.update(id: third.id, text: "# Changed\n\nNew content with #বাংলা.")
        expect(store.note(id: third.id)?.title == "Changed", "Update changes note text")
        expect(store.lastError == nil, "All normal writes succeed")
        expect(store.hasPendingChanges, "Typing is marked pending until autosave completes")
        expect(store.flush(), "Lifecycle flush persists the newest edit")
        expect(!store.hasPendingChanges, "Successful flush clears pending state")
        let reloaded = NoteStore(directory: directory, seed: false)
        expect(reloaded.notes.count == 4, "JSON reload preserves all notes")
        expect(reloaded.note(id: third.id)?.text == store.note(id: third.id)?.text, "JSON reload preserves Unicode text and identity")
        expect(reloaded.filtered(section: "all").count == 4, "JSON reload preserves restored state")

        // Save once more so the backup contains the latest valid data, then corrupt
        // the primary file. Recovery must not destroy evidence of the original file.
        expect(store.save(), "Explicit save succeeds")
        let corrupt = Data("not a notes file".utf8)
        try corrupt.write(to: store.storageURL, options: .atomic)
        let recovered = NoteStore(directory: directory, seed: false)
        expect(recovered.notes.count == 4, "Corrupt primary recovers last-good backup")
        expect(recovered.lastError?.contains("Recovered") == true, "Recovery is surfaced")
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes.corrupt-") }
        expect(preserved.count == 1, "Corrupt source is preserved separately")
        let preservedData = try Data(contentsOf: preserved[0])
        expect(preservedData == corrupt, "Preserved corruption is byte-for-byte intact")
        expect(NoteStore(directory: directory, seed: false).notes.count == 4, "Recovered primary is readable")

        let malformedDirectory = directory.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try corrupt.write(to: malformedDirectory.appendingPathComponent("notes.json"))
        let noBackup = NoteStore(directory: malformedDirectory, seed: false)
        expect(noBackup.notes.isEmpty && noBackup.lastError != nil, "Corruption without backup reports error safely")

        let blockedDirectory = directory.appendingPathComponent("a-file")
        try Data("occupied".utf8).write(to: blockedDirectory)
        let blocked = NoteStore(directory: blockedDirectory, seed: false)
        expect(blocked.lastError != nil, "Unwritable destination error is visible")
        _ = blocked.create(text: "Keep this in memory")
        expect(blocked.notes.count == 1 && blocked.lastError != nil, "Failed save retains in-memory edit")

        let seeded = NoteStore(directory: directory.appendingPathComponent("demo"))
        expect(seeded.notes.count == 6, "Six original demonstration notes")
        expect(seeded.filtered(section: "all").first?.title == "Welcome to Sloth", "Welcome is pinned first")
        let syncStore = NoteStore(directory: directory.appendingPathComponent("sync-model"), seed: false)
        let original = syncStore.create(text: "Before sync")
        let baseline = syncStore.notes
        var remote = original; remote.text = "Remote edit"
        syncStore.update(id: original.id, text: "Typed while syncing")
        expect(!syncStore.applySyncedNotes([remote], baseline: baseline), "Stale sync cannot overwrite a recent local edit")
        expect(syncStore.note(id: original.id)?.text == "Typed while syncing", "Local edit remains after rejected merge")
        expect(syncStore.applySyncedNotes([remote], baseline: syncStore.notes), "Current sync baseline can apply")
        expect(NoteStore(directory: directory.appendingPathComponent("sync-model"), seed: false).notes.first?.text == "Remote edit", "Applied remote content survives restart")
        expect(!syncStore.applySyncedNotes([remote, remote], baseline: syncStore.notes), "Duplicate remote identities rejected")
        // Sidebar metadata and query caches must invalidate just the changed note.
        let cachedStore = NoteStore(directory: directory.appendingPathComponent("cached"), seed: false)
        let indexed = cachedStore.create(text: "# Original\n\n- [ ] Task\n#work/design #work/research")
        let other = cachedStore.create(text: "# Other\n\nA second note. #personal")
        let originalMetadata = cachedStore.metadata(for: indexed)
        let otherMetadata = cachedStore.metadata(for: other)
        expect(originalMetadata.title == "Original" && originalMetadata.hasTodo, "Cached metadata exposes title and task")
        expect(cachedStore.sectionCounts["tag:work"] == 1, "Parent tag counts deduplicate sibling tags on one note")
        expect(cachedStore.filtered(section: "todo").count == 1, "Task query can be cached")
        cachedStore.update(id: indexed.id, text: "# Changed\n\n- [x] Done\n#personal")
        let changed = cachedStore.note(id: indexed.id)!
        expect(cachedStore.metadata(for: changed) !== originalMetadata, "Text edit invalidates its metadata")
        expect(cachedStore.metadata(for: other) === otherMetadata, "Text edit preserves unrelated metadata")
        expect(cachedStore.filtered(section: "todo").isEmpty, "Text edit invalidates filtered task results")
        expect(cachedStore.sectionCounts["tag:work"] == nil && cachedStore.sectionCounts["tag:personal"] == 2, "Sidebar index reflects edited tags")
        cachedStore.archive(id: other.id)
        expect(cachedStore.sectionCounts["archive"] == 1 && cachedStore.sectionCounts["tag:personal"] == 1, "Archive invalidates sidebar membership")
        cachedStore.togglePin(id: indexed.id)
        expect(cachedStore.filtered(section: "pinned").map(\.id) == [indexed.id], "Pinned section is indexed")
        expect(cachedStore.sectionCounts["pinned"] == 1, "Pinned sidebar count is correct")

        let quotedTagNote = cachedStore.create(text: "# Tags\n\n#\"quoted\"# #two words#")
        expect(cachedStore.filtered(section: "tag:\"quoted\"").map(\.id) == [quotedTagNote.id], "Quoted Bear tag section preserves the literal label")
        expect(cachedStore.filtered(section: "all", query: "#\"quoted\"#").map(\.id) == [quotedTagNote.id], "Quoted Bear tag search preserves literal quotes")
        expect(cachedStore.filtered(section: "all", query: "#two words#").map(\.id) == [quotedTagNote.id], "Closed multiword tag is one search term")
        expect(cachedStore.sectionCounts["tag:\"quoted\""] == 1, "Quoted tag has a sidebar count")

        let malformedTagNote = cachedStore.create(text: "# Invalid paths\n#/# #///# #a//b#")
        expect(!cachedStore.tags.contains("/") && !cachedStore.tags.contains("///"), "Slash-only tags do not reach sidebar labels")
        expect(cachedStore.sectionCounts["tag:/"] == nil && cachedStore.sectionCounts["tag:///"] == nil, "Malformed closed tags cannot crash ancestor counts")
        expect(cachedStore.filtered(section: "untagged").contains { $0.id == malformedTagNote.id }, "Only malformed tags leaves a note untagged")
        let batchStore = NoteStore(directory: directory.appendingPathComponent("batch"), seed: false)
        let batch = batchStore.createBatch(texts: ["# First\n#batch", "# Second\n- [ ] Task"])
        expect(batch.map(\.title) == ["First", "Second"] && batchStore.notes.map(\.id) == batch.map(\.id), "Batch import preserves supplied order and all identities")
        expect(batchStore.note(id: batch[1].id)?.text == batch[1].text && batchStore.sectionCounts["all"] == 2, "Batch import updates note lookup and sidebar counts")
        expect(batchStore.flush() && NoteStore(directory: directory.appendingPathComponent("batch"), seed: false).notes.count == 2, "Batch import persists every note")
        expect(batchStore.createBatch(texts: []).isEmpty && !batchStore.hasPendingChanges, "Empty batch does not dirty the library")

        // A burst of typing does no disk I/O on the calling thread. The one
        // delayed background save persists the final revision, including Unicode.
        let asyncDirectory = directory.appendingPathComponent("autosave")
        let asyncStore = NoteStore(directory: asyncDirectory, seed: false)
        let diskBefore = try Data(contentsOf: asyncStore.storageURL)
        let asyncNote = asyncStore.create(text: "Initial")
        var completedSaves = 0
        asyncStore.onPersistenceChange = { completedSaves += 1 }
        for index in 0..<40 { asyncStore.update(id: asyncNote.id, text: "শেষ edit \(index)") }
        let diskDuringBurst = try Data(contentsOf: asyncStore.storageURL)
        expect(diskDuringBurst == diskBefore, "Typing burst leaves disk I/O to the delayed writer")
        expect(asyncStore.hasPendingChanges, "Typing burst reports unsaved changes")
        let deadline = Date().addingTimeInterval(3)
        while asyncStore.hasPendingChanges && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(!asyncStore.hasPendingChanges && asyncStore.lastError == nil, "Background autosave completes successfully")
        expect(completedSaves == 1, "Rapid edits coalesce to one completed save")
        expect(NoteStore(directory: asyncDirectory, seed: false).note(id: asyncNote.id)?.text == "শেষ edit 39", "Autosave persists newest Unicode revision")
        asyncStore.update(id: asyncNote.id, text: "Flush immediately before the debounce")
        expect(asyncStore.flush(), "Flush bypasses debounce")
        expect(NoteStore(directory: asyncDirectory, seed: false).note(id: asyncNote.id)?.text == "Flush immediately before the debounce", "Flush is durable before returning")
        let callbacksAfterFlush = completedSaves
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        expect(completedSaves == callbacksAfterFlush, "Cancelled autosave cannot rewrite after flush")

        // Continuous typing still checkpoints at least every two seconds.
        let continuousStore = NoteStore(directory: directory.appendingPathComponent("continuous"), seed: false)
        let continuousNote = continuousStore.create(text: "Start")
        for index in 0..<30 {
            continuousStore.update(id: continuousNote.id, text: "Still typing \(index)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        let continuousCheckpoint = NoteStore(directory: directory.appendingPathComponent("continuous"), seed: false)
        expect(continuousCheckpoint.note(id: continuousNote.id)?.text.hasPrefix("Still typing") == true, "Continuous typing cannot postpone autosave indefinitely")
        expect(continuousStore.flush(), "Continuous typing final revision flushes")

        let releaseDirectory = directory.appendingPathComponent("release")
        var releasedStore: NoteStore? = NoteStore(directory: releaseDirectory, seed: false)
        let releasedNote = releasedStore!.create(text: "Retained when store is released")
        releasedStore = nil
        expect(NoteStore(directory: releaseDirectory, seed: false).note(id: releasedNote.id)?.text == releasedNote.text, "Releasing a store flushes a pending edit")

        // Write failures retain the edit and are retryable after the cause clears.
        let retryDirectory = directory.appendingPathComponent("retry")
        let retryStore = NoteStore(directory: retryDirectory, seed: false)
        let retryNote = retryStore.create(text: "Retain me")
        try FileManager.default.removeItem(at: retryDirectory)
        try Data("blocked".utf8).write(to: retryDirectory)
        expect(!retryStore.flush() && retryStore.hasPendingChanges && retryStore.lastError != nil, "Failed flush retains dirty state and reports failure")
        try FileManager.default.removeItem(at: retryDirectory)
        expect(retryStore.flush() && !retryStore.hasPendingChanges, "Failed save can be retried")
        expect(NoteStore(directory: retryDirectory, seed: false).note(id: retryNote.id)?.text == "Retain me", "Retry preserves original note identity and text")
        let beforeFailedMerge = retryStore.notes
        var rejectedRemote = retryNote
        rejectedRemote.text = "Remote content that cannot be saved"
        try FileManager.default.removeItem(at: retryDirectory)
        try Data("blocked again".utf8).write(to: retryDirectory)
        expect(!retryStore.applySyncedNotes([rejectedRemote], baseline: beforeFailedMerge), "Unsavable sync merge is rejected")
        expect(retryStore.notes == beforeFailedMerge && retryStore.hasPendingChanges, "Failed sync retains prior library for retry")
        try FileManager.default.removeItem(at: retryDirectory)
        expect(retryStore.flush(), "Library can be saved after failed sync cause clears")
        let identitySnapshot = retryStore.notes
        let originalBytes = try Data(contentsOf: retryStore.storageURL)
        expect(retryStore.applySyncedNotes(identitySnapshot, baseline: identitySnapshot), "Unchanged sync succeeds without rewriting")
        let unchangedBytes = try Data(contentsOf: retryStore.storageURL)
        expect(unchangedBytes == originalBytes, "Unchanged sync preserves file bytes")

        let longNote = Note(text: "# Fast title\n" + String(repeating: "A small line of preview text.\n", count: 10_000))
        expect(longNote.title == "Fast title" && longNote.preview.count == 220, "Large document preview stops after its visible excerpt")
        if ProcessInfo.processInfo.environment["SLOTH_BENCHMARK"] == "1" {
            try benchmark(directory: directory.appendingPathComponent("benchmark"))
        }
        print("Passed \(assertions) model assertions.")
    }
}
