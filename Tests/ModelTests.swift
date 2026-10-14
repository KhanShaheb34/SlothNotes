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
        print("Passed \(assertions) model assertions.")
    }
}
