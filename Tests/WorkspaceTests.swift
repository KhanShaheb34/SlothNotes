import AppKit

/// Native view snapshots and layout checks use an isolated library and never
/// launch Sloth or load the user's Bear/Sloth data.
@main enum WorkspaceTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
    static func waitForSync(_ sync: CloudSyncController, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(condition(), "Temporary-folder sync completes within its retry deadline: \(sync.status.message)")
    }

    static func openTableCell(_ controller: AppController) -> MarkdownTableCellEditor {
        let editor = controller.editor
        editor.restoreScrollPosition(.zero)
        editor.layoutSubtreeIfNeeded()
        guard let storage = editor.textView.textStorage, let manager = editor.textView.layoutManager,
              let container = editor.textView.textContainer else { fatalError("Missing native editor layout") }
        manager.ensureLayout(for: container)
        var tableCell: MarkdownTableAttachmentCell?
        var tableRange = NSRange()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let attachment = value as? NSTextAttachment, let cell = attachment.attachmentCell as? MarkdownTableAttachmentCell {
                tableCell = cell; tableRange = range; stop.pointee = true
            }
        }
        guard let tableCell else { fatalError("Missing rendered table") }
        let glyphs = manager.glyphRange(forCharacterRange: tableRange, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        guard let cell = tableCell.cellFrame(row: 1, column: 0, in: bounds) else { fatalError("Missing table body cell") }
        let point = NSPoint(x: cell.midX + editor.textView.textContainerOrigin.x, y: cell.midY + editor.textView.textContainerOrigin.y)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.textView.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: controller.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        editor.textView.mouseDown(with: event)
        guard let field = editor.textView.subviews.compactMap({ $0 as? MarkdownTableCellEditor }).first else {
            fatalError("Native table click did not open its cell editor")
        }
        return field
    }

    static func verifySyncPreservesTableDraft(_ controller: AppController, directory: URL) throws {
        let original = "# Synced table\n\n| Work | State |\n| --- | --- |\n| Original | Ready |\n"
        let note = controller.store.create(text: original)
        controller.section = "all"; controller.selectedID = note.id; controller.refresh()
        // Obtain the real application callbacks without starting default iCloud.
        let arguments = controller.defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var disabledCloud = arguments
        disabledCloud["icloudEnabled"] = false
        controller.defaults.setVolatileDomain(disabledCloud, forName: UserDefaults.argumentDomain)
        controller.configureSync(directory: directory)
        controller.defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        guard let configured = controller.cloud else { fatalError("Application sync was not configured") }

        let shared = directory.appendingPathComponent("test-shared-cloud", isDirectory: true)
        let remote = directory.appendingPathComponent("test-remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let engine = CloudSync(localDirectory: directory, cloudDirectory: shared)
        let baseline = controller.store.notes
        let initial = try engine.sync(notes: baseline)
        expect(configured.apply?(initial.notes, baseline) == true, "Initial folder sync applies through the application callback")
        try engine.commit(initial)
        let remoteEngine = CloudSync(localDirectory: remote, cloudDirectory: shared)
        let imported = try remoteEngine.sync(notes: [])
        try remoteEngine.commit(imported)
        var remoteNotes = imported.notes
        let remoteIndex = remoteNotes.firstIndex { $0.id == note.id }!
        remoteNotes[remoteIndex].text += "\nRemote addition.\n"
        remoteNotes[remoteIndex].modifiedAt = Date().addingTimeInterval(1)
        let published = try remoteEngine.sync(notes: remoteNotes)
        try remoteEngine.commit(published)

        let field = openTableCell(controller)
        field.stringValue = "Local cell draft"
        expect(!controller.editor.textView.hasMarkedText(), "Table draft exists independently of the main editor's input method")
        let sync = CloudSyncController(engine: engine)
        sync.snapshot = configured.snapshot
        sync.apply = configured.apply
        controller.cloud = sync
        defer { sync.stop() }
        sync.start()
        waitForSync(sync) {
            switch sync.status { case .error, .ready: return true; default: return false }
        }
        let deferred: Bool
        if case .error = sync.status { deferred = true } else { deferred = false }
        expect(deferred, "Incoming same-note sync defers while a native table cell has an uncommitted draft")
        expect(controller.store.note(id: note.id)?.text == original && controller.editor.text == original,
               "Deferred sync leaves both the store and editor at their last committed note")
        expect(field.superview != nil && field.stringValue == "Local cell draft", "Deferred sync leaves the native cell draft editable")
        controller.editor.finishPendingComposition()
        expect(controller.store.note(id: note.id)?.text.contains("| Local cell draft |") == true, "Ending the cell edit saves its draft before sync retry")
        waitForSync(sync) { if case .ready = sync.status { return true }; return false }
        expect(controller.store.notes.contains { $0.text.contains("Local cell draft") }, "Scheduled retry preserves the local table draft")
        expect(controller.store.notes.contains { $0.text.contains("Remote addition.") }, "Scheduled retry preserves the concurrent remote version")
        expect(controller.editor.text == controller.selectedID.flatMap { controller.store.note(id: $0)?.text },
               "After retry the visible editor agrees with its stored note")
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sloth-workspace-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController()
        controller.store = NoteStore(directory: directory)
        controller.attachments = AttachmentStore(directory: directory)
        controller.setupWindow(); controller.setupMenus(); controller.buildSidebar(); controller.refresh(); controller.applyTheme()
        controller.root.frame = NSRect(x: 0, y: 0, width: 1250, height: 800)
        controller.layout(); controller.root.layoutSubtreeIfNeeded()
        let selected = controller.selectedID
        let originalButtons = controller.sidebarButtons.map(ObjectIdentifier.init)
        controller.buildSidebar()
        expect(originalButtons == controller.sidebarButtons.map(ObjectIdentifier.init), "Unchanged sidebar reuses native controls")
        expect(controller.editor.frame.maxY < controller.formatBar.frame.minY, "Formatting toolbar cannot cover note text")
        expect(controller.formatBar.frame.maxY < controller.status.frame.minY, "Toolbar and save status do not overlap")
        expect(controller.visible.count == 6, "Native list loads demo library")
        let snapshotDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/visual-review", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try snapshot(controller.root, to: snapshotDirectory.appendingPathComponent("sloth-light.png"))
        Palette.dark = true; controller.applyTheme()
        expect(controller.selectedID == selected, "Theme changes preserve selected note")
        try snapshot(controller.root, to: snapshotDirectory.appendingPathComponent("sloth-dark.png"))
        controller.window.setContentSize(NSSize(width: 850, height: 520)); controller.root.frame.size = NSSize(width: 850, height: 520); controller.layout(); controller.root.layoutSubtreeIfNeeded()
        expect(controller.formatBar.frame.minX >= 0 && controller.formatBar.frame.maxX <= controller.editorPane.bounds.width, "Toolbar fits minimum window width")
        expect(controller.formatButtons.allSatisfy { $0.frame.maxX <= controller.formatBar.bounds.width }, "Every formatting control fits at minimum width")
        expect(controller.editor.frame.width > 300 && controller.editor.frame.height > 300, "Minimum window retains usable editing area")
        try snapshot(controller.root, to: snapshotDirectory.appendingPathComponent("sloth-compact.png"))
        controller.window.setContentSize(NSSize(width: 1250, height: 1000)); controller.root.frame.size = NSSize(width: 1250, height: 1000); controller.layout()
        Palette.dark = false; controller.applyTheme()
        let icon = try controller.attachments.importFile(URL(fileURLWithPath: "Resources/Sloth.png"))
        let pdf = try controller.attachments.importFile(URL(fileURLWithPath: "Tests/Fixtures/Sloth attachment preview.pdf"))
        let attachmentNote = controller.store.create(text: "# A place for the little things\n\nKeep ideas, plans, and useful files together.\n\n- [x] Make a little space\n- [ ] Follow a thought\n- [ ] \n\n" + icon.markdown + "\n\n" + pdf.markdown)
        controller.selectedID = attachmentNote.id; controller.refresh(); controller.buildSidebar()
        controller.table.layoutSubtreeIfNeeded()
        for row in controller.visible.indices { _ = controller.table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        expect(controller.editor.renderedAttachmentCount == 5, "Workspace renders image, file and visual tasks together")
        try snapshot(controller.root, to: snapshotDirectory.appendingPathComponent("sloth-attachments.png"))
        let target = controller.store.create(text: "# Linked note\n\nA linked destination.")
        expect(controller.openNoteLink("Linked note"), "Wiki links are handled within Sloth")
        expect(controller.selectedID == target.id, "Wiki link opens the matching note")
        controller.store.archive(id: target.id)
        _ = controller.openNoteLink("Linked note")
        expect(controller.section == "archive" && controller.selectedID == target.id, "Wiki links can open archived notes")
        // Updates to the same document preserve reading position, including
        // when a background sync supplies changed text.
        let long = controller.store.create(text: "# A long note\n\n" + String(repeating: "A paragraph to read while keeping your place.\n\n", count: 150))
        controller.section = "all"; controller.selectedID = long.id; controller.refresh()
        controller.editor.selectSourceRange(NSRange(location: 350, length: 4), scroll: false)
        controller.editor.restoreScrollPosition(NSPoint(x: 0, y: 400))
        let readingPosition = controller.editor.scrollPosition
        controller.store.update(id: long.id, text: long.text + "Remote addition.\n")
        controller.refresh()
        expect(controller.editor.selectedSourceRange == NSRange(location: 350, length: 4), "Same-note update preserves selection")
        expect(abs(controller.editor.scrollPosition.y - readingPosition.y) < 2, "Same-note update preserves reading viewport")
        controller.editor.selectSourceRange(NSRange(location: 0, length: 0), scroll: false)
        controller.editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.selectedID = target.id; controller.section = "archive"; controller.refresh()
        expect(controller.store.note(id: long.id)?.text.hasPrefix("日本") == true, "Switching documents commits IME to outgoing note")
        expect(controller.store.note(id: target.id)?.text.hasPrefix("# Linked") == true, "IME cannot leak into newly selected note")
        controller.store.trash(id: target.id); controller.section = "trash"; controller.refresh()
        controller.showStyles = false; controller.toggleStyles()
        expect(controller.formatBar.isHidden, "Styles toggle cannot expose editing controls in Trash")
        try verifySyncPreservesTableDraft(controller, directory: directory)
        controller.setupMenus()
        let formatMenu = NSApp.mainMenu?.item(withTitle: "Format")?.submenu
        expect(formatMenu?.item(withTitle: "Toggle Folding")?.keyEquivalent == "'", "Format menu exposes the familiar folding shortcut")
        expect(formatMenu?.item(withTitle: "Fold All Headings") != nil && formatMenu?.item(withTitle: "Unfold All Headings") != nil, "Bulk folding is discoverable in the Format menu")
        expect(controller.store.flush(), "Workspace test library saves")
        controller.window.delegate = nil; controller.window.orderOut(nil)
        print("Passed \(assertions) workspace assertions; native view snapshots: \(snapshotDirectory.path)")
    }
}
