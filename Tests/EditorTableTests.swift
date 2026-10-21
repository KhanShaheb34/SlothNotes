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
        expect(cell.cellSize().width > 620 && cell.cellSize().width <= editor.textView.bounds.width,
               "Tables use the wide editor's available space rather than the narrower image cap")
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
        editor.setText(table)
        editor.layoutSubtreeIfNeeded()
        editor.textView.mouseDown(with: event)
        guard let draftField = editor.textView.subviews.compactMap({ $0 as? MarkdownTableCellEditor }).first,
              let draftEditor = draftField.currentEditor() as? NSTextView else { fatalError("Missing native draft editor") }
        draftEditor.insertText("A substantially longer first cell 🦥",
                               replacementRange: NSRange(location: 0, length: (draftEditor.string as NSString).length))
        draftEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        guard let nextDraft = editor.textView.subviews.compactMap({ $0 as? MarkdownTableCellEditor }).first,
              let nextDraftEditor = nextDraft.currentEditor() as? NSTextView else { fatalError("Missing next draft editor") }
        expect(nextDraftEditor.undoManager?.canUndo == false,
               "A new cell keeps draft undo separate from committed note edits")
        nextDraftEditor.undoManager?.undo()
        expect(nextDraftEditor.string == "**Ready**" && editor.text.contains("A substantially longer first cell 🦥"),
               "Undo in an untouched next cell preserves both cells")
        nextDraftEditor.insertText("New second cell", replacementRange: NSRange(location: 0, length: (nextDraftEditor.string as NSString).length))
        nextDraftEditor.undoManager?.undo()
        expect(nextDraftEditor.string == "**Ready**", "Undo still restores edits made within the current table cell")
        nextDraftEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        window.undoManager?.undo()
        expect(editor.text == table, "Starting and cancelling another cell preserves the committed note undo history")
        editor.setText(table)
        editor.layoutSubtreeIfNeeded()
        editor.textView.mouseDown(with: event)
        editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.stringValue = "Saved before fold"
        expect(editor.toggleHeadingFold(atUTF16Index: 0), "A section with an active table cell can fold")
        expect(editor.text.contains("Saved before fold"), "Folding commits a pending cell before source offsets shift")
        expect(editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty, "Folding cannot leave a floating field over hidden text")
        editor.setText(table)
        editor.layoutSubtreeIfNeeded()
        editor.textView.mouseDown(with: event)
        editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.stringValue = "Saved before style"
        editor.isDark = true
        expect(editor.text.contains("Saved before style"), "Changing appearance preserves a table draft before rebuilding")
        expect(editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.isEmpty, "Rebuilt tables have no stale-position field")
        editor.isDark = false
        editor.setText(table)
        editor.layoutSubtreeIfNeeded()
        editor.textView.mouseDown(with: event)
        editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.stringValue = "Saved before Trash"
        editor.setEditable(false)
        expect(editor.text.contains("Saved before Trash"), "Entering read-only mode flushes outgoing table edits first")
        editor.setEditable(true)
        editor.setText("| A | B |\n| --- | --- |\n| one\\|\n")
        expect(editor.editTableCell(atUTF16Index: 0, row: 1, column: 1, value: "last"), "A missing cell can follow an escaped trailing pipe")
        let escapedCells = MarkdownPresentation.parse(editor.text).tables[0].rows[1].cells
        expect((editor.text as NSString).substring(with: escapedCells[0].contentRange) == "one\\|", "Escaped pipe remains part of the first cell")
        expect((editor.text as NSString).substring(with: escapedCells[1].contentRange) == "last", "The new value enters the second cell")
        // Clicking a later table flushes the active field before opening the
        // clicked cell. That flush can move the later table's UTF-16 source index.
        editor.setText("# Two tables\n| A | B |\n| --- | --- |\n| one | two |\n\nBetween\n\n| C | D |\n| --- | --- |\n| three | four |\n")
        editor.layoutSubtreeIfNeeded()
        func clickCell(inTable tableIndex: Int, row: Int = 1, column: Int = 0) {
            manager.ensureLayout(for: container)
            var tables: [(NSRange, MarkdownTableAttachmentCell)] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let attachment = value as? NSTextAttachment,
                   let cell = attachment.attachmentCell as? MarkdownTableAttachmentCell { tables.append((range, cell)) }
            }
            let target = tables[tableIndex]
            let glyphs = manager.glyphRange(forCharacterRange: target.0, actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let bounds = target.1.cellFrame(row: row, column: column, in: frame)!
            let point = NSPoint(x: bounds.midX + editor.textView.textContainerOrigin.x,
                                y: bounds.midY + editor.textView.textContainerOrigin.y)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.textView.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            editor.textView.mouseDown(with: click)
        }
        func typeInActiveCell(_ value: String) {
            guard let field = editor.textView.subviews.compactMap({ $0 as? MarkdownTableCellEditor }).first,
                  let native = field.currentEditor() as? NSTextView else { fatalError("Missing active native table field") }
            native.insertText(value, replacementRange: NSRange(location: 0, length: (native.string as NSString).length))
        }
        clickCell(inTable: 0)
        typeInActiveCell("A longer 🦥 first entry")
        clickCell(inTable: 1)
        expect(editor.text.contains("A longer 🦥 first entry"), "Switching tables commits the previous native field")
        expect(editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.stringValue == "three",
               "Clicking a later table opens its requested cell after an earlier Unicode edit shifts source offsets")
        typeInActiveCell("Later entry")
        editor.finishPendingComposition()
        expect(editor.text.contains("| Later entry | four |"), "The newly opened field commits to the shifted table")
        clickCell(inTable: 0)
        typeInActiveCell("x")
        clickCell(inTable: 1)
        expect(editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first?.stringValue == "Later entry",
               "Clicking a later table also tracks a source offset shifted backwards by a shorter edit")
        editor.finishPendingComposition()
        editor.setText(table)
        clickCell(inTable: 0, row: 1, column: 1)
        typeInActiveCell("Final 🦥")
        let lastNative = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first!.currentEditor() as! NSTextView
        lastNative.setSelectedRange(NSRange(location: (lastNative.string as NSString).length, length: 0))
        lastNative.doCommand(by: #selector(NSResponder.insertTab(_:)))
        let boundaryField = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first
        expect(boundaryField?.stringValue == "Final 🦥", "Tab in the final cell commits and keeps editing that cell")
        guard let boundaryNative = boundaryField?.currentEditor() as? NSTextView else { fatalError("Missing final-cell field") }
        boundaryNative.insertText(" plus", replacementRange: boundaryNative.selectedRange())
        editor.finishPendingComposition()
        expect(editor.text.contains("| 🦥 Sloth | Final 🦥 plus |"), "Typing after final-cell Tab keeps the caret inside that cell")
        clickCell(inTable: 0, row: 0, column: 0)
        let firstNative = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first!.currentEditor() as! NSTextView
        firstNative.setSelectedRange(NSRange(location: 2, length: 1))
        firstNative.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        let firstBoundary = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first
        expect(firstBoundary?.stringValue == "Item" && (firstBoundary?.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 1),
               "Shift-Tab in the first cell keeps the cell and its text selection")
        editor.finishPendingComposition()
        for ending in ["", "\n"] {
            let original = "| A | B |\n| --- | --- |\n| One | Two |" + ending
            editor.setText(original)
            clickCell(inTable: 0)
            typeInActiveCell("First")
            let multiline = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first!.currentEditor() as! NSTextView
            multiline.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            multiline.insertText("Second", replacementRange: multiline.selectedRange())
            expect(multiline.string == "First\nSecond" && editor.hasPendingInput,
                   "Return continues editing a multiline native table cell")
            let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            expect(window.performKeyEquivalent(with: commandReturn), "The native window routes Command-Return to the active table cell")
            expect(!editor.hasPendingInput && editor.text.contains("| First<br>Second | Two |"),
                   "Command-Return saves multiline cell source and leaves cell editing")
            window.undoManager?.undo()
            expect(editor.text == original, "One note undo restores both a multiline cell and its Command-Return exit paragraph")
            window.undoManager?.redo()
            editor.textView.insertText("After table", replacementRange: editor.textView.selectedRange())
            expect(MarkdownPresentation.parse(editor.text).tables.count == 1 && editor.text.hasSuffix("\n\nAfter table"),
                   "Typing after Command-Return starts a safe paragraph after a table at EOF")
            let saved = editor.text
            editor.setText(saved)
            clickCell(inTable: 0)
            let reopened = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first!
            expect(reopened.stringValue == "First\nSecond", "Saved multiline source reopens as editable lines")
            typeInActiveCell("Pasted first\nPasted second | 🦥")
            window.makeFirstResponder(editor.textView)
            expect(editor.text.contains("Pasted first<br>Pasted second \\| 🦥") && MarkdownPresentation.parse(editor.text).tables[0].rows.count == 2,
                   "Leaving a multiline paste saves its line breaks and preserves the table structure")
            window.undoManager?.undo()
            expect(editor.text == saved, "Focus-loss commit of a multiline cell remains one note undo action")
        }
        let variedBreaks = "| A | B |\n| --- | --- |\n| First<BR />Second `literal<br>tag` | Two |\n\nAfter."
        editor.setText(variedBreaks)
        clickCell(inTable: 0)
        let unchangedMultiline = editor.textView.subviews.compactMap { $0 as? MarkdownTableCellEditor }.first!
        expect(unchangedMultiline.stringValue == "First\nSecond `literal<br>tag`", "Editing imported break tags keeps literal inline code intact")
        window.makeFirstResponder(editor.textView)
        expect(editor.text == variedBreaks, "Opening and leaving a multiline cell preserves its exact original Markdown")
        clickCell(inTable: 0)
        let finishBeforeParagraph = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: finishBeforeParagraph)
        editor.textView.insertText("Inserted paragraph", replacementRange: editor.textView.selectedRange())
        expect(editor.text.hasSuffix("\n\nInserted paragraph\nAfter.") && MarkdownPresentation.parse(editor.text).tables.count == 1,
               "Command-Return creates a safe paragraph before existing following text")
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
