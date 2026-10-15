import AppKit

@main struct FileOperationTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("File operation test failed: " + message) }
    }
    static func wait(_ app: AppController) {
        let deadline = Date().addingTimeInterval(10)
        while app.pendingFileOperations > 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(app.pendingFileOperations == 0, "asynchronous file operations complete")
        expect(app.fileOperationStatus == nil, "completed operation status clears")
    }
    static func select(_ note: Note, in app: AppController) {
        app.selectedID = note.id; app.displayedID = note.id; app.editor.setText(note.text)
    }
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sloth-file-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppController()
        app.store = NoteStore(directory: root.appendingPathComponent("library"), seed: false)
        app.attachments = AttachmentStore(directory: root.appendingPathComponent("library"))
        app.setupWindow()
        let original = app.store.create(text: "# Original\n\nStart End\n")
        select(original, in: app)
        let file = root.appendingPathComponent("Example.txt")
        try Data("Complete immutable bytes".utf8).write(to: file)
        let caret = (original.text as NSString).range(of: "End").location
        app.editor.selectSourceRange(NSRange(location: caret, length: 0), scroll: false)
        let returned = app.importAttachmentFiles([file])
        expect(returned.isEmpty, "paste returns immediately without temporary text")
        expect(app.pendingFileOperations == 1, "pending copy is exposed before main completion")
        expect(app.store.note(id: original.id)?.text == original.text, "original remains intact until copy completes")
        wait(app)
        let inserted = app.store.note(id: original.id)!.text
        expect(inserted.contains("Start \n[Example.txt](attachments/"), "unchanged note inserts at captured caret")
        expect(inserted.hasSuffix("\nEnd\n"), "original suffix survives captured insertion")
        let firstReference = app.attachments.references(in: inserted).first!
        let originalBytes = try Data(contentsOf: file)
        let importedBytes = try Data(contentsOf: app.attachments.resolve(firstReference.path)!)
        expect(importedBytes == originalBytes, "attachment is complete before publication")

        let edited = app.store.create(text: "# Edited\n\nBefore copy")
        select(edited, in: app)
        app.editor.selectSourceRange(NSRange(location: 0, length: 8), scroll: false)
        _ = app.importAttachmentFiles([file])
        let newerText = "# Edited\n\nTyping while copying survives 👋"
        app.store.update(id: edited.id, text: newerText); app.editor.setText(newerText)
        let newerCaret = NSRange(location: 4, length: 0)
        app.editor.selectSourceRange(newerCaret, scroll: false)
        wait(app)
        expect(app.store.note(id: edited.id)!.text.hasPrefix(newerText + "\n[Example.txt]"), "concurrent typing is preserved and attachment appends")
        expect(app.editor.selectedSourceRange == newerCaret, "append preserves active typing caret")

        let switched = app.store.create(text: "# Destination\nOriginal text")
        let other = app.store.create(text: "# Other\nMust stay unchanged")
        select(switched, in: app)
        _ = app.importAttachmentFiles([file])
        select(other, in: app)
        wait(app)
        expect(app.store.note(id: switched.id)!.text.hasPrefix(switched.text + "\n[Example.txt]"), "switching notes appends to original destination")
        expect(app.store.note(id: other.id) == other && app.editor.text == other.text, "different selected note is untouched")
        expect(app.selectedID == other.id, "copy completion does not switch selected note")

        let importFile = root.appendingPathComponent("Imported.md")
        try Data("# Imported\n\n[Owned file](Example.txt)\n#test".utf8).write(to: importFile)
        let count = app.store.notes.count
        app.importMarkdownFiles([importFile])
        let continued = other.text + "\nContinued typing"
        app.store.update(id: other.id, text: continued); app.editor.setText(continued)
        wait(app)
        expect(app.store.notes.count == count + 1, "Markdown batch adds its note")
        expect(app.selectedID == other.id && app.editor.text == continued, "Markdown completion preserves ongoing work")
        let imported = app.store.notes.first { $0.title == "Imported" }!
        let reference = app.attachments.references(in: imported.text).first!
        expect(app.attachments.resolve(reference.path) != nil, "Markdown relative attachment copied before commit")

        let exportDirectory = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let exported = exportDirectory.appendingPathComponent("note.md")
        app.exportMarkdown(text: imported.text, to: exported)
        app.store.update(id: imported.id, text: "Later edit")
        wait(app)
        let exportedText = try String(contentsOf: exported, encoding: .utf8)
        let exportedBytes = try Data(contentsOf: exportDirectory.appendingPathComponent(reference.path))
        expect(exportedText == imported.text, "export uses immutable captured text snapshot")
        expect(exportedBytes == originalBytes, "export preserves attachment bytes")
        let imageNote = app.store.create(text: "# Image paste")
        select(imageNote, in: app)
        app.editor.selectSourceRange(NSRange(location: (imageNote.text as NSString).length, length: 0), scroll: false)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = bitmap.representation(using: .png, properties: [:])!
        let imageReturn = app.editor.onImportImage?(png)
        expect(imageReturn == nil && app.pendingFileOperations == 1, "image conversion starts asynchronously without placeholder text")
        wait(app)
        let imageText = app.store.note(id: imageNote.id)!.text
        let imageReference = app.attachments.references(in: imageText).first!
        expect(imageReference.isImage && app.attachments.resolve(imageReference.path) != nil, "converted image is owned and inserted")

        let trashNote = app.store.create(text: "# Trash during copy")
        select(trashNote, in: app)
        let assetCount = try FileManager.default.contentsOfDirectory(atPath: app.attachments.rootURL.path).count
        _ = app.importAttachmentFiles([file])
        app.store.trash(id: trashNote.id)
        wait(app)
        expect(app.store.note(id: trashNote.id)!.text == trashNote.text, "moving destination to Trash prevents insertion")
        let retainedCount = try FileManager.default.contentsOfDirectory(atPath: app.attachments.rootURL.path).count
        expect(retainedCount == assetCount + 1, "copied file remains available when destination is trashed")
        expect(app.window.attachedSheet != nil, "cancelled attachment insertion is reported")
        if let sheet = app.window.attachedSheet { app.window.endSheet(sheet); sheet.orderOut(nil) }
        expect(app.store.flush(), "final local persistence succeeds")
        app.window.close()
        print("File operations: \(checks) assertions passed")
    }
}
