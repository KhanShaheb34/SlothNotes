import AppKit

/// Run without showing a window:
/// swiftc Sources/Sloth/MarkdownEditor.swift Sources/Sloth/AttachmentStore.swift Tests/EditorTests.swift -o .build/editor-tests
/// .build/editor-tests
@main
enum EditorTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        // An unshown window supplies NSTextView's native undo manager. No user app is opened.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = editor
        var changes: [String] = []
        editor.onChange = { changes.append($0) }

        editor.setText("A note\nHello world\n#work/test\n- [ ] Done\n")
        expect(changes.isEmpty, "Selecting a note does not emit an edit")
        editor.textView.setSelectedRange(NSRange(location: 7, length: 5))
        editor.applyFormat("bold")
        expect(editor.text.contains("**Hello**"), "Bold wraps the selection")
        expect(editor.textView.selectedRange() == NSRange(location: 9, length: 5), "Selection survives highlighting")
        expect(changes.last == editor.text, "Formatting routes through onChange")
        editor.applyFormat("bold")
        expect(editor.text.contains("\nHello world"), "Bold toggles off around the selection")
        editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        editor.applyFormat("todo")
        expect(editor.text.contains("\n- [ ] Hello world"), "Todo formatting prefixes the active line")

        editor.setText("😊 café\n第二行")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 2))
        editor.applyFormat("italic")
        expect(editor.text.hasPrefix("*😊*"), "UTF-16 selection handles emoji")
        expect(editor.textView.undoManager?.canUndo == true, "Native undo is available")
        editor.textView.undoManager?.undo()
        expect(editor.text == "😊 café\n第二行", "Undo restores the exact Unicode note")
        editor.textView.undoManager?.redo()
        expect(editor.text.hasPrefix("*😊*"), "Redo restores formatting")
        editor.setText(editor.text)
        expect(editor.textView.undoManager?.canUndo == false, "Note selection clears undo even for identical content")

        editor.setText("Tasks 🐻\n- [ ] Buy tea\n- [X] Read\n")
        let checkbox = (editor.text as NSString).range(of: "[ ]")
        let selection = NSRange(location: 0, length: 5)
        editor.textView.setSelectedRange(selection)
        let beforeToggle = changes.count
        expect(editor.toggleTodo(atUTF16Index: checkbox.location + 1), "Clicking the checkbox interior toggles it")
        expect(editor.text.contains("- [x] Buy tea"), "Unchecked task becomes checked")
        expect(editor.textView.selectedRange() == selection, "Toggling preserves the text selection")
        expect(changes.count == beforeToggle + 1 && changes.last == editor.text, "Toggling reports exactly one edit")
        editor.textView.undoManager?.undo()
        expect(editor.text.contains("- [ ] Buy tea"), "Checkbox toggle is undoable")
        editor.textView.undoManager?.redo()
        expect(editor.text.contains("- [x] Buy tea"), "Checkbox toggle can be redone")
        expect(editor.toggleTodo(atUTF16Index: checkbox.location + 2), "Closing bracket is clickable")
        expect(editor.text.contains("- [ ] Buy tea"), "Checked task becomes unchecked")
        let uppercaseCheckbox = (editor.text as NSString).range(of: "[X]")
        expect(editor.toggleTodo(atUTF16Index: uppercaseCheckbox.location), "Uppercase checked task toggles")
        expect(editor.text.contains("- [ ] Read"), "Uppercase checkbox becomes unchecked")
        expect(!editor.toggleTodo(atUTF16Index: checkbox.location + 4), "Task label is not a checkbox hit")
        expect(!editor.toggleTodo(atUTF16Index: -1), "Negative offsets are rejected")
        expect(!editor.toggleTodo(atUTF16Index: (editor.text as NSString).length), "End-of-text offsets are rejected")

        let literalExamples = [
            "```markdown\n- [ ] Literal task\n```\n",
            "~~~markdown\n- [ ] Literal task\n~~~\n",
            "````markdown\n```\n- [ ] Literal task\n````\n",
            "```markdown\n~~~\n- [ ] Literal task\n",
            "Text containing [ ] is not a task",
            "- [ ]without a separating space"
        ]
        for literal in literalExamples {
            editor.setText(literal)
            let marker = (literal as NSString).range(of: "[ ]")
            expect(!editor.toggleTodo(atUTF16Index: marker.location + 1), "Literal syntax does not toggle: \(literal.debugDescription)")
            expect(editor.text == literal, "Literal syntax remains unchanged")
        }
        editor.setText("```markdown\n- [ ] Literal\n```\n- [ ] Real task\n")
        let realTask = (editor.text as NSString).range(of: "[ ]", options: .backwards)
        expect(editor.toggleTodo(atUTF16Index: realTask.location + 1), "Tasks after a closed fence are interactive")
        expect(editor.text.contains("- [ ] Literal"), "Real task toggle does not affect fenced text")
        editor.setText("~~~markdown\n- [ ] Literal\n~~~~\n  * [ ] Nested task\n")
        let nestedTask = (editor.text as NSString).range(of: "[ ]", options: .backwards)
        expect(editor.toggleTodo(atUTF16Index: nestedTask.location), "Indented task works after a longer tilde closing fence")

        // A visual attachment replaces the entire Markdown marker, including its gap.
        editor.setText("Tasks\n- [ ] Checklist\n- [ ] \n- [x] Done\n")
        expect(editor.textView.string == "Tasks\n\u{FFFC}Checklist\n\u{FFFC}\n\u{FFFC}Done\n", "Tasks render as one checkbox each, including an empty row")
        expect(editor.renderedAttachmentCount == 3, "Each checklist row has one native attachment")
        expect(!editor.textView.string.contains("[ ]") && !editor.textView.string.contains("- ["), "No raw task punctuation leaks into the displayed note")
        expect(editor.text == "Tasks\n- [ ] Checklist\n- [ ] \n- [x] Done\n", "Projection preserves the exact source")
        let projectedChecklist = (editor.text as NSString).range(of: "Checklist")
        editor.selectSourceRange(projectedChecklist, scroll: false)
        expect(editor.textView.selectedRange() == NSRange(location: 7, length: 9), "Source selection maps across a checkbox")
        expect(editor.selectedSourceRange == projectedChecklist, "Selection maps back to source")
        let beforeTyping = changes.count
        editor.textView.insertText("Buy 🫖", replacementRange: editor.textView.selectedRange())
        expect(editor.text.contains("- [ ] Buy 🫖"), "Native typed edits after a projected checkbox retain Markdown")
        expect(changes.count == beforeTyping + 1, "A native text edit emits one change")
        expect(!editor.text.contains("\u{FFFC}"), "Attachment placeholders never reach saved notes")
        editor.textView.undoManager?.undo()
        expect(editor.text.contains("- [ ] Checklist"), "Native typed edits undo across projection")
        editor.textView.undoManager?.redo()
        expect(editor.text.contains("- [ ] Buy 🫖"), "Native typed edits redo across projection")

        // Undo shrinks the final projected paragraph while the old caret is
        // beyond its new end. Selection must be restored after TextKit processes
        // the character edit, including on macOS 15 with Writing Tools enabled.
        let emptyTask = "Tasks\n- [ ] "
        editor.setText(emptyTask)
        let emptyTaskCaret = NSRange(location: (emptyTask as NSString).length, length: 0)
        editor.selectSourceRange(emptyTaskCaret, scroll: false)
        editor.textView.insertText("Long 🫖 checklist", replacementRange: editor.textView.selectedRange())
        let completedTask = editor.text
        let completedTaskCaret = NSRange(location: (completedTask as NSString).length, length: 0)
        expect(editor.selectedSourceRange == completedTaskCaret, "Typing leaves the Unicode task caret at its source end")
        editor.textView.undoManager?.undo()
        expect(editor.text == emptyTask && editor.textView.string == "Tasks\n\u{FFFC}", "Shrinking undo restores the empty projected task")
        expect(editor.selectedSourceRange == emptyTaskCaret && editor.textView.selectedRange() == NSRange(location: 7, length: 0),
               "Shrinking undo restores the caret within the shorter display")
        editor.textView.undoManager?.redo()
        expect(editor.text == completedTask && editor.selectedSourceRange == completedTaskCaret, "Redo restores Unicode text and its mapped caret")
        let taskSelection = (editor.text as NSString).range(of: "🫖 checklist")
        editor.selectSourceRange(taskSelection, scroll: false)
        editor.isDark.toggle()
        expect(editor.selectedSourceRange == taskSelection, "Full projection restyling preserves the Unicode source selection")
        editor.isDark.toggle()

        editor.setText("Tasks\n- [x] Buy 🫖")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        editor.textView.insertNewline(nil)
        expect(editor.text == "Tasks\n- [x] Buy 🫖\n- [ ] ", "Return continues checked tasks as unchecked")
        expect(editor.textView.selectedRange().location == (editor.textView.string as NSString).length, "New task caret is after its checkbox")
        editor.textView.insertText("Milk", replacementRange: editor.textView.selectedRange())
        expect(editor.text.hasSuffix("- [ ] Milk"), "Typing a new task preserves the projected marker")
        editor.textView.insertNewline(nil)
        editor.textView.insertNewline(nil)
        expect(editor.text.hasSuffix("- [ ] Milk\n"), "Return on an empty task exits the list")
        editor.textView.insertText("Paragraph", replacementRange: editor.textView.selectedRange())
        expect(editor.text.hasSuffix("- [ ] Milk\nParagraph"), "Text after leaving a checklist is ordinary text")

        editor.setText("Tasks\n  * [ ] Nested")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        expect(editor.continueList(), "Nested checklist Return is handled")
        expect(editor.text.hasSuffix("\n  * [ ] "), "Continuation preserves indentation and bullet style")
        editor.setText("```\n- [ ] Example\n```\n")
        editor.selectSourceRange(NSRange(location: 17, length: 0), scroll: false)
        expect(editor.renderedAttachmentCount == 0 && !editor.continueList(), "Code examples stay literal and do not continue a checklist")
        editor.setText("- [ ]")
        expect(editor.textView.string == "\u{FFFC}", "An empty marker without trailing whitespace still renders")
        expect(editor.continueList() && editor.text.isEmpty, "An empty marker without trailing whitespace exits cleanly")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sloth-editor-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("test.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let fileURL = directory.appendingPathComponent("test.pdf")
        try! Data("%PDF-1.4\nTest fixture".utf8).write(to: fileURL)
        editor.attachmentResolver = { path in
            if path == "attachments/test.png" { return imageURL }
            if path == "attachments/test.pdf" { return fileURL }
            return nil
        }
        let richSource = "Rich 🦥\n![Holiday](attachments/test.png)\n[Paper](attachments/test.pdf)\n[Missing](attachments/missing.zip)\n- [ ] Review\n"
        editor.setText(richSource)
        expect(editor.renderedAttachmentCount == 4, "Images, files, missing files, and tasks all project")
        expect(editor.textView.string == "Rich 🦥\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}\n\u{FFFC}Review\n", "Rich content renders without raw attachment URLs")
        expect(editor.text == richSource, "Rich projection preserves every byte of portable Markdown")
        let reviewRange = (editor.text as NSString).range(of: "Review")
        editor.selectSourceRange(reviewRange, scroll: false)
        editor.applyFormat("bold")
        expect(editor.text.contains("- [ ] **Review**"), "Formatting uses source offsets after several rich attachments")
        expect(editor.selectedSourceRange.length == 6, "Selected label survives rich formatting")
        let boldFont = editor.textView.textStorage?.attribute(.font, at: editor.textView.selectedRange().location, effectiveRange: nil) as? NSFont
        expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Checklist label keeps bold styling")
        let dragBoard = NSPasteboard.withUniqueName()
        dragBoard.declareTypes([.string], owner: nil)
        editor.selectSourceRange(NSRange(location: 0, length: (editor.text as NSString).length), scroll: false)
        expect(editor.textView.writeSelection(to: dragBoard, type: .string), "Drag and service export support plain Markdown")
        expect(dragBoard.string(forType: .string) == editor.text, "Dragging projected content serializes source instead of placeholder characters")
        dragBoard.releaseGlobally()
        editor.textView.undoManager?.undo()
        expect(editor.text == richSource, "Formatting undo restores rich source exactly")
        let imageRange = (editor.text as NSString).range(of: "![Holiday](attachments/test.png)")
        editor.selectSourceRange(imageRange, scroll: false)
        expect(editor.textView.selectedRange().length == 1, "A source image selects one visible attachment")
        editor.textView.insertText("", replacementRange: editor.textView.selectedRange())
        expect(!editor.text.contains("test.png") && editor.renderedAttachmentCount == 3, "Deleting a visible image removes its whole Markdown reference")
        editor.textView.undoManager?.undo()
        expect(editor.text == richSource && editor.renderedAttachmentCount == 4, "Image deletion is fully undoable")
        editor.setText("`![literal](attachments/test.png)`\n~~~\n[file](attachments/test.pdf)\n~~~\n![remote](https://example.com/image.png)")
        expect(editor.renderedAttachmentCount == 0, "Inline code, fenced code, and remote image URLs are never loaded as attachments")
        editor.setText("A note")
        editor.selectSourceRange(NSRange(location: 6, length: 0), scroll: false)
        editor.insertMarkdown("[Paper](attachments/test.pdf)")
        expect(editor.text == "A note\n[Paper](attachments/test.pdf)\n", "Attachment insertion creates its own paragraph")
        expect(editor.renderedAttachmentCount == 1, "Inserted attachment is immediately rendered")

        // Compose through the native input method path and retain surrounding tokens.
        editor.setText("Tasks\n- [ ] ")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        editor.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(editor.text == "Tasks\n- [ ] 日本", "Input method composition preserves checklist source")
        editor.textView.undoManager?.undo()
        expect(editor.text == "Tasks\n- [ ] ", "Composed text has one source-aware undo")

        editor.setText("Outgoing\n- [ ] ")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        editor.textView.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeSwitchChanges = changes.count
        editor.setText("Incoming note\nDo not overwrite this")
        expect(changes.count == beforeSwitchChanges + 1 && changes.last == "Outgoing\n- [ ] 日本", "Switching notes commits marked input to the outgoing document exactly once")
        expect(editor.text == "Incoming note\nDo not overwrite this" && !editor.textView.hasMarkedText(), "The new note replaces the editor only after composition completes")
        expect(editor.textView.undoManager?.isUndoRegistrationEnabled == true && editor.textView.undoManager?.canUndo == false,
               "Switching during composition keeps native undo balanced and clears the old note history")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        editor.textView.insertText(" safely", replacementRange: editor.textView.selectedRange())
        expect(editor.text == "Incoming note\nDo not overwrite this safely", "Editing the new note after composition never includes outgoing text")
        editor.textView.undoManager?.undo()
        expect(editor.text == "Incoming note\nDo not overwrite this", "Undo after a composed note switch affects only the incoming note")

        editor.setText("Draft\n")
        editor.selectSourceRange(NSRange(location: 6, length: 0), scroll: false)
        editor.textView.setMarkedText("বাংলা", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeFlushComposition = changes.count
        editor.finishPendingComposition()
        editor.finishPendingComposition()
        expect(editor.text == "Draft\nবাংলা" && changes.count == beforeFlushComposition + 1,
               "Lifecycle composition flush is idempotent and retains visible multilingual input")
        editor.textView.undoManager?.undo()
        expect(editor.text == "Draft\n", "An explicitly committed composition remains one undoable edit")

        editor.setText("Long note\n" + Array(repeating: "A paragraph with enough lines to scroll.", count: 100).joined(separator: "\n"))
        editor.layoutSubtreeIfNeeded()
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        let clipView = editor.textView.enclosingScrollView!.contentView
        clipView.scroll(to: NSPoint(x: 0, y: 600))
        let visibleOrigin = clipView.bounds.origin
        expect(visibleOrigin.y > 100, "Viewport preservation test starts scrolled down")
        let selectedBeforeRefresh = editor.selectedSourceRange
        let changesBeforeRefresh = changes.count
        editor.refreshAttachments()
        expect(abs(clipView.bounds.origin.y - visibleOrigin.y) < 1, "Background attachment refresh preserves the visible scroll position")
        expect(editor.selectedSourceRange == selectedBeforeRefresh && changes.count == changesBeforeRefresh, "Attachment refresh preserves selection without emitting an edit")

        // The display uses the same parser as import/export and synchronization.
        editor.setText(#"![A \[bracket\] label](<attachments/test.png> "Caption")"# + "\n" + #"[A file](attachments/test.pdf "Title")"#)
        expect(editor.renderedAttachmentCount == 2, "Escaped labels, angle paths and optional titles render as rich attachments")
        expect(editor.textView.string == "\u{FFFC}\n\u{FFFC}", "Shared parser hides complete attachment syntax")
        editor.setText("````swift\n~~~\n![Literal](attachments/test.png)\n`````\n![Visible](attachments/test.png)")
        expect(editor.renderedAttachmentCount == 1, "Only matching fence characters close a code block, including longer fences")

        // Local projection must move the remaining source/display ranges exactly,
        // while keeping the existing attachment cells and their layout alive.
        let incrementalSource = "Title\nFirst **paragraph** here.\n- [ ] Keep this task\n![Keep](attachments/test.png)\nLast paragraph."
        editor.setText(incrementalSource)
        let imageDisplay = (editor.textView.string as NSString).range(of: "\u{FFFC}", options: .backwards)
        let originalImage = editor.textView.textStorage!.attribute(.attachment, at: imageDisplay.location, effectiveRange: nil) as AnyObject?
        let firstParagraph = (editor.text as NSString).range(of: "First")
        editor.selectSourceRange(firstParagraph, scroll: false)
        editor.textView.insertText("A new 😊\nFirst", replacementRange: editor.textView.selectedRange())
        let movedImageRange = (editor.textView.string as NSString).range(of: "\u{FFFC}", options: .backwards)
        let movedImage = editor.textView.textStorage!.attribute(.attachment, at: movedImageRange.location, effectiveRange: nil) as AnyObject?
        expect(originalImage === movedImage, "Editing another paragraph retains existing image cell and layout")
        let movedTask = (editor.text as NSString).range(of: "[ ]")
        expect(editor.toggleTodo(atUTF16Index: movedTask.location + 1), "Task source offsets track a preceding multiline Unicode edit")
        expect(editor.text.contains("- [x] Keep this task"), "Moved checkbox toggles the correct source")
        editor.textView.undoManager?.undo()
        expect(editor.text == incrementalSource, "Grouped undo restores exact Markdown after local projection and checkbox edits")
        editor.textView.undoManager?.redo()
        expect(editor.text.hasPrefix("Title\nA new 😊\nFirst") && editor.text.contains("- [x]"), "Grouped redo reapplies source deltas correctly")

        editor.setText("Title\nAlpha\nBeta\n- [ ] After")
        let newline = (editor.text as NSString).range(of: "\nBeta")
        editor.selectSourceRange(NSRange(location: newline.location, length: 1), scroll: false)
        editor.textView.insertText("", replacementRange: editor.textView.selectedRange())
        expect(editor.text.contains("AlphaBeta\n- [ ] After"), "Deleting a paragraph boundary reparses the joined paragraph")
        expect(editor.renderedAttachmentCount == 1, "Joining adjacent paragraphs retains the following task")
        editor.selectSourceRange(NSRange(location: 6, length: 0), scroll: false)
        editor.textView.insertText("```\n", replacementRange: editor.textView.selectedRange())
        expect(editor.renderedAttachmentCount == 0, "Adding a fence reparses following paragraphs and removes literal task projection")
        editor.textView.undoManager?.undo()
        expect(editor.text == "Title\nAlpha\nBeta\n- [ ] After", "Undoing structural edits restores all paragraphs and task projection")
        expect(editor.renderedAttachmentCount == 1, "Undo restores projected task after fence deletion")

        editor.setText("Title\n```swift\nlet value = 1\n```\n- [ ] After code")
        let codeValue = (editor.text as NSString).range(of: "value")
        editor.selectSourceRange(codeValue, scroll: false)
        editor.textView.insertText("result", replacementRange: editor.textView.selectedRange())
        let codeIndex = (editor.textView.string as NSString).range(of: "result").location
        let codeFont = editor.textView.textStorage!.attribute(.font, at: codeIndex, effectiveRange: nil) as? NSFont
        expect(codeFont?.isFixedPitch == true, "Typing within an existing fence keeps code styling")
        expect(editor.renderedAttachmentCount == 1, "Editing fenced text preserves following tasks")
        editor.selectSourceRange((editor.text as NSString).range(of: "After code"), scroll: false)
        expect(editor.selectedSourceRange == (editor.text as NSString).range(of: "After code"), "Code edits correctly shift later source selections")

        editor.setText("Title\nRead [[Another note|Alias]]\n```\n[[Literal]]\n```")
        let wikiIndex = (editor.textView.string as NSString).range(of: "Another note").location
        let wikiLink = editor.textView.textStorage!.attribute(.link, at: wikiIndex, effectiveRange: nil) as? URL
        var openedNote: String?
        editor.onOpenNoteLink = { openedNote = $0; return true }
        expect(wikiLink != nil && editor.textView(editor.textView, clickedOnLink: wikiLink!, at: wikiIndex), "Wiki references are native clickable note links")
        expect(openedNote == "Another note", "Wiki navigation resolves original title separately from alias")
        let literalIndex = (editor.textView.string as NSString).range(of: "Literal").location
        expect(editor.textView.textStorage!.attribute(.link, at: literalIndex, effectiveRange: nil) == nil, "Fenced wiki examples are not interactive links")

        editor.setText("Title\n[PDF](attachments/test.pdf)")
        let fileDisplay = (editor.textView.string as NSString).range(of: "\u{FFFC}")
        let fileCell = editor.textView.textStorage!.attribute(.attachment, at: fileDisplay.location, effectiveRange: nil) as AnyObject?
        editor.refreshAttachments()
        let refreshedCell = editor.textView.textStorage!.attribute(.attachment, at: fileDisplay.location, effectiveRange: nil) as AnyObject?
        expect(fileCell === refreshedCell, "Unchanged attachment refresh keeps existing layout and cells")
        try! Data("%PDF-1.4\nChanged test fixture".utf8).write(to: fileURL)
        editor.refreshAttachments()
        let changedCell = editor.textView.textStorage!.attribute(.attachment, at: fileDisplay.location, effectiveRange: nil) as AnyObject?
        expect(fileCell !== changedCell, "Changed attachment bytes refresh the visible preview")

        // Mix structural edits and ordinary typing against a fresh parse. This
        // catches offset drift after split/join operations and syntax changes.
        let referenceEditor = MarkdownEditorView(frame: editor.frame)
        referenceEditor.attachmentResolver = editor.attachmentResolver
        editor.setText("Title\nParagraph with **bold** and `code`.\n- [ ] A task\n![Photo](attachments/test.png)\n~~~\nLiteral [file](attachments/test.pdf)\n~~~\nFinal paragraph.")
        var random: UInt64 = 0x51_07_42
        let insertions = ["x", "\n", "**", "- [ ] ", "```", "\n~~~\n", "😊", "[PDF](attachments/test.pdf)", "]", "[[Another note]]", ""]
        for step in 0..<80 {
            random = random &* 6364136223846793005 &+ 1
            let source = editor.text as NSString
            var location = Int((random >> 32) % UInt64(source.length + 1))
            if location > 0 && location < source.length && (0xDC00...0xDFFF).contains(source.character(at: location)) { location -= 1 }
            let length = min(step % 5, source.length - location)
            editor.selectSourceRange(source.rangeOfComposedCharacterSequences(for: NSRange(location: location, length: length)), scroll: false)
            let effectiveRange = editor.selectedSourceRange
            let insertion = insertions[step % insertions.count]
            let expected = source.replacingCharacters(in: effectiveRange, with: insertion)
            editor.textView.insertText(insertion, replacementRange: editor.textView.selectedRange())
            expect(editor.text == expected, "Mixed edit \(step) preserves raw Unicode Markdown")
            referenceEditor.setText(expected)
            expect(editor.textView.string == referenceEditor.textView.string && editor.renderedAttachmentCount == referenceEditor.renderedAttachmentCount,
                   "Mixed edit \(step) matches a fresh projection after syntax changes")
        }

        editor.setText(#"""
Links
[Read \[this\]](<https://example.com/a?name=a%26b> "Title")
[Email](mailto:hello@example.com)
[Subject](mailto:hello@example.com?subject=Hello%20there&body=Details)
[No recipient](mailto:)
[Only subject](mailto:?subject=Hello)
[Only fragment](mailto:#draft)
http://example.org/page.
mailto:team@example.com
[Local](file:///tmp/example.txt)
[Bear](bear://x-callback-url/open-note?id=123)
[Unsafe](javascript:alert)
`https://example.net/inline`
```
https://example.net/fenced
```
"""#)
        func link(at text: String) -> URL? {
            let range = (editor.textView.string as NSString).range(of: text)
            return range.location == NSNotFound ? nil : editor.textView.textStorage!.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        expect(link(at: #"Read \[this\]"#)?.absoluteString == "https://example.com/a?name=a%26b", "Markdown web labels use the shared parser and preserve percent-encoded query semantics")
        expect(link(at: "Email")?.absoluteString == "mailto:hello@example.com", "Markdown mailto labels are native email links")
        expect(link(at: "Subject")?.absoluteString == "mailto:hello@example.com?subject=Hello%20there&body=Details", "Email links preserve encoded subject and body parameters")
        expect(link(at: "No recipient") == nil && link(at: "Only subject") == nil && link(at: "Only fragment") == nil,
               "Email links without a recipient remain plain text")
        expect(link(at: "http://example.org/page")?.absoluteString == "http://example.org/page", "Bare web URLs exclude sentence punctuation")
        expect(link(at: "mailto:team")?.absoluteString == "mailto:team@example.com", "Bare mailto URLs are native links")
        expect(link(at: "Local") == nil && link(at: "Bear") == nil && link(at: "Unsafe") == nil, "Imported file, app and script schemes do not become actionable links")
        expect(link(at: "https://example.net/inline") == nil && link(at: "https://example.net/fenced") == nil, "Inline and fenced code links remain literal examples")

        editor.isDark = true
        editor.fontSize = 18
        let rgb = editor.textView.insertionPointColor.usingColorSpace(.sRGB)!
        expect(abs(rgb.redComponent - 227.0 / 255) < 0.001 && abs(rgb.greenComponent - 107.0 / 255) < 0.001,
               "Dark Graphite uses Sloth's warm coral accent")
        editor.setEditable(false)
        let readOnlyText = editor.text
        let editCount = changes.count
        editor.applyFormat("bold")
        expect(!editor.toggleTodo(atUTF16Index: nestedTask.location), "Read-only tasks cannot toggle")
        expect(editor.text == readOnlyText && changes.count == editCount, "Read-only operations do not change data")
        expect(!window.isVisible, "Native test window stays hidden")
        print("Editor tests passed: \(assertions) assertions")
    }
}
