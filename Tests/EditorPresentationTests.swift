import AppKit

@main
enum EditorPresentationTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func hidden(_ editor: MarkdownEditorView, _ needle: String) -> Bool {
        let range = (editor.textView.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let storage = editor.textView.textStorage else { return false }
        return storage.attribute(NSAttributedString.Key("SlothHiddenSyntax"), at: range.location, effectiveRange: nil) as? Bool == true
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownEditorView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = editor
        let source = "# Heading\n\nA **bold** word, *italic*, ~~gone~~, `code` and [website](https://example.com/path).\n\nEnd."
        editor.setText(source)
        editor.selectSourceRange(NSRange(location: (source as NSString).length, length: 0))
        expect(hidden(editor, "# "), "Heading punctuation disappears when reading")
        expect(hidden(editor, "**"), "Completed bold delimiters disappear after the caret leaves")
        expect(hidden(editor, "](https://"), "Link destination disappears, leaving its label")
        expect(editor.text == source, "Presentation never changes portable Markdown")
        let bold = (source as NSString).range(of: "bold")
        editor.selectSourceRange(NSRange(location: bold.location + 2, length: 0))
        expect(!hidden(editor, "**"), "Moving inside emphasis reveals editable delimiters")
        expect(editor.selectedSourceRange.location == bold.location + 2, "Reveal preserves the Unicode source caret")
        editor.selectSourceRange(NSRange(location: (source as NSString).length, length: 0))
        expect(hidden(editor, "**"), "Leaving emphasis hides its syntax again")
        let folded = "# Note\n\n## Section <!-- {\"fold\":true} -->\nSecret body\n### Child\nHidden child\n## Next\nVisible body\n"
        editor.setText(folded)
        expect(!editor.textView.string.contains("Secret body"), "Saved folded headings exclude their body from display storage")
        expect(!editor.textView.string.contains("Hidden child"), "Folding includes nested headings")
        expect(editor.textView.string.contains("Visible body"), "A fold stops at the next same-level heading")
        expect(editor.text == folded, "Fold projection preserves all original text")
        let section = (folded as NSString).range(of: "## Section").location
        expect(editor.toggleHeadingFold(atUTF16Index: section), "Fold disclosure expands its heading")
        expect(editor.textView.string.contains("Secret body"), "Expanding restores the complete editable body")
        expect(editor.textView.string.contains("Hidden child"), "Expanding restores nested heading text")
        expect(!editor.text.contains("\"fold\":true"), "Unfolded state persists in Markdown")
        expect(editor.toggleHeadingFold(atUTF16Index: section), "Expanded headings can be folded again")
        expect(!editor.textView.string.contains("Secret body"), "Refolding removes text again")
        editor.selectSourceRange(NSRange(location: 0, length: (editor.text as NSString).length))
        let clipboard = NSPasteboard.withUniqueName()
        expect(editor.textView.writeSelection(to: clipboard, type: .string), "Folded text can be copied as Markdown")
        expect(clipboard.string(forType: .string) == editor.text, "Copy includes all folded content without data loss")
        let code = "# Note\n\n```swift\nlet x = 1\n\n# literal **markers** [link](https://example.com)\n```\n\nEnd"
        editor.setText(code)
        editor.selectSourceRange(NSRange(location: (code as NSString).length, length: 0))
        expect(hidden(editor, "```swift"), "Code fence backticks are concealed when reading")
        expect(!hidden(editor, "**markers**"), "Markdown inside code remains literal")
        let literal = (editor.textView.string as NSString).range(of: "# literal").location
        let paragraph = editor.textView.textStorage?.attribute(.paragraphStyle, at: literal, effectiveRange: nil) as? NSParagraphStyle
        expect(paragraph?.paragraphSpacingBefore == 0, "Heading-like code never receives heading paragraph spacing")
        let link = (editor.textView.string as NSString).range(of: "https://example.com").location
        expect(editor.textView.textStorage?.attribute(.link, at: link, effectiveRange: nil) == nil, "Code URLs are not interactive links")
        editor.selectSourceRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("Prefix ", replacementRange: editor.textView.selectedRange())
        let codeLine = (editor.text as NSString).range(of: "let x").location
        editor.selectSourceRange(NSRange(location: codeLine, length: 0))
        editor.textView.insertText(" ", replacementRange: editor.textView.selectedRange())
        if let manager = editor.textView.layoutManager as? MarkdownLayoutManager, let container = editor.textView.textContainer {
            manager.ensureLayout(for: container)
            expect(manager.codeBlockBackgroundRects(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)).count == 1,
                   "Edits before and within code retain one continuous background")
        } else { expect(false, "Editor installs Markdown layout") }
        editor.setText("# Emoji 🦥\n**café 🦥** [site](https://example.com/a_(b))\nEnd")
        let unicode = (editor.text as NSString).range(of: "🦥**")
        editor.selectSourceRange(NSRange(location: unicode.location, length: 2))
        expect(editor.selectedSourceRange == NSRange(location: unicode.location, length: 2), "Concealment preserves Unicode selection")
        editor.textView.insertText("🐾", replacementRange: editor.textView.selectedRange())
        expect(editor.text.contains("**café 🐾**"), "Editing visible content preserves Markdown delimiters")
        let escaped = "# Note\n\\**literal** and `~~not struck~~`\nEnd"
        editor.setText(escaped)
        editor.selectSourceRange(NSRange(location: (escaped as NSString).length, length: 0))
        expect(!hidden(editor, "**literal**"), "Escaped opening punctuation never becomes hidden formatting")
        let struckCode = (editor.textView.string as NSString).range(of: "not struck").location
        expect((editor.textView.textStorage?.attribute(.strikethroughStyle, at: struckCode, effectiveRange: nil) as? Int ?? 0) == 0,
               "Inline code never inherits strike formatting")
        editor.setText("# Title\nBody")
        editor.textView.insertText("New ", replacementRange: editor.textView.selectedRange())
        expect(editor.text.hasPrefix("# New Title"), "The initial heading caret inserts into its text instead of before hidden hashes")
        editor.setText("# Note\n## Heading ##\nBody\n## Next\nEnd")
        expect(editor.toggleHeadingFold(atUTF16Index: 7), "Headings with closing hashes can be folded")
        expect(!editor.textView.string.contains("Body"), "A closing-hash heading persists an effective fold marker")
        editor.setText("# Note\n## Hidden <!-- {\"fold\":true} -->\nFind this 🦥\n## Next\nEnd")
        let target = (editor.text as NSString).range(of: "Find this 🦥")
        editor.selectSourceRange(target)
        expect(editor.textView.string.contains("Find this 🦥"), "Navigation reveals a match inside a collapsed section")
        expect((editor.text as NSString).substring(with: editor.selectedSourceRange) == "Find this 🦥", "Revealing a fold retains the exact target selection")
        editor.setText("# Note\n\n> A **quoted** thought with `code`.\n> Another line.\n\n---\n\n_Emphasis_ and ``code `inside` code``.\nEnd")
        editor.selectSourceRange(NSRange(location: (editor.text as NSString).length, length: 0), scroll: false)
        expect(hidden(editor, "> "), "Blockquotes hide source punctuation behind a native bar")
        expect(!editor.textView.string.contains("---"), "Horizontal rules render as a line")
        expect(hidden(editor, "_Emphasis_"), "Underscore emphasis conceals its delimiters")
        expect(hidden(editor, "``code"), "Long backtick delimiters render as inline code")
        let codeInside = (editor.textView.string as NSString).range(of: "`inside`").location
        expect((editor.textView.textStorage?.attribute(.font, at: codeInside, effectiveRange: nil) as? NSFont)?.isFixedPitch == true,
               "A backtick inside a longer code span remains monospaced literal content")
        let foldRoundTrip = "# Note\n## Heading ##\nBody\n"
        editor.setText(foldRoundTrip)
        _ = editor.toggleHeadingFold(atUTF16Index: 7)
        _ = editor.toggleHeadingFold(atUTF16Index: 7)
        expect(editor.text == foldRoundTrip, "Folding and unfolding do not accumulate heading whitespace")
        let trashFold = "# Note\n## Hidden <!-- {\"fold\":true} -->\nReadable in Trash\n"
        editor.setText(trashFold)
        editor.setEditable(false)
        expect(editor.toggleHeadingFold(atUTF16Index: 7), "Read-only notes can reveal already folded sections")
        expect(editor.textView.string.contains("Readable in Trash"), "Read-only unfolding reveals the body")
        expect(editor.text == trashFold, "Read-only unfolding never modifies the stored note")
        editor.setEditable(true)
        let bulk = "# Root\nIntro\n## One\nBody one\n### Child\nChild body\n## Two ##\nBody two\n"
        editor.setText(bulk)
        window.undoManager?.beginUndoGrouping()
        editor.setAllHeadingsFolded(true)
        window.undoManager?.endUndoGrouping()
        expect(!editor.textView.string.contains("Body one"), "Fold All hides every section body")
        expect(MarkdownPresentation.parse(editor.text).headings.allSatisfy(\.isFolded), "Fold All also remembers nested heading states")
        window.undoManager?.undo()
        expect(editor.text == bulk, "One undo restores all heading states exactly")
        window.undoManager?.redo()
        let allFolded = editor.text
        editor.setAllHeadingsFolded(false)
        expect(editor.text == bulk, "Unfold All restores exact Markdown including closing heading hashes")
        editor.selectSourceRange((bulk as NSString).range(of: "Body one"), scroll: false)
        editor.toggleCurrentHeadingFold()
        expect(!editor.textView.string.contains("Body one") && editor.textView.string.contains("Body two"), "The folding command targets the section containing the caret")
        editor.setText(allFolded)
        editor.setEditable(false)
        editor.setAllHeadingsFolded(false)
        expect(editor.textView.string.contains("Child body"), "Unfold All works in read-only notes")
        expect(editor.text == allFolded, "Read-only bulk folding preserves stored Markdown")
        editor.setEditable(true)
        editor.setText(bulk)
        editor.layoutSubtreeIfNeeded()
        if let manager = editor.textView.layoutManager, let container = editor.textView.textContainer {
            manager.ensureLayout(for: container)
            let headingSource = (editor.text as NSString).range(of: "## Two")
            editor.selectSourceRange(headingSource)
            editor.layoutSubtreeIfNeeded()
            let index = (editor.textView.string as NSString).range(of: "## Two").location
            let glyph = manager.glyphIndexForCharacter(at: index)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let arrow = NSPoint(x: editor.textView.textContainerOrigin.x - 14, y: editor.textView.textContainerOrigin.y + line.minY + 13)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.textView.convert(arrow, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let release = NSEvent.mouseEvent(with: .leftMouseUp, location: click.locationInWindow, modifierFlags: [], timestamp: 0.1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApp.postEvent(release, atStart: false)
            editor.textView.mouseDown(with: click)
            expect(!editor.textView.string.contains("Body two") && editor.textView.string.contains("Body one"), "Clicking a visible heading arrow folds precisely its section")
            editor.setText(bulk)
            editor.selectSourceRange((bulk as NSString).range(of: "Body one"), scroll: false)
            manager.ensureLayout(for: container)
            let headingPoint = NSPoint(x: editor.textView.textContainerOrigin.x + 100, y: editor.textView.textContainerOrigin.y + line.minY + 13)
            let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: editor.textView.convert(headingPoint, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
            if let menu = editor.textView.menu(for: rightClick), let action = menu.item(withTitle: "Fold Section") {
                menu.performActionForItem(at: menu.index(of: action))
                expect(!editor.textView.string.contains("Body two") && editor.textView.string.contains("Body one"), "Context-menu folding targets the clicked section even when the caret is elsewhere")
            } else { expect(false, "Heading context menu offers folding") }
        } else { expect(false, "Native heading controls have layout") }
        let numbered = "# Note\nIssue #17 and #১৭ with #work2026 and #project/123.\nEnd"
        editor.setText(numbered)
        for plain in ["#17", "#১৭"] {
            let range = (editor.textView.string as NSString).range(of: plain)
            expect(editor.textView.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil, "Numeric references are plain text, not highlighted tags")
        }
        let named = (editor.textView.string as NSString).range(of: "#work2026")
        expect(editor.textView.textStorage?.attribute(.backgroundColor, at: named.location, effectiveRange: nil) != nil, "Named tags with numbers keep their tag styling")
        expect(editor.text == numbered, "Tag filtering never removes numeric references from notes")
        let colored = "# Note\n\n```rust\npub struct CacheKey {\n    enabled: bool, // বাংলা comment\n    value: u8,\n}\n```\nEnd"
        editor.setText(colored)
        editor.selectSourceRange(NSRange(location: (colored as NSString).length, length: 0), scroll: false)
        let keywordIndex = (editor.textView.string as NSString).range(of: "pub").location
        let commentIndex = (editor.textView.string as NSString).range(of: "// বাংলা").location
        let keywordColor = editor.textView.textStorage?.attribute(.foregroundColor, at: keywordIndex, effectiveRange: nil) as? NSColor
        let commentColor = editor.textView.textStorage?.attribute(.foregroundColor, at: commentIndex, effectiveRange: nil) as? NSColor
        expect(keywordColor != nil && commentColor != nil && keywordColor != commentColor, "Rust keywords and comments receive distinct syntax colors in the native editor")
        editor.isDark = true
        let darkKeyword = editor.textView.textStorage?.attribute(.foregroundColor, at: keywordIndex, effectiveRange: nil) as? NSColor
        expect(darkKeyword != keywordColor, "Code highlighting adapts to dark appearance")
        editor.isDark = false
        let codeInsertion = (editor.text as NSString).range(of: "enabled").location
        editor.selectSourceRange(NSRange(location: codeInsertion, length: 0))
        editor.textView.insertText("🦥 ", replacementRange: editor.textView.selectedRange())
        let shiftedComment = (editor.textView.string as NSString).range(of: "// বাংলা").location
        expect(editor.textView.textStorage?.attribute(.foregroundColor, at: shiftedComment, effectiveRange: nil) as? NSColor == commentColor, "Incremental Unicode edits preserve subsequent code-token positions")
        expect(editor.text.contains("🦥 enabled: bool, // বাংলা comment"), "Highlighting never rewrites code or Unicode source")
        editor.setText("# Tags\n#work2026# #১২৩বাংলা #_17 #-17\nEnd")
        for name in ["#work2026#", "#১২৩বাংলা"] {
            let range = (editor.textView.string as NSString).range(of: name)
            expect(editor.textView.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil, "Editor highlights exactly the same named and closed tags as the sidebar")
        }
        for name in ["#_17", "#-17"] {
            let range = (editor.textView.string as NSString).range(of: name)
            expect(editor.textView.textStorage?.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil, "Invalid unclosed tags never receive misleading editor styling")
        }
        editor.setText("# Code\n```rust\nlet first = 1;\nlet second = 2;\n```\n")
        let firstKeyword = (editor.text as NSString).range(of: "let first").location
        editor.selectSourceRange(NSRange(location: firstKeyword, length: 0))
        editor.textView.insertText("/* ", replacementRange: editor.textView.selectedRange())
        var secondKeyword = (editor.textView.string as NSString).range(of: "let second").location
        expect(editor.textView.textStorage?.attribute(.foregroundColor, at: secondKeyword, effectiveRange: nil) as? NSColor == commentColor, "Opening a multiline comment recolors following code lines immediately")
        let endOfFirst = NSMaxRange((editor.text as NSString).range(of: "let first = 1;"))
        editor.selectSourceRange(NSRange(location: endOfFirst, length: 0))
        editor.textView.insertText(" */", replacementRange: editor.textView.selectedRange())
        secondKeyword = (editor.textView.string as NSString).range(of: "let second").location
        expect(editor.textView.textStorage?.attribute(.foregroundColor, at: secondKeyword, effectiveRange: nil) as? NSColor == keywordColor, "Closing a multiline comment restores following keyword colors immediately")
        let fixture = "# Markdown, quietly\n\nA **bold** thought, *gentle emphasis*, `inline code`, and a [useful link](https://example.com).\n\n## A folded section <!-- {\"fold\":true} -->\nThis body should not appear.\n\n## Code that stays readable\n\n```swift\nlet greeting = \"Hello, Sloth\"\n\nprint(greeting)\n```\n\n> A quiet quote with **emphasis**.\n\n---\n\nThe original Markdown is preserved."
        editor.setText(fixture)
        editor.selectSourceRange(NSRange(location: (fixture as NSString).length, length: 0), scroll: false)
        editor.restoreScrollPosition(.zero)
        editor.layoutSubtreeIfNeeded()
        if let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) {
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/private/tmp/sloth-markdown-presentation.png"))
            }
        }
        print("Passed \(assertions) editor presentation assertions")
        window.orderOut(nil)
    }
}
