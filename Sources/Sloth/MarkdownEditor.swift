import AppKit
import ImageIO
import Quartz

/// A Markdown-backed editor. The document remains portable Markdown while task markers
/// and local attachments are projected into native text attachments for editing.
final class MarkdownEditorView: NSView, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onOpenNoteLink: ((String) -> Bool)?
    var attachmentResolver: ((String) -> URL?)? { didSet { rebuildProjection() } }
    var onImportFiles: (([URL]) -> [String])?
    var onImportImage: ((Data) -> String?)?
    var isDark = false { didSet { if isDark != oldValue { rebuildProjection() } } }
    var fontSize: CGFloat = 16 { didSet { if fontSize != oldValue { rebuildProjection() } } }

    let textView: NSTextView
    private let scrollView = NSScrollView()
    private var markdown = ""
    private var isUpdating = false
    private var isStyling = false
    private var tokens: [ProjectionToken] = []
    private var fencedCodeRanges: [NSRange] = []
    private var attachmentPreview: AttachmentPreviewWindowController?
    private var composingSelection: NSRange?
    private var disabledCompositionUndo = false
    private var lastContentWidth: CGFloat = 0

    var text: String { markdown }
    var selectedSourceRange: NSRange { sourceRange(for: textView.selectedRange()) }
    var renderedAttachmentCount: Int { tokens.count }
    var scrollPosition: NSPoint { scrollView.contentView.bounds.origin }

    func restoreScrollPosition(_ position: NSPoint) {
        layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(forBoundingRect: NSRect(origin: position, size: clip.bounds.size), in: container)
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: position, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }


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
    private var accent: NSColor { isDark ? NSColor(markdownHex: 0xE36B64) : NSColor(markdownHex: 0xD65A52) }
    private var background: NSColor { isDark ? NSColor(markdownHex: 0x202122) : NSColor(markdownHex: 0xFFFEFC) }
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
        textView.layoutManager?.allowsNonContiguousLayout = true
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
        finishPendingComposition()
        isUpdating = true
        markdown = text
        rebuildProjection(sourceSelection: NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
        isUpdating = false
    }

    /// Commit the visible input-method text to the outgoing Markdown document
    /// before a note switch, shutdown flush, or formatting operation. Clearing
    /// undo while composition has disabled registration corrupts NSUndoManager.
    func finishPendingComposition() {
        guard composingSelection != nil || textView.hasMarkedText() else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        finishComposition()
    }

    /// Re-resolve downloaded or restored attachment files without resetting the caret or undo.
    func refreshAttachments() {
        guard tokens.contains(where: { token in
            guard let path = token.path else { return false }
            return attachmentIdentity(attachmentResolver?(path)) != token.identity
        }) else { return }
        rebuildProjection()
    }

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
        finishPendingComposition()
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

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "sloth", url.host == "note" else { return false }
        let target = String(url.path.dropFirst())
        if onOpenNoteLink?(target) != true { NSSound.beep() }
        return true
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
        fencedCodeRanges = AttachmentStore.fencedCodeRanges(in: markdown)
        let projected = projection(for: markdown, sourceOffset: 0, displayOffset: 0)
        tokens = projected.tokens
        textView.textStorage?.setAttributedString(projected.text)
        restyle()
        textView.setSelectedRange(displayRange(for: clamped(selection, length: (markdown as NSString).length)))
        textView.typingAttributes = defaultAttributes()
        // TextKit lays out visible paragraphs on demand. Forcing ensureLayout on
        // the entire container makes a single key in a long note block the UI.
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isUpdating = previousUpdating
    }

    private static var expressions: [String: NSRegularExpression] = [:]
    private static func expression(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        let key = "\(options.rawValue):\(pattern)"
        if let cached = expressions[key] { return cached }
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        expressions[key] = regex
        return regex
    }

    private func projection(for value: String, sourceOffset: Int, displayOffset: Int) -> (text: NSAttributedString, tokens: [ProjectionToken]) {
        let source = value as NSString
        let all = NSRange(location: 0, length: source.length)
        let localFences = fencedCodeRanges.compactMap { fence -> NSRange? in
            let intersection = NSIntersectionRange(fence, NSRange(location: sourceOffset, length: source.length))
            return intersection.length > 0 ? NSRange(location: intersection.location - sourceOffset, length: intersection.length) : nil
        }
        let ignored = AttachmentStore.codeRanges(in: value, fences: localFences)
        var candidates: [(NSRange, ProjectionToken.Kind, Bool, String?, String?)] = []
        let checklist = Self.expression("^([ \\t]*)([-+*][ \\t]+\\[[ xX]\\])([ \\t]*)(?=$|[^\\r\\n])", options: [.anchorsMatchLines])
        for match in checklist.matches(in: value, range: all) {
            let start = match.range(at: 2).location
            let range = NSRange(location: start, length: NSMaxRange(match.range) - start)
            let end = NSMaxRange(match.range(at: 2))
            let separator = end == source.length || [32, 9, 13, 10].contains(Int(source.character(at: end)))
            if separator && !ignored.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                candidates.append((range, .checkbox, source.substring(with: range).lowercased().contains("[x]"), nil, nil))
            }
        }
        for reference in AttachmentStore.references(in: value, ignoring: ignored) where reference.path.hasPrefix("attachments/") {
            candidates.append((reference.range, reference.isImage ? .image : .file, false, reference.path, reference.label))
        }
        candidates.sort { $0.0.location < $1.0.location }
        let result = NSMutableAttributedString()
        var resultTokens: [ProjectionToken] = []
        var cursor = 0
        for (range, kind, checked, path, name) in candidates {
            guard range.location >= cursor else { continue }
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            let attachment = MarkdownAttachment(markdown: source.substring(with: range))
            let url = path.flatMap { attachmentResolver?($0) }
            if kind == .checkbox {
                attachment.attachmentCell = CheckboxAttachmentCell(checked: checked, size: fontSize, dark: isDark, accent: accent)
            } else {
                let cell = FileAttachmentCell(url: url, name: name ?? "Attachment", isImage: kind == .image,
                                              width: contentWidth, dark: isDark)
                cell.onPreviewReady = { [weak self, weak attachment] in
                    guard let self, let attachment,
                          let token = self.tokens.first(where: { $0.attachment === attachment }) else { return }
                    self.textView.layoutManager?.invalidateDisplay(forCharacterRange: token.displayRange)
                    self.textView.needsDisplay = true
                }
                attachment.attachmentCell = cell
            }
            resultTokens.append(ProjectionToken(sourceRange: NSRange(location: sourceOffset + range.location, length: range.length),
                                                displayRange: NSRange(location: displayOffset + result.length, length: 1), kind: kind,
                                                path: path, url: url, name: name, identity: attachmentIdentity(url), attachment: attachment))
            result.append(NSAttributedString(attachment: attachment))
            cursor = NSMaxRange(range)
        }
        result.append(NSAttributedString(string: source.substring(from: cursor)))
        return (result, resultTokens)
    }

    private func attachmentIdentity(_ url: URL?) -> String? {
        guard let url else { return nil }
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? -1)"
    }

    /// Rebuild only touched paragraphs, preserving the layout, attachment cells,
    /// and attributes in the rest of a long note. Fence edits can affect all
    /// following paragraphs and deliberately use the full parser instead.
    private func updateProjection(previous: String, edit: SourceEdit, selection: NSRange) -> Bool {
        guard let storage = textView.textStorage, composingSelection == nil, !textView.hasMarkedText() else { return false }
        let old = previous as NSString
        let first = old.lineRange(for: NSRange(location: edit.range.location, length: 0))
        let last = old.lineRange(for: NSRange(location: NSMaxRange(edit.range), length: 0))
        let oldRegion = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let replacementLength = (edit.replacement as NSString).length
        let delta = replacementLength - edit.range.length
        let newRegion = NSRange(location: oldRegion.location, length: oldRegion.length + delta)
        let new = markdown as NSString
        guard newRegion.length >= 0, NSMaxRange(newRegion) <= new.length else { return false }
        let oldFragment = old.substring(with: oldRegion)
        let fragment = new.substring(with: newRegion)
        let fence = Self.expression("^[ \\t]*(`{3,}|~{3,})", options: [.anchorsMatchLines])
        if fence.firstMatch(in: oldFragment, range: NSRange(location: 0, length: (oldFragment as NSString).length)) != nil ||
            fence.firstMatch(in: fragment, range: NSRange(location: 0, length: (fragment as NSString).length)) != nil { return false }
        // Tokens still refer to the previous source here, so the old region can
        // be translated before offsets are adjusted for the edit.
        let oldDisplay = displayRange(for: oldRegion)
        fencedCodeRanges = fencedCodeRanges.map { range in
            if range.location >= NSMaxRange(edit.range) { return NSRange(location: range.location + delta, length: range.length) }
            if NSMaxRange(range) > edit.range.location { return NSRange(location: range.location, length: range.length + delta) }
            return range
        }
        let projected = projection(for: fragment, sourceOffset: newRegion.location, displayOffset: oldDisplay.location)
        let displayDelta = projected.text.length - oldDisplay.length
        var updated = tokens.filter { NSMaxRange($0.sourceRange) <= oldRegion.location }
        updated.append(contentsOf: projected.tokens)
        updated.append(contentsOf: tokens.filter { $0.sourceRange.location >= NSMaxRange(oldRegion) }.map { token in
            var moved = token
            moved.sourceRange.location += delta
            moved.displayRange.location += displayDelta
            return moved
        })
        tokens = updated
        storage.beginEditing()
        storage.replaceCharacters(in: oldDisplay, with: projected.text)
        restyle(in: NSRange(location: oldDisplay.location, length: projected.text.length))
        storage.endEditing()
        textView.setSelectedRange(displayRange(for: clamped(selection, length: new.length)))
        textView.typingAttributes = defaultAttributes()
        return true
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.42
        paragraph.paragraphSpacing = fontSize * 0.28
        return [.font: bodyFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    /// Only user-clicked web and email links are handed to the system. Imported
    /// file, app and custom-scheme URLs remain portable source text.
    private func webLink(_ destination: String) -> URL? {
        guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "mailto" { return url.path.isEmpty ? nil : url }
        return url.host?.isEmpty == false ? url : nil
    }

    private func restyle(in requestedRange: NSRange? = nil) {
        guard !isStyling else { return }
        textView.backgroundColor = background
        textView.insertionPointColor = accent
        textView.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: 0]
        textView.selectedTextAttributes = [.backgroundColor: isDark ? NSColor(markdownHex: 0x454D56) : NSColor(markdownHex: 0xD3E6FB)]
        scrollView.backgroundColor = background
        layer?.backgroundColor = background.cgColor
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        isStyling = true
        defer { isStyling = false }
        let content = textView.string as NSString
        let full = requestedRange ?? NSRange(location: 0, length: content.length)
        let selections = textView.selectedRanges
        storage.beginEditing()
        storage.setAttributes(defaultAttributes(), range: full)

        func matches(_ pattern: String, options: NSRegularExpression.Options = [.anchorsMatchLines], _ body: (NSTextCheckingResult) -> Void) {
            let regex = Self.expression(pattern, options: options)
            regex.enumerateMatches(in: content as String, range: full) { result, _, _ in
                if let result = result { body(result) }
            }
        }
        func style(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            guard range.location != NSNotFound, NSMaxRange(range) <= content.length else { return }
            let intersection = NSIntersectionRange(full, range)
            if intersection.length > 0 { storage.addAttributes(attributes, range: intersection) }
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
            let target = content.substring(with: match.range(at: 2)).components(separatedBy: "|").first ?? ""
            if let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "sloth://note/" + encoded) {
                style([.foregroundColor: accent, .link: url], match.range(at: 2))
            }
            dim(match, [1, 3])
        }
        matches("(\\[)([^\\]\\n]+)(\\]\\()([^\\s)]+)(\\))", options: []) { match in
            style([.foregroundColor: accent], match.range(at: 2))
            style([.foregroundColor: secondary], match.range(at: 4)); dim(match, [1, 3, 5])
        }
        let scopedText = content.substring(with: full)
        for reference in AttachmentStore.references(in: scopedText) {
            let literal = (scopedText as NSString).substring(with: reference.destinationRange)
            let destination = literal.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!<> -])"#, with: "$1", options: .regularExpression)
            if let url = webLink(destination) {
                let range = NSRange(location: full.location + reference.labelRange.location, length: reference.labelRange.length)
                style([.foregroundColor: accent, .link: url], range)
            }
        }
        matches("(?:https?://|mailto:)[^\\s<>\\])]+", options: []) { match in
            var destination = content.substring(with: match.range)
            while let last = destination.last, ".,;".contains(last) { destination.removeLast() }
            if let url = webLink(destination) {
                style([.foregroundColor: accent, .link: url], NSRange(location: match.range.location, length: (destination as NSString).length))
            }
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
            storage.removeAttribute(.link, range: match.range)
            dim(match, [1, 3])
        }
        // Cached source fence ranges remain valid across ordinary paragraph edits.
        for sourceRange in fencedCodeRanges {
            let range = displayRange(for: sourceRange)
            guard NSIntersectionRange(range, full).length > 0 else { continue }
            style([.font: codeFont, .foregroundColor: foreground, .backgroundColor: codeBackground, .strikethroughStyle: 0], range)
            storage.removeAttribute(.link, range: NSIntersectionRange(range, full))
            style([.foregroundColor: marker], content.lineRange(for: NSRange(location: range.location, length: 0)))
        }
        for token in tokens where NSIntersectionRange(content.lineRange(for: token.displayRange), full).length > 0 {
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
        fencedCodeRanges.contains { NSLocationInRange(lineStart, $0) }
    }

    /// Inserts or toggles Markdown around the current selection as one undoable edit.
    func applyFormat(_ format: String) {
        guard textView.isEditable else { return }
        finishPendingComposition()
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
        commit(next, selection: selection, actionName: actionName, edit: SourceEdit(range: range, replacement: replacement))
        if scrollToSelection { textView.scrollRangeToVisible(textView.selectedRange()) }
        return true
    }

    private func commit(_ value: String, selection: NSRange, actionName: String, previousSelection: NSRange? = nil, edit: SourceEdit? = nil) {
        guard value != markdown else { selectSourceRange(selection); return }
        let previousText = markdown
        let previousRange = previousSelection ?? selectedSourceRange
        let previousUpdating = isUpdating
        isUpdating = true
        markdown = value
        if let edit, updateProjection(previous: previousText, edit: edit, selection: selection) {
            // Paragraph-local projection kept unaffected TextKit layout intact.
        } else { rebuildProjection(sourceSelection: selection) }
        isUpdating = previousUpdating
        if let edit {
            let reverse = SourceEdit(range: NSRange(location: edit.range.location, length: (edit.replacement as NSString).length),
                                     replacement: (previousText as NSString).substring(with: edit.range))
            // Store only the changed text for ordinary edits. Capturing a full
            // note per keystroke made long editing sessions grow without bound.
            textView.undoManager?.registerUndo(withTarget: self) { target in
                target.replace(reverse.range, with: reverse.replacement, selection: previousRange,
                               actionName: actionName, scrollToSelection: false)
            }
        } else {
            textView.undoManager?.registerUndo(withTarget: self) { target in
                target.commit(previousText, selection: previousRange, actionName: actionName)
            }
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

private struct SourceEdit {
    let range: NSRange
    let replacement: String
}

private struct ProjectionToken {
    enum Kind { case checkbox, image, file }
    var sourceRange: NSRange
    var displayRange: NSRange
    let kind: Kind
    let path: String?
    let url: URL?
    let name: String?
    let identity: String?
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

    private static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Sloth attachment previews"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private static func thumbnail(for url: URL, key: NSString) -> NSImage? {
        if let image = thumbnailCache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnailCache.setObject(thumbnail, forKey: key, cost: image.width * image.height * 4)
        return thumbnail
    }
    private let name: String
    private let dark: Bool
    private let width: CGFloat
    private var preview: NSImage?
    private let imageSize: NSSize?
    private let icon: NSImage?
    private let detail: String
    var onPreviewReady: (() -> Void)?

    init(url: URL?, name: String, isImage: Bool, width: CGFloat, dark: Bool) {
        self.name = name; self.width = max(160, min(width, 620)); self.dark = dark
        let metadata = url.flatMap { try? URL(fileURLWithPath: $0.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) }
        let key = "\(url?.path ?? "missing")|\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(metadata?.fileSize ?? -1)" as NSString
        var dimensions: NSSize?
        if isImage, let url,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetType(source).map({ ($0 as String) != "com.adobe.pdf" }) == true,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pixelsWide = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           pixelsWide.doubleValue > 0, pixelsHigh.doubleValue > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            dimensions = orientation >= 5 ? NSSize(width: pixelsHigh.doubleValue, height: pixelsWide.doubleValue) :
                NSSize(width: pixelsWide.doubleValue, height: pixelsHigh.doubleValue)
        }
        imageSize = dimensions
        preview = dimensions == nil ? nil : Self.thumbnailCache.object(forKey: key)
        icon = dimensions == nil ? url.map { NSWorkspace.shared.icon(forFile: $0.path) } : nil
        if let url, let bytes = metadata?.fileSize {
            let type = url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased()
            detail = type + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " · Click to preview"
        } else { detail = "Attachment unavailable" }
        super.init(textCell: name)
        if dimensions != nil, preview == nil, let url {
            Self.thumbnailQueue.addOperation { [weak self] in
                guard self != nil, let thumbnail = Self.thumbnail(for: url, key: key) else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.preview = thumbnail
                    self?.onPreviewReady?()
                }
            }
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize {
        guard let size = imageSize else { return NSSize(width: min(width, 440), height: 66) }
        let scale = min(width / max(1, size.width), 340 / max(1, size.height), 1)
        return NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale) + 8)
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
        if imageSize != nil {
            let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: "Loading image preview")
            symbol?.draw(in: NSRect(x: frame.midX - 12, y: frame.midY - 12, width: 24, height: 24), from: .zero,
                         operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
            return
        }
        icon?.draw(in: NSRect(x: frame.minX + 12, y: frame.minY + 12, width: 32, height: 32), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let color = dark ? NSColor(markdownHex: 0xDFE0E0) : NSColor(markdownHex: 0x444444)
        (name as NSString).draw(in: NSRect(x: frame.minX + 56, y: frame.minY + 10, width: frame.width - 68, height: 20),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
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
        let wasHandling = isHandlingMarkedText
        isHandlingMarkedText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isHandlingMarkedText = wasHandling
    }

    override func unmarkText() {
        // AppKit may recursively remove/reinsert marked text while unmarking.
        // Preserve the outer transaction across every native input callback.
        let wasHandling = isHandlingMarkedText
        isHandlingMarkedText = true
        super.unmarkText()
        isHandlingMarkedText = wasHandling
        if !wasHandling { onCompositionEnd?() }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let finishing = hasMarkedText()
        let wasHandling = isHandlingMarkedText
        if finishing { isHandlingMarkedText = true }
        super.insertText(insertString, replacementRange: replacementRange)
        isHandlingMarkedText = wasHandling
        if finishing && !wasHandling { onCompositionEnd?() }
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
        if let data = pasteboard.data(forType: .tiff) {
            // The attachment importer decodes and normalizes image data on its
            // worker queue. Pasting a large TIFF must not decode on the UI thread.
            _ = onPasteImage?(data); return true
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
            let location = convert(event.locationInWindow, from: nil)
            let point = NSPoint(x: location.x - textContainerOrigin.x, y: location.y - textContainerOrigin.y)
            manager.ensureLayout(forBoundingRect: NSRect(origin: point, size: NSSize(width: 1, height: 1)), in: container)
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
