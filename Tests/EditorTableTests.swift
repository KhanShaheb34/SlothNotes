import AppKit

@main
enum EditorTableTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        window.contentView = editor
        let table = "# Table\n\n| Item | State |\n| :--- | ---: |\n| 🦥 Sloth | **Ready** |\n\nAfter."
        editor.setText(table)
        expect(!editor.textView.string.contains("| :---"), "Pipe tables render as native grids rather than literal source")
        expect(editor.text == table, "Table rendering keeps portable Markdown unchanged")
        let start = (table as NSString).range(of: "| Item").location
        window.undoManager?.beginUndoGrouping()
        expect(editor.editTableCell(atUTF16Index: start, row: 1, column: 1, value: "Done | reviewed"), "Native cell edits reach the Markdown source")
        window.undoManager?.endUndoGrouping()
        expect(editor.text.contains("| 🦥 Sloth | Done \\| reviewed |"), "Pipes typed in cells cannot split columns")
        expect(editor.text.hasSuffix("\n\nAfter."), "Editing a table preserves following paragraphs")
        window.undoManager?.undo()
        expect(editor.text == table, "A cell edit undoes as a single source change")
        window.undoManager?.redo()
        expect(editor.text.contains("Done \\| reviewed"), "Redo restores the cell edit")
        editor.setText("# Short row\n\n| A | B | C |\n| --- | --- | --- |\n| x |\n")
        let shortStart = (editor.text as NSString).range(of: "| A").location
        expect(editor.editTableCell(atUTF16Index: shortStart, row: 1, column: 2, value: "last"), "Implicit empty cells can be edited")
        let parsed = MarkdownPresentation.parse(editor.text)
        expect(parsed.tables.first?.rows[1].cells.count == 3, "Materializing missing cells keeps the table structure")
        if let cells = parsed.tables.first?.rows[1].cells {
            expect((editor.text as NSString).substring(with: cells[1].contentRange).isEmpty, "Earlier missing cell stays empty")
            expect((editor.text as NSString).substring(with: cells[2].contentRange) == "last", "Edited value lands in the requested missing column")
        }
        editor.setText(table)
        editor.layoutSubtreeIfNeeded()
        guard let storage = editor.textView.textStorage, let manager = editor.textView.layoutManager,
              let container = editor.textView.textContainer else { fatalError("Missing native editor layout") }
        manager.ensureLayout(for: container)
        var attachment: NSTextAttachment?
        var attachmentRange = NSRange()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let value = value as? NSTextAttachment, value.attachmentCell is MarkdownTableAttachmentCell {
                attachment = value; attachmentRange = range; stop.pointee = true
            }
        }
        guard let cell = attachment?.attachmentCell as? MarkdownTableAttachmentCell else { fatalError("Missing rendered table") }
        let glyphs = manager.glyphRange(forCharacterRange: attachmentRange, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        guard let firstCell = cell.cellFrame(row: 1, column: 0, in: bounds) else { fatalError("Missing cell geometry") }
        let point = NSPoint(x: firstCell.midX + editor.textView.textContainerOrigin.x, y: firstCell.midY + editor.textView.textContainerOrigin.y)
        let windowPoint = editor.textView.convert(point, to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        editor.textView.mouseDown(with: event)
        let field = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first
        expect(field?.stringValue == "🦥 Sloth", "Clicking a rendered cell opens its native editor")
        if let field {
            let nativeEditor = NSTextView()
            nativeEditor.string = "Changed"
            expect(field.control(field, textView: nativeEditor, doCommandBy: #selector(NSResponder.insertTab(_:))), "Tab commits a native cell edit")
            let next = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first
            expect(next?.stringValue == "**Ready**", "Tab moves into the next cell")
            next?.stringValue = "Pending save"
            editor.finishPendingComposition()
            expect(editor.text.contains("| Changed | Pending save |"), "Shutdown/note-switch flush includes pending table text")
            expect(editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty, "Flushing removes the field without leaking it into another note")
        }
        editor.setEditable(false)
        expect(!editor.editTableCell(atUTF16Index: start, row: 0, column: 0, value: "No"), "Read-only notes reject cell edits")
        editor.setEditable(true)
        editor.setText("# A small plan\n\n| Task | Owner | State |\n| :--- | :---: | ---: |\n| Read **one chapter** | 🦥 | Done |\n| Visit [the library](https://example.com) | Me | Next |\n| Write a long thought that wraps neatly inside its cell | Us | Later |\n\nClick a cell to edit. Tab moves to the next cell.")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        for dark in [false, true] {
            editor.isDark = dark
            editor.restoreScrollPosition(.zero)
            editor.layoutSubtreeIfNeeded()
            if let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
                editor.cacheDisplay(in: editor.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/private/tmp/sloth-table-\(dark ? "dark" : "light").png"))
                }
            }
        }
        print("Passed \(assertions) table editor assertions")
        window.orderOut(nil)
    }
}
