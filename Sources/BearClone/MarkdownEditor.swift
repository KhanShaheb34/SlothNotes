import AppKit
import ImageIO
import Quartz

/// A Markdown-backed editor. The document remains portable Markdown while task markers
/// and local attachments are projected into native text attachments for editing.
final class MarkdownEditorView: NSView, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    var onSelectionChange: (() -> Void)?
    var attachmentResolver: ((String) -> URL?)? { didSet { rebuildProjection() } }
    var onImportFiles: (([URL]) -> [String])?
    var onImportImage: ((Data) -> String?)?
    var isDark = false { didSet { rebuildProjection() } }
    var fontSize: CGFloat = 16 { didSet { rebuildProjection() } }

    let textView: NSTextView
    private let scrollView = NSScrollView()
    private var markdown = ""
    private var isUpdating = false
    private var isStyling = false
    private var tokens: [ProjectionToken] = []
    private var attachmentPreview: AttachmentPreviewWindowController?
    private var composingSelection: NSRange?
    private var disabledCompositionUndo = false
    private var lastContentWidth: CGFloat = 0

    var text: String { markdown }
    var selectedSourceRange: NSRange { sourceRange(for: textView.selectedRange()) }
    var renderedAttachmentCount: Int { tokens.count }

    override init(frame frameRect: NSRect) {
        textView = MarkdownTextView(frame: .zero)
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        textView = MarkdownTextView(frame: .zero)
        super.init(coder: coder)
        configure()
    }

    private var bodyFont: NSFont { NSFont.systemFont(ofSize: fontSize) }
    private var foreground: NSColor { isDark ? NSColor(markdownHex: 0xDFE0E0) : NSColor(markdownHex: 0x444444) }
    private var secondary: NSColor { isDark ? NSColor(markdownHex: 0x969A9D) : NSColor(markdownHex: 0x929496) }
    private var marker: NSColor { isDark ? NSColor(markdownHex: 0x656A6E) : NSColor(markdownHex: 0xBDC0C2) }
    private var accent: NSColor { isDark ? NSColor(markdownHex: 0x44A2E5) : NSColor(markdownHex: 0xDD4C4F) }
    private var background: NSColor { isDark ? NSColor(markdownHex: 0x1D1E1F) : .white }
    private var contentWidth: CGFloat {
        max(160, min(620, textView.bounds.width - textView.textContainerInset.width * 2))
    }

    private func configure() {
        wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Note editor")
        textView.setAccessibilityHelp("Edit this note. Checkboxes are clickable. Attachments open in Quick Look. Changes save automatically.")
        scrollView.documentView = textView
        if let editor = textView as? MarkdownTextView {
            editor.onFormat = { [weak self] in self?.applyFormat($0) }
            editor.onAttachmentClick = { [weak self] in self?.activateAttachment(atDisplayIndex: $0) ?? false }
            editor.onReturn = { [weak self] in self?.continueList() ?? false }
            editor.onCopy = { [weak self] in
                guard let self else { return nil }
                return (self.markdown as NSString).substring(with: self.selectedSourceRange)
            }
            editor.onPasteFiles = { [weak self] urls in self?.importFiles(urls) ?? false }
            editor.onPasteImage = { [weak self] data in
                guard let self, let snippet = self.onImportImage?(data) else { return false }
                self.insertMarkdown(snippet); return true
            }
            editor.onCompositionStart = { [weak self] in self?.beginComposition() }
            editor.onCompositionEnd = { [weak self] in self?.finishComposition() }
            editor.registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        }
        rebuildProjection()
    }

    override func layout() {
        super.layout()
        let width = max(0, scrollView.contentSize.width)
        let inset: CGFloat = width < 440 ? 28 : max(48, (width - 760) / 2)
        textView.textContainerInset = NSSize(width: inset, height: 56)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height)))
        }
        if abs(contentWidth - lastContentWidth) > 1 {
            lastContentWidth = contentWidth
            if tokens.contains(where: { $0.kind != .checkbox }) { rebuildProjection() }
        }
    }

    /// A selected note starts a fresh undo history, even if its text is unchanged.
    func setText(_ text: String) {
        isUpdating = true
        markdown = text
        rebuildProjection(sourceSelection: NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
        isUpdating = false
    }

    /// Re-resolve downloaded or restored attachment files without resetting the caret or undo.
    func refreshAttachments() { rebuildProjection() }

    func focus() { window?.makeFirstResponder(textView) }
    func setEditable(_ editable: Bool) { textView.isEditable = editable }

    func selectSourceRange(_ range: NSRange, scroll: Bool = true) {
        let selected = displayRange(for: clamped(range, length: (markdown as NSString).length))
        textView.setSelectedRange(selected)
        if scroll { textView.scrollRangeToVisible(selected) }
    }

    /// Inserts source at the visual caret. Attachment snippets use their own paragraph.
    func insertMarkdown(_ snippet: String) {
        guard textView.isEditable else { return }
        let range = selectedSourceRange
        let source = markdown as NSString
        var insertion = snippet
        if range.location > 0, source.substring(with: NSRange(location: range.location - 1, length: 1)) != "\n" {
            insertion = "\n" + insertion
        }
        if !insertion.hasSuffix("\n") { insertion += "\n" }
        replace(range, with: insertion,
                selection: NSRange(location: range.location + (insertion as NSString).length, length: 0),
                actionName: "Insert Attachment")
    }

    @discardableResult
    private func importFiles(_ urls: [URL]) -> Bool {
        guard textView.isEditable, !urls.isEmpty, let snippets = onImportFiles?(urls), !snippets.isEmpty else { return false }
        insertMarkdown(snippets.joined(separator: "\n\n")); return true
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isUpdating { return true }
        guard textView.isEditable else { return false }
        if (textView as? MarkdownTextView)?.isHandlingMarkedText == true || textView.hasMarkedText() { return true }
        guard let replacementString else { return false }
        let range = sourceRange(for: affectedCharRange)
        replace(range, with: replacementString,
                selection: NSRange(location: range.location + (replacementString as NSString).length, length: 0),
                actionName: "Edit Note")
        return false
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, composingSelection == nil, !textView.hasMarkedText() else { return }
        // Some text-system operations bypass shouldChangeText. Reconstruct Markdown
        // from attachment metadata before applying the same undoable source update.
        let value = serializedStorage()
        if value != markdown {
            let selection = serializedSelection()
            commit(value, selection: selection, actionName: "Edit Note")
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, !isStyling else { return }
        if !textView.hasMarkedText() { textView.typingAttributes = defaultAttributes() }
        onSelectionChange?()
    }

    private func beginComposition() {
        guard composingSelection == nil else { return }
        composingSelection = selectedSourceRange
        if textView.undoManager?.isUndoRegistrationEnabled == true {
            textView.undoManager?.disableUndoRegistration(); disabledCompositionUndo = true
        }
    }

    private func finishComposition() {
        guard let previousSelection = composingSelection, !textView.hasMarkedText() else { return }
        let value = serializedStorage()
        let selection = serializedSelection()
        composingSelection = nil
        if disabledCompositionUndo { textView.undoManager?.enableUndoRegistration(); disabledCompositionUndo = false }
        commit(value, selection: selection, actionName: "Edit Note", previousSelection: previousSelection)
    }

    private func serializedStorage(range: NSRange? = nil) -> String {
        guard let storage = textView.textStorage else { return textView.string }
        let range = range ?? NSRange(location: 0, length: storage.length)
        var result = ""
        storage.enumerateAttribute(.attachment, in: range) { value, piece, _ in
            if let attachment = value as? MarkdownAttachment {
                result += attachment.markdown
            } else {
                result += (storage.string as NSString).substring(with: piece)
            }
        }
        return result
    }

    private func serializedSelection() -> NSRange {
        let selected = textView.selectedRange()
        let before = serializedStorage(range: NSRange(location: 0, length: selected.location))
        let inside = serializedStorage(range: selected)
        return NSRange(location: (before as NSString).length, length: (inside as NSString).length)
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
        let start = max(0, min(range.location == NSNotFound ? 0 : range.location, length))
        return NSRange(location: start, length: max(0, min(range.length, length - start)))
    }

    private func sourceOffset(forDisplayOffset offset: Int) -> Int {
        var difference = 0
        for token in tokens {
            if offset <= token.displayRange.location { break }
            difference += token.sourceRange.length - token.displayRange.length
        }
        return max(0, min(offset + difference, (markdown as NSString).length))
    }

    private func displayOffset(forSourceOffset offset: Int, trailing: Bool = false) -> Int {
        var difference = 0
        for token in tokens {
            if offset < token.sourceRange.location { break }
            if offset < NSMaxRange(token.sourceRange) {
                return token.displayRange.location + (trailing && offset > token.sourceRange.location ? 1 : 0)
            }
            difference += token.sourceRange.length - token.displayRange.length
        }
        return max(0, offset - difference)
    }

    private func sourceRange(for display: NSRange) -> NSRange {
        let safe = clamped(display, length: (textView.string as NSString).length)
        let start = sourceOffset(forDisplayOffset: safe.location)
        let end = sourceOffset(forDisplayOffset: NSMaxRange(safe))
        return NSRange(location: start, length: end - start)
    }

    private func displayRange(for source: NSRange) -> NSRange {
        let start = displayOffset(forSourceOffset: source.location)
        let end = displayOffset(forSourceOffset: NSMaxRange(source), trailing: source.length > 0)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func rebuildProjection(sourceSelection: NSRange? = nil) {
        guard composingSelection == nil, !textView.hasMarkedText() else { return }
        let selection = sourceSelection ?? selectedSourceRange
        let visibleOrigin = scrollView.contentView.bounds.origin
        let previousUpdating = isUpdating
        isUpdating = true
        let source = markdown as NSString
        tokens = []
        var candidates: [(NSRange, ProjectionToken.Kind, Bool, String?, String?)] = []
        let all = NSRange(location: 0, length: source.length)
        if let expression = try? NSRegularExpression(pattern: "^([ \\t]*)([-+*][ \\t]+\\[[ xX]\\])([ \\t]*)(?=$|[^\\r\\n])", options: [.anchorsMatchLines]) {
            for match in expression.matches(in: markdown, range: all) {
                let start = match.range(at: 2).location
                let range = NSRange(location: start, length: NSMaxRange(match.range) - start)
                // A marker needs a separator, or to be the whole otherwise-empty line.
                let end = NSMaxRange(match.range(at: 2))
                let separator = end == source.length || [" ", "\t", "\r", "\n"].contains(source.substring(with: NSRange(location: min(end, max(0, source.length - 1)), length: source.length > 0 ? 1 : 0)))
                if separator && !isInsideCodeFence(before: source.lineRange(for: match.range).location, in: source) {
                    candidates.append((range, .checkbox, source.substring(with: range).lowercased().contains("[x]"), nil, nil))
                }
            }
        }
        if let expression = try? NSRegularExpression(pattern: "(!?)\\[([^\\]\\n]*)\\]\\((attachments/[^\\s)]+)\\)") {
            for match in expression.matches(in: markdown, range: all) {
                if !isInsideCodeFence(before: source.lineRange(for: match.range).location, in: source) && !isInsideInlineCode(at: match.range.location, in: source) {
                    candidates.append((match.range, match.range(at: 1).length > 0 ? .image : .file, false,
                                       source.substring(with: match.range(at: 3)), source.substring(with: match.range(at: 2))))
                }
            }
        }
        candidates.sort { $0.0.location < $1.0.location }
        let result = NSMutableAttributedString()
        var sourceCursor = 0
        for (range, kind, checked, path, name) in candidates {
            guard range.location >= sourceCursor else { continue }
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: sourceCursor, length: range.location - sourceCursor))))
            let literal = source.substring(with: range)
            let attachment = MarkdownAttachment(markdown: literal)
            let url = path.flatMap { attachmentResolver?($0) }
            let cell: NSTextAttachmentCell
            if kind == .checkbox {
                cell = CheckboxAttachmentCell(checked: checked, size: fontSize, dark: isDark, accent: accent)
            } else {
                cell = FileAttachmentCell(url: url, name: name ?? "Attachment", isImage: kind == .image,
                                          width: contentWidth, dark: isDark)
            }
            attachment.attachmentCell = cell
            tokens.append(ProjectionToken(sourceRange: range, displayRange: NSRange(location: result.length, length: 1), kind: kind, url: url, name: name, attachment: attachment))
            result.append(NSAttributedString(attachment: attachment))
            sourceCursor = NSMaxRange(range)
        }
        result.append(NSAttributedString(string: source.substring(from: sourceCursor)))
        textView.textStorage?.setAttributedString(result)
        restyle()
        textView.setSelectedRange(displayRange(for: clamped(selection, length: source.length)))
        textView.typingAttributes = defaultAttributes()
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isUpdating = previousUpdating
    }

    private func isInsideInlineCode(at offset: Int, in source: NSString) -> Bool {
        let line = source.lineRange(for: NSRange(location: offset, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: offset - line.location))
        return prefix.filter { $0 == "`" }.count % 2 == 1
    }
    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.42
        paragraph.paragraphSpacing = fontSize * 0.28
        return [.font: bodyFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    private func restyle() {
        guard !isStyling else { return }
        textView.backgroundColor = background
        textView.insertionPointColor = accent
        textView.selectedTextAttributes = [.backgroundColor: isDark ? NSColor(markdownHex: 0x454D56) : NSColor(markdownHex: 0xD3E6FB)]
        scrollView.backgroundColor = background
        layer?.backgroundColor = background.cgColor
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        isStyling = true
        defer { isStyling = false }
        let content = textView.string as NSString
        let full = NSRange(location: 0, length: content.length)
        let selections = textView.selectedRanges
        storage.beginEditing()
        storage.setAttributes(defaultAttributes(), range: full)

        func matches(_ pattern: String, options: NSRegularExpression.Options = [.anchorsMatchLines], _ body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: content as String, range: full) { result, _, _ in
                if let result = result { body(result) }
            }
        }
        func style(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            guard range.location != NSNotFound, NSMaxRange(range) <= content.length else { return }
            storage.addAttributes(attributes, range: range)
        }
        func fontTrait(_ trait: NSFontTraitMask, _ range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, fontRange, _ in
                let font = (value as? NSFont) ?? bodyFont
                style([.font: NSFontManager.shared.convert(font, toHaveTrait: trait)], fontRange)
            }
        }
        func dim(_ match: NSTextCheckingResult, _ groups: [Int]) {
            for group in groups { style([.foregroundColor: marker], match.range(at: group)) }
        }

        // The first line is a note title even when it has no explicit Markdown heading.
        if content.length > 0, !tokens.contains(where: { content.lineRange(for: $0.displayRange).location == 0 }) {
            let first = content.lineRange(for: NSRange(location: 0, length: 0))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 16
            style([.font: NSFont.systemFont(ofSize: fontSize * 1.75, weight: .semibold), .paragraphStyle: paragraph], first)
        }
        matches("^(#{1,6})([ \\t]+)(.+)$") { match in
            let level = match.range(at: 1).length
            let scale: CGFloat = level == 1 ? 1.75 : level == 2 ? 1.375 : level == 3 ? 1.2 : 1.06
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacingBefore = level == 1 ? 0 : 14
            paragraph.paragraphSpacing = 10
            style([.font: NSFont.systemFont(ofSize: fontSize * scale, weight: .semibold), .paragraphStyle: paragraph], match.range)
            dim(match, [1])
        }
        matches("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)(\\1)", options: []) { match in
            fontTrait(.boldFontMask, match.range(at: 2))
            dim(match, [1, 3])
        }
        matches("(?<!\\*)(\\*)(?!\\*|\\s)(.+?)(?<!\\s)(\\*)(?!\\*)", options: []) { match in
            fontTrait(.italicFontMask, match.range(at: 2))
            dim(match, [1, 3])
        }
        matches("(~~)(.+?)(~~)", options: []) { match in
            style([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: secondary], match.range(at: 2))
            dim(match, [1, 3])
        }
        matches("(==)(.+?)(==)", options: []) { match in
            style([.backgroundColor: isDark ? NSColor(markdownHex: 0x355F3A) : NSColor(markdownHex: 0xD3FFA4)], match.range(at: 2))
            dim(match, [1, 3])
        }
        matches("(^|[ \\t])(#(?:[\\p{L}\\p{N}_-]+)(?:/[\\p{L}\\p{N}_-]+)*)(?=$|[ \\t.,!?])") { match in
            style([.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.08)], match.range(at: 2))
        }
        matches("(\\[\\[)([^\\]\\n]+)(\\]\\])", options: []) { match in
            style([.foregroundColor: accent], match.range(at: 2)); dim(match, [1, 3])
        }
        matches("(\\[)([^\\]\\n]+)(\\]\\()([^\\s)]+)(\\))", options: []) { match in
            style([.foregroundColor: accent], match.range(at: 2))
            style([.foregroundColor: secondary], match.range(at: 4)); dim(match, [1, 3, 5])
        }
        matches("https?://[^\\s<>\\])]+", options: []) { match in
            style([.foregroundColor: accent], match.range)
        }
        matches("^([ \\t]*)([-+*]|[0-9]+\\.)([ \\t]+)") { match in
            style([.foregroundColor: accent], match.range(at: 2))
        }
        matches("^([ \\t]*[-+*][ \\t]+)(\\[[ xX]\\])([ \\t]+)(.*)$") { match in
            style([.foregroundColor: accent, .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)], match.range(at: 2))
            if content.substring(with: match.range(at: 2)).lowercased() == "[x]" {
                style([.foregroundColor: secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue], match.range(at: 4))
            }
        }
        matches("^(>[ \\t]?)(.*)$") { match in
            style([.foregroundColor: secondary, .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)], match.range)
            style([.foregroundColor: accent], match.range(at: 1))
        }
        matches("^([ \\t]*)(-{3,}|\\*{3,}|_{3,})[ \\t]*$") { match in
            style([.foregroundColor: marker], match.range)
        }
        let codeBackground = isDark ? NSColor(markdownHex: 0x2E2F30) : NSColor(markdownHex: 0xF3F5F7)
        let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.88, weight: .regular)
        matches("(?<!`)(`)([^`\\n]+)(`)(?!`)", options: []) { match in
            style([.font: codeFont, .foregroundColor: foreground, .backgroundColor: codeBackground], match.range)
            dim(match, [1, 3])
        }
        // Code blocks are styled last, so Markdown punctuation inside is ordinary code.
        matches("^(```[^\\n]*\\n)([\\s\\S]*?)(^```[ \\t]*$|\\z)") { match in
            style([.font: codeFont, .foregroundColor: foreground, .backgroundColor: codeBackground, .strikethroughStyle: 0], match.range)
            dim(match, [1, 3])
        }
        for token in tokens {
            style([.attachment: token.attachment, .font: bodyFont], token.displayRange)
            if token.kind == .checkbox {
                let line = content.lineRange(for: token.displayRange)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = fontSize * 0.42
                paragraph.paragraphSpacing = fontSize * 0.28
                paragraph.headIndent = fontSize * 2.05
                style([.paragraphStyle: paragraph], line)
                if token.attachment.markdown.lowercased().contains("[x]") {
                    let label = NSRange(location: NSMaxRange(token.displayRange), length: max(0, NSMaxRange(line) - NSMaxRange(token.displayRange)))
                    style([.foregroundColor: secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue], label)
                }
            }
        }
        storage.endEditing()
        textView.selectedRanges = selections
        textView.typingAttributes = defaultAttributes()
    }

    /// Toggles only the checkbox marker of a Markdown task, outside fenced code.
    /// The index uses NSTextView's UTF-16 offsets and must be inside `[ ]` or `[x]`.
    @discardableResult
    func toggleTodo(atUTF16Index index: Int) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        let source = markdown as NSString
        guard index >= 0, index < source.length else { return false }
        let lineRange = source.lineRange(for: NSRange(location: index, length: 0))
        guard !isInsideCodeFence(before: lineRange.location, in: source) else { return false }
        let line = source.substring(with: lineRange) as NSString
        guard let expression = try? NSRegularExpression(pattern: "^[ \\t]*[-+*][ \\t]+(\\[[ xX]\\])(?=[ \\t\\r\\n]|$)"),
              let match = expression.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return false }
        let markerRange = NSRange(location: lineRange.location + match.range(at: 1).location, length: 3)
        guard NSLocationInRange(index, markerRange) else { return false }
        let replacement = source.substring(with: markerRange) == "[ ]" ? "[x]" : "[ ]"
        return replace(markerRange, with: replacement, selection: selectedSourceRange,
                       actionName: "Toggle Todo", scrollToSelection: false)
    }

    private func isInsideCodeFence(before lineStart: Int, in source: NSString) -> Bool {
        guard lineStart > 0 else { return false }
        let preceding = source.substring(to: lineStart)
        var openingCharacter: Character?
        var openingLength = 0
        for line in preceding.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let runLength = trimmed.prefix(while: { $0 == first }).count
            guard runLength >= 3 else { continue }
            if let current = openingCharacter {
                if first == current, runLength >= openingLength,
                   trimmed.dropFirst(runLength).trimmingCharacters(in: .whitespaces).isEmpty {
                    openingCharacter = nil
                    openingLength = 0
                }
            } else {
                openingCharacter = first
                openingLength = runLength
            }
        }
        return openingCharacter != nil
    }

    /// Inserts or toggles Markdown around the current selection as one undoable edit.
    func applyFormat(_ format: String) {
        guard textView.isEditable else { return }
        focus()
        let source = markdown as NSString
        let range = selectedSourceRange
        guard NSMaxRange(range) <= source.length else { return }
        let selected = source.substring(with: range)
        let wrappers: [String: (String, String, String)] = [
            "bold": ("**", "**", "bold text"),
            "italic": ("*", "*", "italic text"),
            "strike": ("~~", "~~", "text"),
            "code": ("`", "`", "code"),
            "link": ("[", "](https://)", "link text")
        ]
        if let (prefix, suffix, placeholder) = wrappers[format] {
            let beforeLength = (prefix as NSString).length
            let afterLength = (suffix as NSString).length
            if range.length > 0, range.location >= beforeLength,
               NSMaxRange(range) + afterLength <= source.length,
               source.substring(with: NSRange(location: range.location - beforeLength, length: beforeLength)) == prefix,
               source.substring(with: NSRange(location: NSMaxRange(range), length: afterLength)) == suffix {
                replace(NSRange(location: range.location - beforeLength, length: range.length + beforeLength + afterLength),
                        with: selected, selection: NSRange(location: range.location - beforeLength, length: range.length))
            } else {
                let inner = selected.isEmpty ? placeholder : selected
                replace(range, with: prefix + inner + suffix,
                        selection: NSRange(location: range.location + beforeLength, length: (inner as NSString).length))
            }
            return
        }
        let prefixes = ["heading": "## ", "bullet": "- ", "todo": "- [ ] ", "quote": "> "]
        guard let prefix = prefixes[format] else { return }
        var lineRange = source.lineRange(for: range)
        // A selection ending at the start of another line must not format that next line.
        if range.length > 0, NSMaxRange(range) < source.length,
           source.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" {
            lineRange = source.lineRange(for: NSRange(location: range.location, length: range.length - 1))
        }
        let lines = source.substring(with: lineRange)
        let trailingNewline = lines.hasSuffix("\n")
        var parts = lines.components(separatedBy: "\n")
        if trailingNewline { parts.removeLast() }
        let remove = parts.allSatisfy { $0.hasPrefix(prefix) }
        let replacement = parts.map { line -> String in
            if remove { return String(line.dropFirst(prefix.count)) }
            if format == "heading" {
                return prefix + line.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            }
            return prefix + line
        }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        replace(lineRange, with: replacement,
                selection: NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    /// Return continues a task, while Return on an empty task exits the list.
    @discardableResult
    func continueList() -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        let range = selectedSourceRange
        let source = markdown as NSString
        let lineRange = source.lineRange(for: range)
        guard !isInsideCodeFence(before: lineRange.location, in: source) else { return false }
        let line = source.substring(with: lineRange) as NSString
        guard let regex = try? NSRegularExpression(pattern: "^([ \\t]*)([-+*][ \\t]+)\\[[ xX]\\]([ \\t]*)(.*?)(?:\\r?\\n)?$"),
              let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return false }
        let body = line.substring(with: match.range(at: 4))
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bodyStart = lineRange.location + match.range(at: 4).location
            return replace(NSRange(location: lineRange.location, length: bodyStart - lineRange.location), with: "",
                           selection: NSRange(location: lineRange.location, length: 0), actionName: "End Checklist")
        }
        let prefix = line.substring(with: match.range(at: 1)) + line.substring(with: match.range(at: 2)) + "[ ] "
        let insertion = "\n" + prefix
        return replace(range, with: insertion,
                       selection: NSRange(location: range.location + (insertion as NSString).length, length: 0), actionName: "Continue Checklist")
    }

    @discardableResult
    private func replace(_ range: NSRange, with replacement: String, selection: NSRange,
                         actionName: String = "Format Note", scrollToSelection: Bool = true) -> Bool {
        guard textView.isEditable, NSMaxRange(range) <= (markdown as NSString).length else { return false }
        let next = (markdown as NSString).replacingCharacters(in: range, with: replacement)
        commit(next, selection: selection, actionName: actionName)
        if scrollToSelection { textView.scrollRangeToVisible(textView.selectedRange()) }
        return true
    }

    private func commit(_ value: String, selection: NSRange, actionName: String, previousSelection: NSRange? = nil) {
        guard value != markdown else { selectSourceRange(selection); return }
        let previousText = markdown
        let previousRange = previousSelection ?? selectedSourceRange
        let previousUpdating = isUpdating
        isUpdating = true
        markdown = value
        rebuildProjection(sourceSelection: selection)
        isUpdating = previousUpdating
        textView.undoManager?.registerUndo(withTarget: self) { target in
            target.commit(previousText, selection: previousRange, actionName: actionName)
        }
        textView.undoManager?.setActionName(actionName)
        onChange?(markdown)
    }

    private func activateAttachment(atDisplayIndex index: Int) -> Bool {
        guard let token = tokens.first(where: { $0.displayRange.location == index }) else { return false }
        if token.kind == .checkbox {
            let marker = (token.attachment.markdown as NSString).range(of: "[")
            return toggleTodo(atUTF16Index: token.sourceRange.location + marker.location + 1)
        }
        guard let url = token.url, FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return true }
        // A dedicated view owns its preview item directly. Shared QLPreviewPanel
        // changes controllers with the responder chain and can clear that selection.
        if attachmentPreview == nil {
            let preview = AttachmentPreviewWindowController()
            preview.onClose = { [weak self, weak preview] in
                guard let self, let preview, self.attachmentPreview === preview,
                      preview.window?.isVisible != true else { return }
                self.attachmentPreview = nil
            }
            attachmentPreview = preview
        }
        attachmentPreview?.showAttachment(url, name: token.name ?? url.lastPathComponent, sourceWindow: window)
        return true
    }

}

private struct ProjectionToken {
    enum Kind { case checkbox, image, file }
    let sourceRange: NSRange
    let displayRange: NSRange
    let kind: Kind
    let url: URL?
    let name: String?
    let attachment: MarkdownAttachment
}

/// Keeps the preview item alive independently of text selection and responder changes.
private final class AttachmentPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView: QLPreviewView
    private var item: AttachmentPreviewItem?
    private weak var sourceWindow: NSWindow?
    var onClose: (() -> Void)?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 780, height: 600)
        let window = AttachmentPreviewWindow(contentRect: frame,
                                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                             backing: .buffered, defer: false)
        previewView = QLPreviewView(frame: frame, style: .normal)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)
        window.contentView = previewView
        window.delegate = self
        window.center()
        previewView.autoresizingMask = [.width, .height]
        previewView.shouldCloseWithWindow = false
        previewView.autostarts = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { previewView.close() }

    func showAttachment(_ url: URL, name: String, sourceWindow: NSWindow?) {
        self.sourceWindow = sourceWindow
        item = AttachmentPreviewItem(url: url, name: name)
        window?.title = name
        previewView.previewItem = item
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        previewView.previewItem = nil
        item = nil
        let origin = sourceWindow
        // Restore focus after AppKit finishes closing the preview, then release
        // this window outside its own close callback. The next preview is fresh.
        DispatchQueue.main.async { [weak self, weak origin] in
            if let origin, origin.isVisible { origin.makeKeyAndOrderFront(nil) }
            self?.onClose?()
        }
    }
}

private final class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, name: String) { previewItemURL = url; previewItemTitle = name; super.init() }
}

private final class AttachmentPreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil) } else { super.keyDown(with: event) }
    }
}

private final class MarkdownAttachment: NSTextAttachment {
    let markdown: String
    init(markdown: String) { self.markdown = markdown; super.init(data: nil, ofType: nil) }
    required init?(coder: NSCoder) { markdown = coder.decodeObject(forKey: "markdown") as? String ?? ""; super.init(coder: coder) }
    override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(markdown, forKey: "markdown") }
}

private final class CheckboxAttachmentCell: NSTextAttachmentCell {
    let checked: Bool
    let size: CGFloat
    let dark: Bool
    let accent: NSColor

    init(checked: Bool, size: CGFloat, dark: Bool, accent: NSColor) {
        self.checked = checked; self.size = size; self.dark = dark; self.accent = accent
        super.init(textCell: checked ? "Checked task" : "Unchecked task")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: size * 2.05, height: size * 1.23) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -size * 0.23) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let side = max(19, size * 1.06)
        let bounds = NSRect(x: cellFrame.minX + 0.9, y: cellFrame.minY + (cellFrame.height - side) / 2,
                            width: side, height: side).integral.insetBy(dx: 0.7, dy: 0.7)
        let path = NSBezierPath(roundedRect: bounds, xRadius: size * 0.29, yRadius: size * 0.29)
        path.lineWidth = max(1.4, size * 0.09)
        if checked { accent.setFill(); path.fill(); accent.setStroke() }
        else { (dark ? NSColor(markdownHex: 0x92969A) : NSColor(markdownHex: 0x909090)).setStroke() }
        path.stroke()
        if checked {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: bounds.minX + side * 0.21, y: bounds.minY + side * 0.49))
            check.line(to: NSPoint(x: bounds.minX + side * 0.40, y: bounds.minY + side * 0.69))
            check.line(to: NSPoint(x: bounds.minX + side * 0.76, y: bounds.minY + side * 0.29))
            check.lineWidth = max(1.4, size * 0.10); check.lineCapStyle = .round; check.lineJoinStyle = .round
            NSColor.white.setStroke(); check.stroke()
        }
    }
}

private final class FileAttachmentCell: NSTextAttachmentCell {
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()

    private static func thumbnail(for url: URL) -> NSImage? {
        let metadata = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(metadata?.fileSize ?? 0)" as NSString
        if let image = thumbnailCache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnailCache.setObject(thumbnail, forKey: key, cost: image.width * image.height * 4)
        return thumbnail
    }
    private let url: URL?
    private let name: String
    private let dark: Bool
    private let width: CGFloat
    private let preview: NSImage?
    private let icon: NSImage?

    init(url: URL?, name: String, isImage: Bool, width: CGFloat, dark: Bool) {
        self.url = url; self.name = name; self.width = max(160, min(width, 620)); self.dark = dark
        preview = isImage ? url.flatMap { Self.thumbnail(for: $0) } : nil
        icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        super.init(textCell: name)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize {
        guard let preview else { return NSSize(width: min(width, 440), height: 66) }
        let scale = min(width / max(1, preview.size.width), 340 / max(1, preview.size.height), 1)
        return NSSize(width: max(80, preview.size.width * scale), height: max(56, preview.size.height * scale) + 8)
    }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let frame = cellFrame.insetBy(dx: 1, dy: 4)
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        if let preview {
            path.addClip()
            preview.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        (dark ? NSColor(markdownHex: 0x2C2E30) : NSColor(markdownHex: 0xF5F5F5)).setFill(); path.fill()
        (dark ? NSColor(markdownHex: 0x424548) : NSColor(markdownHex: 0xE4E4E4)).setStroke(); path.lineWidth = 1; path.stroke()
        icon?.draw(in: NSRect(x: frame.minX + 12, y: frame.minY + 12, width: 32, height: 32), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let color = dark ? NSColor(markdownHex: 0xDFE0E0) : NSColor(markdownHex: 0x444444)
        (name as NSString).draw(in: NSRect(x: frame.minX + 56, y: frame.minY + 10, width: frame.width - 68, height: 20),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
        let detail: String
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let type = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            detail = type + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " · Click to preview"
        } else { detail = "Attachment unavailable" }
        (detail as NSString).draw(in: NSRect(x: frame.minX + 56, y: frame.minY + 31, width: frame.width - 68, height: 17),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}

private final class MarkdownTextView: NSTextView {
    var onFormat: ((String) -> Void)?
    var onAttachmentClick: ((Int) -> Bool)?
    var onReturn: (() -> Bool)?
    var onCopy: (() -> String?)?
    var onPasteFiles: (([URL]) -> Bool)?
    var onPasteImage: ((Data) -> Bool)?
    var onCompositionStart: (() -> Void)?
    var onCompositionEnd: (() -> Void)?
    var isHandlingMarkedText = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onCompositionStart?()
        isHandlingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isHandlingMarkedText = false
    }

    override func unmarkText() { super.unmarkText(); onCompositionEnd?() }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let finishing = hasMarkedText()
        if finishing { isHandlingMarkedText = true }
        super.insertText(insertString, replacementRange: replacementRange)
        if finishing { isHandlingMarkedText = false; onCompositionEnd?() }
    }

    override func insertNewline(_ sender: Any?) {
        if onReturn?() == true { return }
        super.insertNewline(sender)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let value = onCopy?() else { return false }
        return pasteboard.setString(value, forType: .string)
    }

    override func copy(_ sender: Any?) {
        guard let value = onCopy?() else { super.copy(sender); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if importPasteboard(NSPasteboard.general) { return }
        if let string = NSPasteboard.general.string(forType: .string) {
            insertText(string, replacementRange: selectedRange())
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable, let string = NSPasteboard.general.string(forType: .string) else { return }
        insertText(string, replacementRange: selectedRange())
    }

    private func importPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Consume a file paste even if import fails: never insert raw file:// links.
            _ = onPasteFiles?(urls); return true
        }
        if let data = pasteboard.data(forType: .png) { _ = onPasteImage?(data); return true }
        if let data = pasteboard.data(forType: .tiff), let representation = NSBitmapImageRep(data: data),
           let png = representation.representation(using: .png, properties: [:]) {
            _ = onPasteImage?(png); return true
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        if importPasteboard(sender.draggingPasteboard) { return true }
        if let value = sender.draggingPasteboard.string(forType: .string) {
            insertText(value, replacementRange: selectedRange()); return true
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let manager = layoutManager, let container = textContainer {
            manager.ensureLayout(for: container)
            let location = convert(event.locationInWindow, from: nil)
            let point = NSPoint(x: location.x - textContainerOrigin.x, y: location.y - textContainerOrigin.y)
            let glyph = manager.glyphIndex(for: point, in: container)
            if glyph < manager.numberOfGlyphs {
                let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                if bounds.contains(point), onAttachmentClick?(manager.characterIndexForGlyph(at: glyph)) == true {
                    window?.makeFirstResponder(self)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, isEditable,
              modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if let format = ["b": "bold", "i": "italic", "k": "link"][key] {
            onFormat?(format); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSColor {
    convenience init(markdownHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
