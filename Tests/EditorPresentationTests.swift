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
        let fixture = "# Markdown, quietly\n\nA **bold** thought, *gentle emphasis*, `inline code`, and a [useful link](https://example.com).\n\n## A folded section <!-- {\"fold\":true} -->\nThis body should not appear.\n\n## Code that stays readable\n\n```swift\nlet greeting = \"Hello, Sloth\"\n\nprint(greeting)\n```\n\nThe original Markdown is preserved."
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
