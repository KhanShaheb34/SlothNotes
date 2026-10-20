import AppKit

extension NSAttributedString.Key {
    /// Set to true on completed Markdown punctuation that should have no glyph width.
    /// Characters stay in text storage, preserving source offsets, copy and input methods.
    static let markdownHiddenSyntax = NSAttributedString.Key("SlothHiddenSyntax")

    /// Apply one non-nil identifier to every character in a fenced code block.
    /// Adjacent blocks need different identifiers; inline styling may vary within a block.
    static let markdownCodeBlockID = NSAttributedString.Key("SlothCodeBlockID")
}

/// TextKit decoration for a source-preserving Markdown editor. Concealment changes
/// glyph generation, never the underlying characters or their UTF-16 indexes.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var codeBlockBackgroundColor = NSColor(srgbRed: 0.953, green: 0.961, blue: 0.969, alpha: 1) {
        didSet { if !codeBlockBackgroundColor.isEqual(oldValue) { invalidateCodeDecoration() } }
    }
    var codeBlockCornerRadius: CGFloat = 6 {
        didSet { if codeBlockCornerRadius != oldValue { invalidateCodeDecoration() } }
    }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// Call after changing visibility attributes, once the text storage editing
    /// transaction has ended. Custom attributes do not automatically regenerate
    /// cached glyphs, and merely invalidating display leaves their old advances.
    func invalidatePresentation(in requestedRange: NSRange) {
        guard let storage = textStorage else { return }
        let start = min(max(0, requestedRange.location == NSNotFound ? 0 : requestedRange.location), storage.length)
        let range = NSRange(location: start, length: min(max(0, requestedRange.length), storage.length - start))
        invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: range)
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var hasHiddenSyntax = false
        for index in 0..<glyphRange.length {
            let character = charIndexes[index]
            guard character >= 0, character < storage.length,
                  (storage.attribute(.markdownHiddenSyntax, at: character, effectiveRange: nil) as? Bool) == true else { continue }
            // Preserve control/combining properties and the original mapping;
            // TextKit ignores a null glyph for both layout and display.
            properties[index].insert(.null)
            hasHiddenSyntax = true
        }
        guard hasHiddenSyntax else { return 0 }
        properties.withUnsafeBufferPointer { values in
            setGlyphs(glyphs, properties: values.baseAddress!, characterIndexes: charIndexes,
                      font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    /// Returns full block rectangles for blocks touched by this redraw. Expanding
    /// the code attribute (not all attributes) keeps syntax-colored spans and
    /// empty paragraphs inside one continuous background. Coordinates are in the
    /// text container; callers apply NSTextView's textContainerOrigin when drawing.
    func codeBlockBackgroundRects(forGlyphRange glyphRange: NSRange) -> [NSRect] {
        guard glyphRange.length > 0, let storage = textStorage, storage.length > 0 else { return [] }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.location < storage.length else { return [] }
        let relevant = NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))
        guard relevant.length > 0 else { return [] }
        var blocks: [NSRange] = []
        storage.enumerateAttribute(.markdownCodeBlockID, in: relevant) { identifier, part, _ in
            guard identifier != nil else { return }
            var entireBlock = NSRange()
            _ = storage.attribute(.markdownCodeBlockID, at: part.location, longestEffectiveRange: &entireBlock,
                                  in: NSRange(location: 0, length: storage.length))
            if blocks.last != entireBlock { blocks.append(entireBlock) }
        }
        let requestedContainer = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil)
        return blocks.compactMap { block in
            let glyphs = self.glyphRange(forCharacterRange: block, actualCharacterRange: nil)
            var rectangle: NSRect?
            enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, _, _ in
                // drawBackground is scoped to one container. In a paginated text
                // system the next container's coordinates begin at zero again.
                guard container === requestedContainer else { return }
                rectangle = rectangle.map { $0.union(lineRect) } ?? lineRect
            }
            return rectangle
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        codeBlockBackgroundColor.setFill()
        for rectangle in codeBlockBackgroundRects(forGlyphRange: glyphsToShow) {
            let translated = rectangle.offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(roundedRect: translated, xRadius: codeBlockCornerRadius, yRadius: codeBlockCornerRadius).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Native selection, marked-text and inline background colors are drawn
        // above the block decoration, retaining normal editing feedback.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func invalidateCodeDecoration() {
        guard let storage = textStorage else { return }
        // An editor can configure decoration while restyling inside an outer
        // storage transaction. Display invalidation may generate glyphs, which
        // TextKit forbids until that transaction has ended. Mark the view dirty
        // without querying layout; the pending storage edit handles invalidation.
        guard storage.editedMask.isEmpty else {
            for container in textContainers { container.textView?.needsDisplay = true }
            return
        }
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
    }
}
