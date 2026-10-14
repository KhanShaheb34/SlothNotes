import Foundation

@main
enum SyncTests {
    static var assertions = 0
    static let manager = FileManager.default

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func expectThrows(_ message: String, _ operation: () throws -> Void) {
        assertions += 1
        do { try operation(); fputs("FAIL: \(message)\n", stderr); exit(1) } catch { }
    }

    static func sync(_ engine: CloudSync, _ notes: inout [Note], attachments: URL? = nil) throws -> CloudSyncResult {
        let result = try engine.sync(notes: notes, attachmentsDirectory: attachments)
        notes = result.notes
        try engine.commit(result)
        return result
    }

    static func directory(_ root: URL, _ name: String) throws -> URL {
        let result = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    static func main() throws {
        let root = try directory(manager.temporaryDirectory, "Sloth-sync-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let shared = try directory(root, "iCloud-Sloth")
        let localA = try directory(root, "device-A")
        let localB = try directory(root, "device-B")
        let a = CloudSync(localDirectory: localA, cloudDirectory: shared)
        let b = CloudSync(localDirectory: localB, cloudDirectory: shared)
        let original = Note(text: "# Shared\n\nOriginal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        var notesA = [original]
        var notesB: [Note] = []
        _ = try sync(a, &notesA)
        _ = try sync(b, &notesB)
        expect(notesB == notesA, "Second device imports an initial note")
        expect(notesB[0].id == original.id, "Transport preserves note identity")

        notesB[0].text = "# Shared\n\nEdited on B"
        notesB[0].modifiedAt = Date(timeIntervalSince1970: 1_700_000_001)
        _ = try sync(b, &notesB)
        _ = try sync(a, &notesA)
        expect(notesA == notesB, "Two-way edit returns from B to A")
        expect(notesA.count == 1, "Sequential edit produces no conflict copy")

        // Both devices edit the same applied version before observing each other.
        notesA[0].text = "# Shared\n\nOffline edit A"
        notesA[0].modifiedAt = Date(timeIntervalSince1970: 1_700_000_002.9)
        notesB[0].text = "# Shared\n\nOffline edit B"
        notesB[0].modifiedAt = Date(timeIntervalSince1970: 1_700_000_002.1)
        _ = try sync(a, &notesA)
        let conflict = try sync(b, &notesB)
        expect(conflict.conflictCount == 1, "Concurrent changes produce a conflict copy")
        expect(notesB.count == 2, "Both concurrent versions remain accessible")
        expect(notesB.contains { $0.text.contains("Offline edit A") }, "A's concurrent edit survives")
        expect(notesB.contains { $0.text.contains("Offline edit B") }, "B's concurrent edit survives")
        expect(notesB.contains { $0.title.contains("conflict copy") }, "Conflict is named visibly")
        _ = try sync(a, &notesA)
        _ = try sync(b, &notesB)
        expect(Set(notesA.map(\.id)) == Set(notesB.map(\.id)), "Conflict identities converge")
        expect(Dictionary(uniqueKeysWithValues: notesA.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: notesB.map { ($0.id, $0) }), "Conflict contents converge despite subsecond timestamps")
        expect(notesA.count == 2, "Repeated reconciliation does not multiply conflicts")

        // A new process reads its checkpoint rather than declaring every note new.
        let reloadedA = CloudSync(localDirectory: localA, cloudDirectory: shared)
        _ = try sync(reloadedA, &notesA)
        expect(notesA.count == 2, "Restart preserves revision ancestry")
        notesA[notesA.firstIndex { $0.id == original.id }!].trashed = true
        notesA[notesA.firstIndex { $0.id == original.id }!].modifiedAt = Date(timeIntervalSince1970: 1_700_000_005)
        _ = try sync(reloadedA, &notesA)
        _ = try sync(b, &notesB)
        expect(notesB.first { $0.id == original.id }?.trashed == true, "Trash is propagated as soft state")
        notesB[notesB.firstIndex { $0.id == original.id }!].trashed = false
        notesB[notesB.firstIndex { $0.id == original.id }!].modifiedAt = Date(timeIntervalSince1970: 1_700_000_006)
        _ = try sync(b, &notesB)
        _ = try sync(reloadedA, &notesA)
        expect(notesA.first { $0.id == original.id }?.trashed == false, "Restore propagates after trash")

        let attachmentA = try directory(localA, "attachments")
        let attachmentB = try directory(localB, "attachments")
        let attachmentName = "\(UUID().uuidString).png"
        let imageBytes = Data([0, 1, 2, 3, 4, 5, 200, 255])
        try imageBytes.write(to: attachmentA.appendingPathComponent(attachmentName))
        notesA.append(Note(text: "# Image\n\n![An image](attachments/\(attachmentName))"))
        _ = try sync(reloadedA, &notesA)
        _ = try sync(b, &notesB)
        expect(tryData(attachmentB.appendingPathComponent(attachmentName)) == imageBytes, "Attachment bytes arrive on the second device")
        expect(notesB.contains { $0.text.contains(attachmentName) }, "Attachment Markdown arrives with its note")
        expect(tryData(attachmentA.appendingPathComponent(attachmentName)) == imageBytes, "Original local attachment remains intact")
        try Data("different".utf8).write(to: attachmentB.appendingPathComponent(attachmentName))
        expectThrows("Different bytes at an immutable attachment name stop sync") { _ = try b.sync(notes: notesB) }
        expect(tryData(attachmentA.appendingPathComponent(attachmentName)) == imageBytes, "Attachment collision never overwrites A")
        expect(tryData(shared.appendingPathComponent("attachments").appendingPathComponent(attachmentName)) == imageBytes, "Attachment collision never overwrites cloud")
        expect(tryData(attachmentB.appendingPathComponent(attachmentName)) == Data("different".utf8), "Attachment collision preserves B's differing file")
        try imageBytes.write(to: attachmentB.appendingPathComponent(attachmentName))

        let beforeOffline = notesA
        let away = root.appendingPathComponent("disconnected-cloud")
        try manager.moveItem(at: shared, to: away)
        expectThrows("Unavailable folder is an error") { _ = try reloadedA.sync(notes: notesA) }
        expect(notesA == beforeOffline, "Offline error leaves local notes unchanged")
        expect(!manager.fileExists(atPath: shared.path), "Offline folder is not silently recreated")
        notesA.append(Note(text: "# Offline new note"))
        try manager.moveItem(at: away, to: shared)
        _ = try sync(reloadedA, &notesA)
        _ = try sync(b, &notesB)
        expect(notesB.contains { $0.title == "Offline new note" }, "Offline edits publish after reconnection")

        let malformedDirectory = shared.appendingPathComponent("revisions").appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        let malformed = malformedDirectory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: malformed)
        let beforeMalformed = notesA
        expectThrows("Malformed remote revision stops import") { _ = try reloadedA.sync(notes: notesA) }
        expect(notesA == beforeMalformed, "Malformed remote data does not damage local notes")
        expect(tryData(malformed) == Data("broken".utf8), "Malformed cloud evidence is preserved")
        try manager.removeItem(at: malformedDirectory)

        let absent = Note(text: "# Pending\n![Wait](attachments/missing.png)")
        expectThrows("Referenced missing attachment reports pending") { _ = try reloadedA.sync(notes: notesA + [absent]) }
        expect(!manager.fileExists(atPath: shared.appendingPathComponent("revisions/\(absent.id.uuidString)").path), "Note is not published before its attachment")

        // An uncommitted preparation cannot move the local ancestry checkpoint.
        let held = Note(text: "# Held back")
        let prepared = try reloadedA.sync(notes: notesA + [held])
        expect(prepared.notes.contains { $0.id == held.id }, "Prepared updates are explicit values")
        let again = try reloadedA.sync(notes: notesA)
        expect(again.notes.contains { $0.id == held.id }, "Published revision survives rejected local application")

        // Device with the same note and no prior checkpoint must not create noise.
        let localC = try directory(root, "device-C")
        let c = CloudSync(localDirectory: localC, cloudDirectory: shared)
        var notesC = notesA
        _ = try sync(c, &notesC)
        expect(notesC.filter { $0.title.contains("conflict copy") }.count == 1, "Identical first-sync content adds no conflict")

        let symlink = attachmentA.appendingPathComponent("unsafe.png")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: attachmentA.appendingPathComponent(attachmentName))
        expectThrows("Symlink attachments are rejected") { _ = try reloadedA.sync(notes: notesA) }
        try manager.removeItem(at: symlink)

        // Deleting a local row is not a cloud purge. Only explicit trash travels.
        var empty: [Note] = []
        let localD = try directory(root, "device-D")
        let d = CloudSync(localDirectory: localD, cloudDirectory: shared)
        _ = try sync(d, &empty)
        let originalCount = empty.count
        empty = []
        _ = try sync(d, &empty)
        expect(empty.count == originalCount, "Absent local rows never hard-delete remote history")
        expect(CloudSyncStatus.ready(Date()).message == "iCloud Drive folder updated", "Status does not claim delivery to other devices")
        // iCloud can evict, delay, or lose a revision. A local checkpoint is not
        // permission to discard a note whose remote head is currently absent.
        let repairCloud = try directory(root, "repair-cloud")
        let repairLocal = try directory(root, "repair-local")
        let repair = CloudSync(localDirectory: repairLocal, cloudDirectory: repairCloud)
        var repairNotes = [Note(text: "# Earlier", createdAt: Date(timeIntervalSince1970: 100))]
        _ = try sync(repair, &repairNotes)
        repairNotes[0].text = "# Latest local content"
        repairNotes[0].modifiedAt = Date(timeIntervalSince1970: 200)
        _ = try sync(repair, &repairNotes)
        let revisionFolder = repairCloud.appendingPathComponent("revisions/\(repairNotes[0].id.uuidString)")
        for file in try manager.contentsOfDirectory(at: revisionFolder, includingPropertiesForKeys: nil) {
            if String(data: try Data(contentsOf: file), encoding: .utf8)?.contains("Latest local content") == true {
                try manager.removeItem(at: file)
            }
        }
        _ = try sync(repair, &repairNotes)
        expect(repairNotes.first { $0.title == "Latest local content" } != nil, "Missing applied head cannot roll back newer local contents")
        let repairedIDs = Set(repairNotes.map(\.id))
        try manager.removeItem(at: repairCloud.appendingPathComponent("revisions"))
        _ = try sync(repair, &repairNotes)
        expect(Set(repairNotes.map(\.id)) == repairedIDs, "Missing entire remote history cannot drop local notes")
        expect(repairNotes.contains { $0.title == "Latest local content" }, "Local content survives missing entire remote history")

        let examples = Note(text: "# Markdown examples\n`![Example](attachments/missing.png)`\n```markdown\n![Example](attachments/missing.png)\n```\n")
        let exampleResult = try repair.sync(notes: repairNotes + [examples])
        expect(exampleResult.notes.contains { $0.id == examples.id }, "Code examples with attachment syntax do not block sync")
        let titled = Note(text: "# Pending title\n![Missing](<attachments/not-yet.png>)")
        expectThrows("Angle-wrapped missing attachment reports pending") { _ = try repair.sync(notes: repairNotes + [titled]) }

        let malformedParentDir = try directory(repairCloud.appendingPathComponent("revisions"), UUID().uuidString)
        let malformedParent = malformedParentDir.appendingPathComponent("bad.json")
        try Data("{\"schemaVersion\":1,\"parents\":[\"not-a-digest\"]}".utf8).write(to: malformedParent)
        expectThrows("Malformed graph parent record is rejected") { _ = try repair.sync(notes: repairNotes) }
        try manager.removeItem(at: malformedParentDir)

        let validRevision = try manager.contentsOfDirectory(at: repairCloud.appendingPathComponent("revisions/\(repairNotes[0].id.uuidString)"), includingPropertiesForKeys: nil)[0]
        let linkedNoteDir = try directory(repairCloud.appendingPathComponent("revisions"), UUID().uuidString)
        let linkedRevision = linkedNoteDir.appendingPathComponent("linked.json")
        try manager.createSymbolicLink(at: linkedRevision, withDestinationURL: validRevision)
        expectThrows("Revision symlinks are rejected before file contents are read") { _ = try repair.sync(notes: repairNotes) }
        try manager.removeItem(at: linkedNoteDir)
        let controllerCloud = try directory(root, "controller-cloud")
        let controllerLocal = try directory(root, "controller-local")
        let controller = CloudSyncController(engine: CloudSync(localDirectory: controllerLocal, cloudDirectory: controllerCloud))
        var controllerNotes = [Note(text: "# Controller baseline")]
        var rejectApply = true
        var rejected = false
        var ready = false
        controller.snapshot = { controllerNotes }
        controller.apply = { result, baseline in
            guard !rejectApply, baseline == controllerNotes else { rejected = true; return false }
            controllerNotes = result
            return true
        }
        controller.onUpdate = { if case .ready = $0 { ready = true } }
        controller.start()
        expect(runUntil { rejected }, "Controller detects failed baseline application")
        expect(!ready, "Controller cannot report folder updated before local save succeeds")
        expect(controllerNotes.count == 1 && controllerNotes[0].title == "Controller baseline", "Rejected application preserves current notes")
        rejectApply = false
        controller.syncNow()
        expect(runUntil { ready }, "Controller reports success after accepted local save and checkpoint")
        controller.stop()
        expect(controller.status.message == "iCloud Drive is off", "Stop cancels periodic updates and clears ready status")

        let stopped = CloudSyncController(engine: CloudSync(localDirectory: try directory(root, "stopped-controller"), cloudDirectory: controllerCloud))
        var appliedAfterStop = false
        stopped.snapshot = { [] }
        stopped.apply = { _, _ in appliedAfterStop = true; return true }
        stopped.start()
        stopped.stop()
        _ = runUntil(timeout: 0.3) { appliedAfterStop }
        expect(!appliedAfterStop, "An in-flight result does not apply after sync is disabled")
        print("Passed \(assertions) sync assertions (isolated folders; no real iCloud writes).")
    }

    static func runUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
