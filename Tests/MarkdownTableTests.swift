import AppKit

private final class TableDrawingView: NSView {
    let table: MarkdownTableAttachmentCell
    init(table: MarkdownTableAttachmentCell) {
        self.table = table
        super.init(frame: NSRect(origin: .zero, size: table.cellSize()))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { table.draw(withFrame: bounds, in: self) }
}

@main
enum MarkdownTableTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    /// Use native glyph geometry to click a known literal label in test content.
    static func point(over substring: String, in text: NSAttributedString, frame: NSRect) -> NSPoint {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let characters = (text.string as NSString).range(of: substring)
        let glyph = manager.glyphIndexForCharacter(at: characters.location)
        let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(x: frame.minX + bounds.midX, y: frame.minY + bounds.midY)
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let text = MarkdownTableInlineText.render("**Strong** and *soft* with `code` and [site](https://example.com)", fontSize: 16)
        expect(text.string == "Strong and soft with code and site", "Table cells hide Markdown delimiters and link destinations")
        let ns = text.string as NSString
        let bold = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Strong cell text stays visibly bold")
        let italic = text.attribute(.font, at: ns.range(of: "soft").location, effectiveRange: nil) as? NSFont
        expect(italic.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } == true, "Emphasis stays italic in a table")
        let code = text.attribute(.font, at: ns.range(of: "code").location, effectiveRange: nil) as? NSFont
        expect(code?.isFixedPitch == true, "Inline code has a monospaced font")
        expect((text.attribute(.link, at: ns.range(of: "site").location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com", "Cell link labels retain their safe URL")
        let escaped = MarkdownTableInlineText.render("a\\|b and \\*literal\\* 🦥", fontSize: 16)
        expect(escaped.string == "a|b and *literal* 🦥", "Escapes and Unicode render without exposing table syntax")
        let unsafe = MarkdownTableInlineText.render("[local](file:///tmp/private) [script](javascript:alert)", fontSize: 16)
        expect(unsafe.string == "local script", "Unsafe destinations remain readable labels")
        var unsafeLinks = 0
        unsafe.enumerateAttribute(.link, in: NSRange(location: 0, length: unsafe.length)) { value, _, _ in if value != nil { unsafeLinks += 1 } }
        expect(unsafeLinks == 0, "Unsafe destinations are never interactive")
        let field = MarkdownTableCellEditor(frame: NSRect(x: 0, y: 0, width: 180, height: 60), text: "old", fontSize: 16, dark: false)
        var commits: [(String, Int)] = []
        var cancellations = 0
        field.onCommit = { commits.append(($0, $1)) }
        field.onCancel = { cancellations += 1 }
        let fieldEditor = NSTextView()
        fieldEditor.string = "new|value"
        expect(field.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertTab(_:))), "Tab commits a table cell for keyboard navigation")
        expect(commits.count == 1 && commits[0].0 == "new|value" && commits[0].1 == 1, "Tab forwards the final field editor value and forward direction")
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        expect(commits.count == 1, "Removing a committed field cannot apply the edit twice")
        let cancelled = MarkdownTableCellEditor(frame: .zero, text: "original", fontSize: 16, dark: false)
        cancelled.onCommit = { commits.append(($0, $1)) }
        cancelled.onCancel = { cancellations += 1 }
        expect(cancelled.control(cancelled, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Escape closes a cell without saving")
        cancelled.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: cancelled))
        expect(cancellations == 1 && commits.count == 1, "Escape preserves the original cell even when the field loses focus")
        expect(MarkdownTableCellEditor.escapedCellText("one|two\\|three\nnext") == "one\\|two\\|three next", "Saving a cell escapes new pipes, keeps existing escapes, and keeps the table on one line")
        expect(MarkdownTableCellEditor.escapedCellText("`x|y` | tail") == "`x|y` \\| tail", "Saving code spans keeps their visible pipe literal while escaping real cell separators")
        let backtab = MarkdownTableCellEditor(frame: .zero, text: "old", fontSize: 16, dark: true)
        backtab.onCommit = { commits.append(($0, $1)) }
        expect(backtab.control(backtab, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertBacktab(_:))), "Backtab is handled by the table editor")
        expect(commits.last?.1 == -1, "Backtab moves to the previous table cell")
        let tableSource = "Before 🦥\n| Name | Count |\n| :--- | ---: |\n| **Café** | 12 |\n| Long wrapping text that needs several lines in a narrow column | 3 |\n"
        let table = MarkdownPresentation.parse(tableSource).tables[0]
        let grid = MarkdownTableAttachmentCell(table: table, source: tableSource, width: 420, fontSize: 16, dark: false)
        let narrowGrid = MarkdownTableAttachmentCell(table: table, source: tableSource, width: 220, fontSize: 16, dark: false)
        expect(grid.cellSize().width == 420 && grid.cellSize().height > 90, "A rendered table occupies a visible grid at the available width")
        expect(narrowGrid.cellSize().height > grid.cellSize().height, "Table rows grow to fit wrapped cell contents at narrow widths")
        let frame = NSRect(x: 30, y: 40, width: grid.cellSize().width, height: grid.cellSize().height)
        let headerFrame = grid.cellFrame(row: 0, column: 0, in: frame)!
        let numberFrame = grid.cellFrame(row: 1, column: 1, in: frame)!
        expect(headerFrame.width > numberFrame.width, "Description columns receive more width than compact numeric columns")
        expect(numberFrame.minY > headerFrame.minY && numberFrame.minX > headerFrame.minX, "Table cell frames place body rows below headers and columns side by side")
        let hit = grid.cellCoordinates(at: NSPoint(x: numberFrame.midX, y: numberFrame.midY), in: frame)
        expect(hit?.row == 1 && hit?.column == 1, "Clicking a visible cell resolves its original row and column")
        expect(grid.cellCoordinates(at: NSPoint(x: frame.minX - 2, y: frame.midY), in: frame) == nil, "Outside clicks do not start editing a table cell")
        expect(grid.cellFrame(row: 3, column: 0, in: frame) == nil && grid.sourceText(row: -1, column: 0) == nil, "Out-of-bounds cell requests are rejected")
        expect(grid.sourceText(row: 1, column: 0) == "**Café**", "Cell editors receive original inline Markdown without table padding")
        expect(grid.attributedText(row: 1, column: 0)?.string == "Café", "A grid draws formatted cell content without markers")
        let numberStyle = grid.attributedText(row: 1, column: 1)?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        expect(numberStyle?.alignment == .right, "Column alignment reaches the native renderer")
        let sourceRange = grid.sourceRange(row: 1, column: 0)!
        expect((tableSource as NSString).substring(with: sourceRange) == "**Café**", "Cell edits target exact UTF-16 source content after Unicode text")
        let linkSource = "| Content |\n| :--- |\n| Plain 🦥 [Café 🐻 link](https://example.com/notes) tail |\n| [local](file:///tmp/private) [script](javascript:alert) |\n"
        let linkTable = MarkdownPresentation.parse(linkSource).tables[0]
        let linkGrid = MarkdownTableAttachmentCell(table: linkTable, source: linkSource, width: 215, fontSize: 16, dark: false)
        let linkFrame = NSRect(x: 20, y: 30, width: linkGrid.cellSize().width, height: linkGrid.cellSize().height)
        let contentFrame = linkGrid.cellFrame(row: 1, column: 0, in: linkFrame)!.insetBy(dx: 10, dy: 8)
        let linkText = linkGrid.attributedText(row: 1, column: 0)!
        for label in ["Café", "🐻", "link"] {
            expect(linkGrid.link(at: point(over: label, in: linkText, frame: contentFrame), in: linkFrame)?.absoluteString == "https://example.com/notes", "Only actual Unicode link label glyphs open the table URL: \(label)")
        }
        for label in ["Plain", "🦥", "tail"] {
            expect(linkGrid.link(at: point(over: label, in: linkText, frame: contentFrame), in: linkFrame) == nil, "Neighboring text inside a linked cell is not clickable: \(label)")
        }
        let paddedPoint = NSPoint(x: contentFrame.minX - 5, y: contentFrame.minY + 4)
        expect(linkGrid.link(at: paddedPoint, in: linkFrame) == nil, "Cell padding cannot activate its nearest link")
        let blankPoint = NSPoint(x: contentFrame.maxX - 1, y: contentFrame.maxY - 1)
        expect(linkGrid.link(at: blankPoint, in: linkFrame) == nil, "Unused cell space cannot activate a nearby link")
        let deniedFrame = linkGrid.cellFrame(row: 2, column: 0, in: linkFrame)!.insetBy(dx: 10, dy: 8)
        let deniedText = linkGrid.attributedText(row: 2, column: 0)!
        for label in ["local", "script"] {
            expect(linkGrid.link(at: point(over: label, in: deniedText, frame: deniedFrame), in: linkFrame) == nil, "Denied schemes stay noninteractive in table hit testing")
        }
        for delimiter in [":---:", "---:"] {
            let alignedSource = "| Content |\n| \(delimiter) |\n| before [é 🦥](https://example.com/aligned) after |\n"
            let alignedTable = MarkdownPresentation.parse(alignedSource).tables[0]
            let alignedGrid = MarkdownTableAttachmentCell(table: alignedTable, source: alignedSource, width: 350, fontSize: 16, dark: true)
            let alignedFrame = NSRect(origin: .zero, size: alignedGrid.cellSize())
            let alignedContent = alignedGrid.cellFrame(row: 1, column: 0, in: alignedFrame)!.insetBy(dx: 10, dy: 8)
            let alignedText = alignedGrid.attributedText(row: 1, column: 0)!
            expect(alignedGrid.link(at: point(over: "🦥", in: alignedText, frame: alignedContent), in: alignedFrame)?.absoluteString == "https://example.com/aligned", "Aligned link hit testing follows the visible glyph position")
            expect(alignedGrid.link(at: NSPoint(x: alignedContent.minX + 1, y: alignedContent.minY + 2), in: alignedFrame) == nil, "Alignment whitespace does not activate the first visible link")
        }
        // TextKit can override link colors while drawing even when the source
        // attributes are correct, so verify actual pixels rather than attributes.
        let colorSource = "| Link |\n| --- |\n| [Sloth link](https://example.com) |\n"
        let colorTable = MarkdownPresentation.parse(colorSource).tables[0]
        for dark in [false, true] {
            let colorGrid = MarkdownTableAttachmentCell(table: colorTable, source: colorSource, width: 220, fontSize: 18, dark: dark)
            let preview = TableDrawingView(table: colorGrid)
            let imageWindow = NSWindow(contentRect: preview.bounds, styleMask: [], backing: .buffered, defer: false)
            imageWindow.contentView = preview
            guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { fatalError("Cannot render table test image") }
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            var accentPixels = 0
            var systemBluePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                    if color.redComponent > color.blueComponent + 0.2 && color.redComponent > color.greenComponent + 0.2 { accentPixels += 1 }
                    if color.blueComponent > color.redComponent + 0.2 && color.blueComponent > color.greenComponent + 0.2 { systemBluePixels += 1 }
                }
            }
            expect(accentPixels > 20 && systemBluePixels == 0, "Native table drawing preserves Sloth link accent in \(dark ? "dark" : "light") appearance")
            imageWindow.orderOut(nil)
        }
        let editing = MarkdownTableCellEditor(frame: .zero, text: "text", fontSize: 16, dark: false)
        editing.onCommit = { commits.append(($0, $1)) }
        editing.onCancel = { cancellations += 1 }
        let beforeArrows = (commits.count, cancellations)
        for selector in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:))] {
            expect(!editing.control(editing, textView: fieldEditor, doCommandBy: selector), "Arrow keys stay with native text editing in a table cell")
        }
        expect(commits.count == beforeArrows.0 && cancellations == beforeArrows.1, "Arrow movement neither commits nor cancels a table cell")
        print("Markdown table tests passed (\(assertions) assertions)")
    }
}
