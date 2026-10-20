import AppKit

/// Styled text used by the native table cell renderer. Parsing inline Markdown here
/// keeps the table source unchanged while the grid presents only readable content.
enum MarkdownTableInlineText {
    static func render(_ source: String, fontSize: CGFloat, header: Bool = false,
                       dark: Bool = false, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(1, fontSize * 0.12)
        let foreground = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.22, alpha: 1)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: header ? .semibold : .regular),
            .foregroundColor: foreground, .paragraphStyle: paragraph
        ]
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: fontSize * 0.91, weight: .regular)
                : NSFont.systemFont(ofSize: fontSize, weight: header || intent.contains(.stronglyEmphasized) ? .bold : .regular)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) {
                attributes[.backgroundColor] = dark ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.92, alpha: 1)
            }
            if let url = run.link, isSafeLink(url) {
                attributes[.link] = url
                attributes[.foregroundColor] = dark
                    ? NSColor(srgbRed: 0xE3 / 255.0, green: 0x6B / 255.0, blue: 0x64 / 255.0, alpha: 1)
                    : NSColor(srgbRed: 0xD6 / 255.0, green: 0x5A / 255.0, blue: 0x52 / 255.0, alpha: 1)
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func isSafeLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "mailto": return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == false
        default: return false
        }
    }
}

/// A temporary native field over the selected table cell. Commit callbacks carry
/// the untouched inline Markdown so the owner can use the note's normal undo path.
final class MarkdownTableCellEditor: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String, Int) -> Void)?
    var onCancel: (() -> Void)?
    private var completed = false

    init(frame: NSRect, text: String, fontSize: CGFloat, dark: Bool,
         alignment: NSTextAlignment = .left) {
        super.init(frame: frame)
        stringValue = text
        font = NSFont.systemFont(ofSize: fontSize)
        self.alignment = alignment
        isEditable = true
        isSelectable = true
        isBezeled = false
        isBordered = false
        drawsBackground = true
        backgroundColor = dark ? NSColor(white: 0.19, alpha: 1) : .textBackgroundColor
        textColor = dark ? NSColor(white: 0.9, alpha: 1) : .textColor
        focusRingType = .none
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        cell?.usesSingleLineMode = false
        cell?.lineBreakMode = .byWordWrapping
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 3
        delegate = self
        setAccessibilityLabel("Table cell")
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)):
            stringValue = textView.string
            finish(direction: 1)
        case #selector(NSResponder.insertBacktab(_:)):
            stringValue = textView.string
            finish(direction: -1)
        case #selector(NSResponder.insertNewline(_:)):
            stringValue = textView.string
            finish(direction: 0)
        case #selector(NSResponder.cancelOperation(_:)):
            guard !completed else { return true }
            completed = true
            onCancel?()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finish(direction: 0)
    }

    private func finish(direction: Int) {
        guard !completed else { return }
        completed = true
        onCommit?(stringValue, direction)
    }

    /// Preserve escaped pipes and code spans; escape only pipes that split a row.
    static func escapedCellText(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\u{2029}", with: " ")
        let characters = Array(singleLine)
        var output = ""
        var backslashes = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`", backslashes % 2 == 0 {
                var openingEnd = index
                while openingEnd < characters.count, characters[openingEnd] == "`" { openingEnd += 1 }
                let delimiterCount = openingEnd - index
                var closing = openingEnd
                var spanEnd: Int?
                while closing < characters.count {
                    if characters[closing] != "`" { closing += 1; continue }
                    var closingEnd = closing
                    while closingEnd < characters.count, characters[closingEnd] == "`" { closingEnd += 1 }
                    if closingEnd - closing == delimiterCount { spanEnd = closingEnd; break }
                    closing = closingEnd
                }
                if let spanEnd {
                    output += String(characters[index..<spanEnd])
                    index = spanEnd
                    backslashes = 0
                    continue
                }
                output += String(characters[index..<openingEnd])
                index = openingEnd
                backslashes = 0
                continue
            }
            if character == "|", backslashes % 2 == 0 { output.append("\\") }
            output.append(character)
            backslashes = character == "\\" ? backslashes + 1 : 0
            index += 1
        }
        return output
    }
}

/// Native table grid projected in place of the source table. Its geometry uses
/// the flipped coordinates of NSTextView so hit testing and the field editor agree.
final class MarkdownTableAttachmentCell: NSTextAttachmentCell {
    let table: MarkdownPresentation.Table
    private let source: NSString
    private let width: CGFloat
    private let dark: Bool
    private let texts: [[NSAttributedString]]
    private let layouts: [[TextLayout]]
    private let columnWidths: [CGFloat]
    private let rowHeights: [CGFloat]
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 8
    private let outerSpacing: CGFloat = 6

    init(table: MarkdownPresentation.Table, source: String, width: CGFloat, fontSize: CGFloat, dark: Bool) {
        self.table = table
        self.source = source as NSString
        self.width = max(1, width)
        self.dark = dark
        let nsSource = source as NSString
        let texts = table.rows.map { row in
            row.cells.enumerated().map { index, cell in
                MarkdownTableInlineText.render(nsSource.substring(with: cell.contentRange), fontSize: fontSize,
                    header: row.isHeader, dark: dark, alignment: Self.textAlignment(table.alignments[index]))
            }
        }
        self.texts = texts
        let widths = Self.allocateWidths(texts: texts, width: self.width, fontSize: fontSize)
        self.columnWidths = widths
        let layouts = texts.map { row in
            row.enumerated().map { TextLayout(text: $0.element, width: max(1, widths[$0.offset] - 20)) }
        }
        self.layouts = layouts
        self.rowHeights = layouts.map { row in
            row.reduce(max(34, fontSize * 1.5 + 16)) { max($0, ceil($1.manager.usedRect(for: $1.container).height) + 16) }
        }
        super.init(textCell: texts.map { $0.map(\.string).joined(separator: ", ") }.joined(separator: "; "))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: width, height: rowHeights.reduce(0, +) + outerSpacing * 2) }
    override func cellBaselineOffset() -> NSPoint { .zero }

    func cellFrame(row: Int, column: Int, in frame: NSRect) -> NSRect? {
        guard table.rows.indices.contains(row), columnWidths.indices.contains(column) else { return nil }
        return NSRect(x: frame.minX + columnWidths.prefix(column).reduce(0, +),
                      y: frame.minY + outerSpacing + rowHeights.prefix(row).reduce(0, +),
                      width: columnWidths[column], height: rowHeights[row])
    }

    func cellCoordinates(at point: NSPoint, in frame: NSRect) -> (row: Int, column: Int)? {
        guard point.x >= frame.minX, point.x < frame.minX + width,
              point.y >= frame.minY + outerSpacing, point.y < frame.minY + cellSize().height - outerSpacing else { return nil }
        var x = frame.minX
        var column = 0
        for (index, cellWidth) in columnWidths.enumerated() {
            if point.x < x + cellWidth { column = index; break }
            x += cellWidth
        }
        var y = frame.minY + outerSpacing
        for (row, height) in rowHeights.enumerated() {
            if point.y < y + height { return (row, column) }
            y += height
        }
        return nil
    }

    func sourceRange(row: Int, column: Int) -> NSRange? {
        guard table.rows.indices.contains(row), table.rows[row].cells.indices.contains(column) else { return nil }
        return table.rows[row].cells[column].contentRange
    }

    func sourceText(row: Int, column: Int) -> String? {
        sourceRange(row: row, column: column).map { source.substring(with: $0) }
    }

    func attributedText(row: Int, column: Int) -> NSAttributedString? {
        guard texts.indices.contains(row), texts[row].indices.contains(column) else { return nil }
        return texts[row][column]
    }

    /// Hit only a rendered link glyph, never the nearest character in cell padding
    /// or unused space. Drawing and hit testing share this native text layout.
    func link(at point: NSPoint, in frame: NSRect) -> URL? {
        guard let coordinate = cellCoordinates(at: point, in: frame),
              let cell = cellFrame(row: coordinate.row, column: coordinate.column, in: frame) else { return nil }
        let content = cell.insetBy(dx: horizontalPadding, dy: verticalPadding)
        guard content.contains(point) else { return nil }
        let layout = layouts[coordinate.row][coordinate.column]
        let localPoint = NSPoint(x: point.x - content.minX, y: point.y - content.minY)
        let glyph = layout.manager.glyphIndex(for: localPoint, in: layout.container)
        guard glyph < layout.manager.numberOfGlyphs else { return nil }
        let glyphBounds = layout.manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: layout.container)
        guard glyphBounds.contains(localPoint) else { return nil }
        let character = layout.manager.characterIndexForGlyph(at: glyph)
        guard character < layout.storage.length else { return nil }
        return texts[coordinate.row][coordinate.column].attribute(.link, at: character, effectiveRange: nil) as? URL
    }

    static func textAlignment(_ alignment: MarkdownPresentation.Alignment) -> NSTextAlignment {
        switch alignment {
        case .unspecified, .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let gridFrame = NSRect(x: cellFrame.minX + 0.5, y: cellFrame.minY + outerSpacing + 0.5,
            width: width - 1, height: rowHeights.reduce(0, +) - 1)
        let outline = NSBezierPath(roundedRect: gridFrame, xRadius: 4, yRadius: 4)
        outline.addClip()
        for row in table.rows.indices {
            guard let first = self.cellFrame(row: row, column: 0, in: cellFrame) else { continue }
            let rowFrame = NSRect(x: first.minX, y: first.minY, width: width, height: first.height)
            let background: NSColor
            if table.rows[row].isHeader {
                background = dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.94, alpha: 1)
            } else if row % 2 == 0 {
                background = dark ? NSColor(white: 0.175, alpha: 1) : NSColor(white: 0.985, alpha: 1)
            } else {
                background = dark ? NSColor(white: 0.15, alpha: 1) : .white
            }
            background.setFill()
            rowFrame.fill()
            for column in table.rows[row].cells.indices {
                guard let frame = self.cellFrame(row: row, column: column, in: cellFrame) else { continue }
                let content = frame.insetBy(dx: horizontalPadding, dy: verticalPadding)
                let layout = layouts[row][column]
                let glyphs = layout.manager.glyphRange(for: layout.container)
                layout.manager.drawBackground(forGlyphRange: glyphs, at: content.origin)
                layout.manager.drawGlyphs(forGlyphRange: glyphs, at: content.origin)
            }
        }
        let separators = NSBezierPath()
        var x = gridFrame.minX
        for columnWidth in columnWidths.dropLast() {
            x += columnWidth
            separators.move(to: NSPoint(x: x, y: gridFrame.minY))
            separators.line(to: NSPoint(x: x, y: gridFrame.maxY))
        }
        var y = gridFrame.minY
        for rowHeight in rowHeights.dropLast() {
            y += rowHeight
            separators.move(to: NSPoint(x: gridFrame.minX, y: y))
            separators.line(to: NSPoint(x: gridFrame.maxX, y: y))
        }
        (dark ? NSColor(white: 0.31, alpha: 1) : NSColor(white: 0.83, alpha: 1)).setStroke()
        separators.lineWidth = 0.75
        separators.stroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Reserve complete header words before giving descriptive columns extra
    /// room. A narrow index column should not force a medium header to split.
    private static func allocateWidths(texts: [[NSAttributedString]], width: CGFloat, fontSize: CGFloat) -> [CGFloat] {
        guard let headers = texts.first, !headers.isEmpty else { return [] }
        let minimums = headers.map { max(12, ceil(longestWordWidth($0))) + 20 }
        let preferredWords = headers.indices.map { column in
            max(minimums[column], min(fontSize * 8, texts.reduce(CGFloat(0)) { max($0, ceil(longestWordWidth($1[column])) + 20) }))
        }
        let preferred = headers.indices.map { column in
            texts.reduce(preferredWords[column]) { max($0, ceil($1[column].size().width) + 20) }
        }
        let minimumTotal = minimums.reduce(0, +)
        var widths: [CGFloat]
        if minimumTotal > width {
            // Keep padding and a usable glyph area in every column before
            // sharing the remaining space with oversized header words.
            let base = min(fontSize + 20, width / CGFloat(headers.count))
            let remaining = max(0, width - base * CGFloat(headers.count))
            let needs = minimums.map { max(0, $0 - base) }
            let total = needs.reduce(0, +)
            widths = needs.map { base + (total > 0 ? remaining * $0 / total : 0) }
        } else {
            widths = minimums
            var remaining = width - minimumTotal
            func grow(toward targets: [CGFloat]) {
                let needs = widths.indices.map { max(0, targets[$0] - widths[$0]) }
                let total = needs.reduce(0, +)
                guard total > 0, remaining > 0 else { return }
                let amount = min(remaining, total)
                for column in widths.indices { widths[column] += amount * needs[column] / total }
                remaining -= amount
            }
            grow(toward: preferredWords)
            grow(toward: preferred)
            if remaining > 0 {
                let total = preferred.reduce(0, +)
                for column in widths.indices { widths[column] += remaining * preferred[column] / total }
            }
        }
        // Absorb floating-point rounding so the last border matches the cell.
        widths[widths.count - 1] += width - widths.reduce(0, +)
        return widths
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static func longestWordWidth(_ text: NSAttributedString) -> CGFloat {
        wordPattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reduce(0) {
            max($0, text.attributedSubstring(from: $1.range).size().width)
        }
    }

    private final class TextLayout {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer

        init(text: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: text)
            // TextKit applies its own blue/underlined link drawing even when
            // foreground attributes are present. Keep URLs in the original
            // cell text for hit testing and draw only its explicit styling.
            storage.removeAttribute(.link, range: NSRange(location: 0, length: storage.length))
            container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
        }
    }

}
