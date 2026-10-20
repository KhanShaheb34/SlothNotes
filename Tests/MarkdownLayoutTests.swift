import AppKit

/// Focused TextKit tests run in an unshown text container; no app windows are opened.
@main
enum MarkdownLayoutTests {
    private static var assertions = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    private static func fixture(_ value: String, width: CGFloat = 320) -> (NSTextStorage, MarkdownLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)])
        let manager = MarkdownLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: 100_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        return (storage, manager, container)
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let source = "## 🦥 Café **bold**"
        let (storage, manager, container) = fixture(source)
        let raw = source as NSString
        let opening = raw.range(of: "**")
        let closing = raw.range(of: "**", options: .backwards)
        let hidden = [NSRange(location: 0, length: 3), opening, closing]
        manager.ensureLayout(for: container)
        let rawWidth = manager.usedRect(for: container).width
        for range in hidden { storage.addAttribute(.markdownHiddenSyntax, value: true, range: range) }
        manager.invalidatePresentation(in: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)

        let (plainStorage, plainManager, plainContainer) = fixture("🦥 Café bold")
        plainManager.ensureLayout(for: plainContainer)
        let hiddenWidth = manager.usedRect(for: container).width
        expect(plainStorage.length > 0, "Reference layout keeps its backing text storage alive")
        expect(abs(hiddenWidth - plainManager.usedRect(for: plainContainer).width) < 0.5,
               "Completed Markdown punctuation occupies no horizontal layout space")
        expect(hiddenWidth < rawWidth, "Concealing markers changes layout rather than only their color")
        expect(storage.string == source, "Glyph concealment preserves the exact source and Unicode")
        let bold = raw.range(of: "bold")
        let boldGlyph = manager.glyphIndexForCharacter(at: bold.location)
        expect(manager.characterIndexForGlyph(at: boldGlyph) == bold.location,
               "Visible glyphs retain UTF-16 source indexes after concealed punctuation and emoji")
        expect(manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: opening.location)).contains(.null),
               "Hidden marker glyphs are marked null")
        expect(!manager.propertyForGlyph(at: boldGlyph).contains(.null), "Visible text retains its normal glyph properties")

        for range in hidden { storage.removeAttribute(.markdownHiddenSyntax, range: range) }
        manager.invalidatePresentation(in: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)
        expect(abs(manager.usedRect(for: container).width - rawWidth) < 0.5, "Revealing syntax restores the original geometry")
        expect(!manager.propertyForGlyph(at: manager.glyphIndexForCharacter(at: opening.location)).contains(.null),
               "Revealing syntax regenerates cached null glyphs")

        let code = "Heading\nlet value = 1\n\nprint(value)\nOutside\nsecond()\n"
        let (codeStorage, codeManager, codeContainer) = fixture(code, width: 280)
        let codeSource = code as NSString
        let firstStart = codeSource.range(of: "let value").location
        let firstEnd = codeSource.range(of: "Outside").location
        let firstBlock = NSRange(location: firstStart, length: firstEnd - firstStart)
        let secondBlock = codeSource.range(of: "second()\n")
        codeStorage.addAttribute(.markdownCodeBlockID, value: "first", range: firstBlock)
        codeStorage.addAttribute(.markdownCodeBlockID, value: "second", range: secondBlock)
        // Inline syntax coloring must not fragment the enclosing code background.
        codeStorage.addAttribute(.foregroundColor, value: NSColor.systemPurple,
                                 range: codeSource.range(of: "value"))
        codeManager.ensureLayout(for: codeContainer)
        let allGlyphs = codeManager.glyphRange(for: codeContainer)
        let blocks = codeManager.codeBlockBackgroundRects(forGlyphRange: allGlyphs)
        expect(blocks.count == 2, "Distinct fences receive separate continuous backgrounds")
        expect(abs(blocks[0].width - 280) < 0.5, "Code background extends across the container, beyond the text width")
        let firstGlyph = codeManager.glyphIndexForCharacter(at: firstStart)
        let lastGlyph = codeManager.glyphIndexForCharacter(at: firstEnd - 1)
        let firstLine = codeManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let lastLine = codeManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        expect(abs(blocks[0].minY - firstLine.minY) < 0.5 && abs(blocks[0].maxY - lastLine.maxY) < 0.5,
               "Code background continuously includes internal blank lines without consuming adjacent prose")
        let inside = codeManager.glyphRange(forCharacterRange: codeSource.range(of: "print(value)"), actualCharacterRange: nil)
        expect(codeManager.codeBlockBackgroundRects(forGlyphRange: inside) == [blocks[0]],
               "Partial redraw within a block retains its full continuous background geometry")
        let prose = codeManager.glyphRange(forCharacterRange: codeSource.range(of: "Outside"), actualCharacterRange: nil)
        expect(codeManager.codeBlockBackgroundRects(forGlyphRange: prose).isEmpty,
               "Ordinary prose has no fenced-code background")
        expect(codeStorage.string == code, "Code decoration never modifies the source")

        // Restyling can set theme configuration inside an outer text-storage
        // edit. Invalidating all display here would force generation of newly
        // inserted glyphs before the transaction is balanced and crash TextKit.
        let (editingStorage, editingManager, editingContainer) = fixture("Old")
        let editingView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), textContainer: editingContainer)
        editingManager.ensureLayout(for: editingContainer)
        editingManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: editingStorage.length),
                                       changeInLength: 0, actualCharacterRange: nil)
        editingStorage.beginEditing()
        editingStorage.replaceCharacters(in: NSRange(location: 0, length: editingStorage.length),
                                         with: "A replacement long enough to extend the existing glyph cache")
        editingManager.codeBlockBackgroundColor = .systemGray
        editingManager.codeBlockCornerRadius = 8
        editingStorage.endEditing()
        editingManager.ensureLayout(for: editingContainer)
        expect(editingView.string == editingStorage.string && editingManager.numberOfGlyphs == editingStorage.length,
               "Changing code decoration during an outer edit never generates premature glyphs")
        expect(editingManager.codeBlockBackgroundColor == .systemGray && editingManager.codeBlockCornerRadius == 8,
               "Decoration changes made during an edit apply when the text can be laid out")

        let (emptyStorage, emptyManager, emptyContainer) = fixture("")
        emptyManager.invalidatePresentation(in: NSRange(location: 0, length: emptyStorage.length))
        emptyManager.ensureLayout(for: emptyContainer)
        expect(emptyManager.codeBlockBackgroundRects(forGlyphRange: NSRange(location: 0, length: 0)).isEmpty,
               "Empty notes have no decoration and accept presentation invalidation")
        print("Markdown layout tests passed: \(assertions) assertions")
    }
}
