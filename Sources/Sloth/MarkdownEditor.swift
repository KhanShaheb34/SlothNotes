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
    private var presentation = MarkdownPresentation.parse("")
    private var codeHighlights: [Int: (source: String, language: String?, tokens: [MarkdownSyntaxHighlighter.Token])] = [:]
    private var attachmentPreview: AttachmentPreviewWindowController?
    private var tableEditor: MarkdownTableCellEditor?
    private var tableEditingSourceIndex: Int?
    private var readOnlyFoldOverrides: [Int: Bool] = [:]
    private var composingSelection: NSRange?
    private var disabledCompositionUndo = false
    private var lastContentWidth: CGFloat = 0
    private var stylingSourceSelection: NSRange?
    private var lastStyledSelection = NSRange(location: 0, length: 0)

    var text: String { markdown }
    var hasPendingInput: Bool { tableEditor != nil || composingSelection != nil || textView.hasMarkedText() }
    var selectedSourceRange: NSRange { sourceRange(for: textView.selectedRange()) }
    var renderedAttachmentCount: Int { tokens.filter { $0.kind == .checkbox || $0.kind == .image || $0.kind == .file }.count }
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
    private var availableTextWidth: CGFloat {
        max(160, textView.bounds.width - textView.textContainerInset.width * 2)
    }
    private var contentWidth: CGFloat { min(620, availableTextWidth) }

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
        if let container = textView.textContainer {
            container.replaceLayoutManager(MarkdownLayoutManager())
        }
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
        textView.setAccessibilityHelp("Edit this note. Click heading arrows to fold sections. Click table cells to edit; Tab moves between cells. Command-click table links to open them. Checkboxes are clickable. Attachments open in Quick Look. Changes save automatically.")
        scrollView.documentView = textView
        if let editor = textView as? MarkdownTextView {
            editor.onFormat = { [weak self] in self?.applyFormat($0) }
            editor.onAttachmentClick = { [weak self] index, point, modifiers in self?.activateAttachment(atDisplayIndex: index, point: point, modifiers: modifiers) ?? false }
            editor.onToggleFold = { [weak self] in self?.toggleHeadingFold(atUTF16Index: $0) ?? false }
            editor.onToggleCurrentFold = { [weak self] in self?.toggleCurrentHeadingFold() }
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
        if abs(availableTextWidth - lastContentWidth) > 1 {
            lastContentWidth = availableTextWidth
            if tokens.contains(where: { $0.kind != .checkbox }) { rebuildProjection() }
        }
    }

    /// A selected note starts a fresh undo history, even if its text is unchanged.
    func setText(_ text: String) {
        finishPendingComposition()
        isUpdating = true
        markdown = text
        codeHighlights.removeAll()
        readOnlyFoldOverrides.removeAll()
        let initial = Self.expression("^ {0,3}#{1,6}[ \t]+").firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range.length ?? 0
        rebuildProjection(sourceSelection: NSRange(location: initial, length: 0))
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
        isUpdating = false
    }

    /// Commit the visible input-method text to the outgoing Markdown document
    /// before a note switch, shutdown flush, or formatting operation. Clearing
    /// undo while composition has disabled registration corrupts NSUndoManager.
    func finishPendingComposition() {
        finishTableEditing()
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
    func setEditable(_ editable: Bool) {
        if !editable && textView.isEditable { finishPendingComposition() }
        textView.isEditable = editable
        if editable && !readOnlyFoldOverrides.isEmpty {
            readOnlyFoldOverrides.removeAll()
            rebuildProjection()
        }
    }

    func selectSourceRange(_ range: NSRange, scroll: Bool = true) {
        var target = clamped(range, length: (markdown as NSString).length)
        // Search/outline navigation must reveal a hidden destination. Plain
        // selection restoration and copying an entire note keep folds intact.
        if scroll {
            while let heading = presentation.headings.first(where: {
                isHeadingFolded($0) && NSLocationInRange(target.location, $0.bodyRange) && NSMaxRange(target) <= NSMaxRange($0.bodyRange)
            }) {
                let previousLength = (markdown as NSString).length
                guard toggleHeadingFold(atUTF16Index: heading.range.location) else { break }
                target.location = max(0, target.location + (markdown as NSString).length - previousLength)
            }
        }
        let selected = displayRange(for: target)
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
        if editFoldBoundary(in: affectedCharRange, replacement: replacementString) { return false }
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
        if !textView.hasMarkedText(), composingSelection == nil {
            // Visibility is presentation only: retain source, selection, scroll and undo.
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let old = source.lineRange(for: clamped(lastStyledSelection, length: source.length))
            let new = source.lineRange(for: clamped(selection, length: source.length))
            restyle(in: NSUnionRange(old, new))
            textView.typingAttributes = defaultAttributes()
        }
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
        finishTableEditing()
        guard composingSelection == nil, !textView.hasMarkedText() else { return }
        let selection = sourceSelection ?? selectedSourceRange
        let visibleOrigin = scrollView.contentView.bounds.origin
        let previousUpdating = isUpdating
        isUpdating = true
        presentation = MarkdownPresentation.parse(markdown)
        fencedCodeRanges = presentation.codeBlocks.map(\.range)
        let projected = projection(for: markdown, sourceOffset: 0, displayOffset: 0)
        tokens = projected.tokens
        textView.textStorage?.setAttributedString(projected.text)
        stylingSourceSelection = selection
        restyle()
        stylingSourceSelection = nil
        textView.setSelectedRange(displayRange(for: clamped(selection, length: (markdown as NSString).length)))
        textView.typingAttributes = defaultAttributes()
        // TextKit lays out visible paragraphs on demand. Forcing ensureLayout on
        // the entire container makes a single key in a long note block the UI.
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateHeadingControls()
        isUpdating = previousUpdating
    }

    private func updateHeadingControls() {
        guard let view = textView as? MarkdownTextView else { return }
        view.headingControls = presentation.headings.filter { heading in
            heading.bodyRange.length > 0 && !tokens.contains { $0.kind == .fold && NSLocationInRange(heading.range.location, $0.sourceRange) }
        }.map { (displayRange(for: $0.contentRange), $0.range.location, isHeadingFolded($0), NSMaxRange(displayRange(for: $0.bodyRange))) }
        view.foldControlColor = isDark ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.42, alpha: 1)
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }

    func toggleCurrentHeadingFold() {
        finishPendingComposition()
        let index = selectedSourceRange.location
        if let heading = presentation.headings.last(where: { $0.range.location <= index }) {
            _ = toggleHeadingFold(atUTF16Index: heading.range.location)
        }
    }

    /// A bulk fold is one undoable source change; read-only notes use temporary presentation state.
    func setAllHeadingsFolded(_ folded: Bool) {
        finishPendingComposition()
        guard !textView.hasMarkedText() else { return }
        if !textView.isEditable {
            readOnlyFoldOverrides = Dictionary(uniqueKeysWithValues: presentation.headings.filter { $0.bodyRange.length > 0 }.map { ($0.range.location, folded) })
            rebuildProjection()
            return
        }
        var next = markdown as NSString
        var selection = selectedSourceRange
        for heading in presentation.headings.reversed() where heading.bodyRange.length > 0 && heading.isFolded != folded {
            let edit = foldEdit(for: heading, folded: folded)
            let delta = (edit.replacement as NSString).length - edit.range.length
            if NSMaxRange(edit.range) <= selection.location { selection.location += delta }
            else if edit.range.location < NSMaxRange(selection) { selection.length = 0; selection.location = edit.range.location }
            next = next.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        }
        guard next as String != markdown else { return }
        commit(next as String, selection: clamped(selection, length: next.length), actionName: folded ? "Fold All Headings" : "Unfold All Headings")
    }

    private func foldEdit(for heading: MarkdownPresentation.Heading, folded: Bool) -> SourceEdit {
        if let marker = heading.foldMarkerRange {
            var removal = marker
            if !folded, heading.isFolded, removal.location > 0, (markdown as NSString).character(at: removal.location - 1) == 32 {
                removal.location -= 1; removal.length += 1
            }
            return SourceEdit(range: removal, replacement: folded ? "<!-- {\"fold\":true} -->" : "")
        }
        let source = markdown as NSString
        var end = NSMaxRange(heading.range)
        while end > heading.range.location && [10, 13].contains(Int(source.character(at: end - 1))) { end -= 1 }
        return SourceEdit(range: NSRange(location: end, length: 0), replacement: " <!-- {\"fold\":true} -->")
    }

    /// Fold state travels with Markdown, so reopening or syncing a note keeps it.
    @discardableResult
    func toggleHeadingFold(atUTF16Index index: Int) -> Bool {
        var target = index
        if let editingIndex = tableEditingSourceIndex {
            let previousLength = (markdown as NSString).length
            finishTableEditing()
            if editingIndex < target { target += (markdown as NSString).length - previousLength }
        }
        guard !textView.hasMarkedText(),
              let heading = presentation.headings.first(where: { NSLocationInRange(target, $0.range) }),
              heading.bodyRange.length > 0 else { return false }
        if !textView.isEditable {
            readOnlyFoldOverrides[heading.range.location] = !isHeadingFolded(heading)
            rebuildProjection()
            return true
        }
        let edit = foldEdit(for: heading, folded: !heading.isFolded)
        return replace(edit.range, with: edit.replacement, selection: NSRange(location: heading.contentRange.location, length: 0),
                       actionName: heading.isFolded ? "Unfold Section" : "Fold Section", scrollToSelection: false)
    }

    private func isHeadingFolded(_ heading: MarkdownPresentation.Heading) -> Bool {
        readOnlyFoldOverrides[heading.range.location] ?? heading.isFolded
    }

    /// A temporary read-only fold starts at the heading's paragraph break when
    /// there is no saved marker. The attachment still retains the exact source.
    private func foldedSourceRange(for heading: MarkdownPresentation.Heading) -> NSRange {
        let source = markdown as NSString
        var start = heading.foldMarkerRange?.location ?? NSMaxRange(heading.range)
        if heading.foldMarkerRange == nil {
            while start > heading.range.location && [10, 13].contains(Int(source.character(at: start - 1))) { start -= 1 }
        }
        var end = NSMaxRange(heading.bodyRange)
        // Keep one paragraph break after the inline disclosure attachment.
        if end > start && source.character(at: end - 1) == 10 { end -= 1 }
        if end > start && source.character(at: end - 1) == 13 { end -= 1 }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A collapsed disclosure represents text the user cannot see. A blind
    /// Delete/Backspace reveals it first; Return expands and rebases its caret
    /// before inserting, preventing fold metadata from becoming visible text.
    private func editFoldBoundary(in affectedRange: NSRange, replacement: String) -> Bool {
        let insertingLineBreak = replacement.rangeOfCharacter(from: .newlines) != nil
        guard textView.selectedRange().length == 0, replacement.isEmpty || insertingLineBreak else { return false }
        let originalCaret = sourceOffset(forDisplayOffset: textView.selectedRange().location)
        guard let token = tokens.first(where: { token in
                  guard token.kind == .fold else { return false }
                  if replacement.isEmpty { return NSIntersectionRange(affectedRange, token.displayRange).length > 0 }
                  let headingStart = (markdown as NSString).lineRange(for: NSRange(location: token.sourceRange.location, length: 0)).location
                  return affectedRange.length == 0 && insertingLineBreak &&
                      originalCaret >= headingStart && affectedRange.location <= NSMaxRange(token.displayRange)
              }),
              let heading = presentation.headings.first(where: {
                  isHeadingFolded($0) && foldedSourceRange(for: $0).location == token.sourceRange.location
              }) else { return false }
        let edit = foldEdit(for: heading, folded: false)
        let delta = (edit.replacement as NSString).length - edit.range.length
        func rebased(_ offset: Int) -> Int {
            if offset <= edit.range.location { return offset }
            if offset < NSMaxRange(edit.range) { return edit.range.location }
            return offset + delta
        }
        let caret = rebased(originalCaret)
        var next = (markdown as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        if !replacement.isEmpty {
            next = (next as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: replacement)
        }
        commit(next, selection: NSRange(location: caret + (replacement as NSString).length, length: 0),
               actionName: replacement.isEmpty ? "Unfold Section" : "Edit Note")
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
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
        let horizontalRule = Self.expression(#"^ {0,3}(?:-[ \t]*){3,}$|^ {0,3}(?:\*[ \t]*){3,}$|^ {0,3}(?:_[ \t]*){3,}$"#, options: [.anchorsMatchLines])
        for match in horizontalRule.matches(in: value, range: all) where !ignored.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            candidates.append((match.range, .rule, false, nil, nil))
        }
        for reference in AttachmentStore.references(in: value, ignoring: ignored) where reference.path.hasPrefix("attachments/") {
            candidates.append((reference.range, reference.isImage ? .image : .file, false, reference.path, reference.label))
        }
        for heading in presentation.headings where isHeadingFolded(heading) && heading.bodyRange.length > 0 {
            let hidden = foldedSourceRange(for: heading)
            let range = NSRange(location: hidden.location - sourceOffset, length: hidden.length)
            guard range.location >= 0, NSMaxRange(range) <= source.length else { continue }
            candidates.append((range, .fold, false, nil, nil))
        }
        for table in presentation.tables {
            var range = NSRange(location: table.range.location - sourceOffset, length: table.range.length)
            guard range.location >= 0, NSMaxRange(range) <= source.length else { continue }
            while range.length > 0 && [10, 13].contains(Int(source.character(at: NSMaxRange(range) - 1))) { range.length -= 1 }
            candidates.append((range, .table, false, nil, nil))
        }
        candidates.sort { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }
        let result = NSMutableAttributedString()
        var resultTokens: [ProjectionToken] = []
        var cursor = 0
        for (range, kind, checked, path, name) in candidates {
            guard range.location >= cursor else { continue }
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            let attachment = MarkdownAttachment(markdown: source.substring(with: range))
            let url = path.flatMap { attachmentResolver?($0) }
            if kind == .table, let table = presentation.tables.first(where: { $0.range.location == sourceOffset + range.location }) {
                attachment.attachmentCell = MarkdownTableAttachmentCell(table: table, source: markdown, width: availableTextWidth, fontSize: fontSize, dark: isDark)
            } else if kind == .rule {
                attachment.attachmentCell = RuleAttachmentCell(width: availableTextWidth, size: fontSize, dark: isDark)
            } else if kind == .fold {
                attachment.attachmentCell = FoldAttachmentCell(size: fontSize, dark: isDark)
            } else if kind == .checkbox {
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
        // A collapsed section spans paragraphs; never splice a fragment into it.
        guard !tokens.contains(where: { $0.kind == .table }) else { return false }
        let hadFolds = tokens.contains(where: { $0.kind == .fold })
        let incremental = presentation.updating(previous: previous, range: edit.range, replacement: edit.replacement)
        guard !hadFolds || incremental != nil else { return false }
        let nextPresentation = incremental ?? MarkdownPresentation.parse(markdown)
        guard (hadFolds || nextPresentation.foldedBodyRanges.isEmpty), nextPresentation.tables.isEmpty else { return false }
        presentation = nextPresentation
        let old = previous as NSString
        let first = old.lineRange(for: NSRange(location: edit.range.location, length: 0))
        let last = old.lineRange(for: NSRange(location: NSMaxRange(edit.range), length: 0))
        let oldRegion = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard !tokens.contains(where: { $0.kind == .fold && NSIntersectionRange($0.sourceRange, oldRegion).length > 0 }) else { return false }
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
        // An unfinished fence grows when typing exactly at its old EOF. Reuse
        // the updated parser ranges so that new lines remain literal code.
        fencedCodeRanges = nextPresentation.codeBlocks.map(\.range)
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
        stylingSourceSelection = selection
        restyle(in: NSRange(location: oldDisplay.location, length: projected.text.length))
        stylingSourceSelection = nil
        storage.endEditing()
        (textView.layoutManager as? MarkdownLayoutManager)?.invalidatePresentation(in: NSRange(location: oldDisplay.location, length: projected.text.length))
        textView.setSelectedRange(displayRange(for: clamped(selection, length: new.length)))
        textView.typingAttributes = defaultAttributes()
        updateHeadingControls()
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
        if scheme == "mailto" {
            // Older NSURL-backed Foundation treats mailto as opaque, so URL.path
            // can be empty even with a recipient. Components uses RFC 3986 parsing.
            return URLComponents(string: destination)?.path.isEmpty == false ? url : nil
        }
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
        var full = requestedRange ?? NSRange(location: 0, length: content.length)
        // Multiline strings/comments change the lexical state of following lines.
        // Repaint the affected block on source edits; caret-only refreshes stay local.
        if requestedRange != nil {
            let source = markdown as NSString
            for (index, block) in presentation.codeBlocks.enumerated() {
                if tokens.contains(where: { $0.kind == .fold && NSLocationInRange(block.range.location, $0.sourceRange) }) { continue }
                let displayed = displayRange(for: block.range)
                guard NSIntersectionRange(displayed, full).length > 0 else { continue }
                let language = block.languageRange.map { source.substring(with: $0) }
                if codeHighlights[index]?.source != source.substring(with: block.contentRange) || codeHighlights[index]?.language != language {
                    full = NSUnionRange(full, displayed)
                }
            }
        }
        let selection = stylingSourceSelection.map { displayRange(for: $0) } ?? textView.selectedRange()
        lastStyledSelection = selection
        let localText = content.substring(with: full)
        let localFences = fencedCodeRanges.compactMap { range -> NSRange? in
            let overlap = NSIntersectionRange(displayRange(for: range), full)
            return overlap.length > 0 ? NSRange(location: overlap.location - full.location, length: overlap.length) : nil
        }
        let localLiteralRanges = AttachmentStore.codeRanges(in: localText, fences: localFences)
        let literalRanges = localLiteralRanges.map {
            NSRange(location: full.location + $0.location, length: $0.length)
        }
        func literal(_ range: NSRange) -> Bool {
            literalRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        storage.beginEditing()
        storage.setAttributes(defaultAttributes(), range: full)

        func matches(_ pattern: String, options: NSRegularExpression.Options = [.anchorsMatchLines], _ body: (NSTextCheckingResult) -> Void) {
            let regex = Self.expression(pattern, options: options)
            regex.enumerateMatches(in: content as String, range: full) { result, _, _ in
                if let result = result {
                    var before = result.range.location
                    while before > 0 && content.character(at: before - 1) == 92 { before -= 1 }
                    if (result.range.location - before) % 2 == 0 { body(result) }
                }
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
        func conceal(_ ranges: [NSRange], within span: NSRange, always: Bool = false) {
            let editing = selection.length == 0
                ? selection.location > span.location && selection.location < NSMaxRange(span)
                : NSIntersectionRange(selection, span).length > 0
            for range in ranges {
                style([.foregroundColor: marker], range)
                if always || !editing { style([.markdownHiddenSyntax: true], range) }
            }
        }
        func dim(_ match: NSTextCheckingResult, _ groups: [Int]) {
            guard !groups.contains(where: { literal(match.range(at: $0)) }) else { return }
            conceal(groups.map { match.range(at: $0) }, within: match.range)
        }

        // The first line is a note title even when it has no explicit Markdown heading.
        if content.length > 0, !tokens.contains(where: { content.lineRange(for: $0.displayRange).location == 0 }) {
            let first = content.lineRange(for: NSRange(location: 0, length: 0))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 16
            style([.font: NSFont.systemFont(ofSize: fontSize * 1.75, weight: .semibold), .paragraphStyle: paragraph], first)
        }
        matches("^ {0,3}(#{1,6})([ \\t]+)(.+)$") { match in
            let level = match.range(at: 1).length
            let scale: CGFloat = level == 1 ? 1.75 : level == 2 ? 1.375 : level == 3 ? 1.2 : 1.06
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacingBefore = level == 1 ? 0 : 14
            paragraph.paragraphSpacing = 10
            style([.font: NSFont.systemFont(ofSize: fontSize * scale, weight: .semibold), .paragraphStyle: paragraph], match.range)
            let prefix = NSRange(location: match.range.location, length: NSMaxRange(match.range(at: 2)) - match.range.location)
            if !literal(prefix) {
                conceal([prefix], within: prefix)
            }
        }
        matches("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)(\\1)", options: []) { match in
            fontTrait(.boldFontMask, match.range(at: 2))
            dim(match, [1, 3])
        }
        matches("(?<!\\*)(\\*)(?!\\*|\\s)(.+?)(?<!\\s)(\\*)(?!\\*)", options: []) { match in
            fontTrait(.italicFontMask, match.range(at: 2))
            dim(match, [1, 3])
        }
        matches(#"(?<![\p{L}\p{N}_])(_)(?!_|\s)(.+?)(?<!\s)(_)(?![\p{L}\p{N}_])"#, options: []) { match in
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
        for tag in MarkdownTagSyntax.matches(in: localText) {
            let range = NSRange(location: full.location + tag.range.location, length: tag.range.length)
            guard !literal(range) else { continue }
            style([.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.08)], range)
        }
        matches("(\\[\\[)([^\\]\\n]+)(\\]\\])", options: []) { match in
            let target = content.substring(with: match.range(at: 2)).components(separatedBy: "|").first ?? ""
            if let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "sloth://note/" + encoded) {
                style([.foregroundColor: accent, .link: url], match.range(at: 2))
            }
            if !literal(match.range) {
                let inner = content.substring(with: match.range(at: 2)) as NSString
                let separator = inner.range(of: "|")
                var markers = [match.range(at: 1), match.range(at: 3)]
                if separator.location != NSNotFound {
                    markers.append(NSRange(location: match.range(at: 2).location, length: separator.location + 1))
                }
                conceal(markers, within: match.range)
            }
        }
        matches("(\\[)([^\\]\\n]+)(\\]\\()([^\\s)]+)(\\))", options: []) { match in
            style([.foregroundColor: accent], match.range(at: 2))
            style([.foregroundColor: secondary], match.range(at: 4)); dim(match, [1, 3, 5])
        }
        let scopedText = content.substring(with: full)
        // A partial redraw may begin inside a fence. Preserve the document's
        // code context instead of treating its closing fence as a new opener.
        for reference in AttachmentStore.references(in: scopedText, ignoring: localLiteralRanges) {
            let outer = NSRange(location: full.location + reference.range.location, length: reference.range.length)
            let label = NSRange(location: full.location + reference.labelRange.location, length: reference.labelRange.length)
            conceal([NSRange(location: outer.location, length: label.location - outer.location),
                     NSRange(location: NSMaxRange(label), length: NSMaxRange(outer) - NSMaxRange(label))], within: outer)
            let literal = (scopedText as NSString).substring(with: reference.destinationRange)
            let destination = literal.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!<> -])"#, with: "$1", options: .regularExpression)
            if let url = webLink(destination) {
                let range = NSRange(location: full.location + reference.labelRange.location, length: reference.labelRange.length)
                style([.foregroundColor: accent, .link: url], range)
            }
        }
        matches("(?:https?://|mailto:)[^\\s<>\\]]+", options: []) { match in
            var destination = ""
            var parentheses = 0
            for character in content.substring(with: match.range) {
                if character == "(" { parentheses += 1 }
                if character == ")" {
                    // Keep balanced URL parentheses, but stop before enclosing
                    // prose or the closing delimiter of a Markdown link.
                    guard parentheses > 0 else { break }
                    parentheses -= 1
                }
                destination.append(character)
            }
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
        matches("^(>[ \t]?)(.*)$") { match in
            guard !literal(match.range(at: 1)) else { return }
            let line = content.lineRange(for: match.range)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.42
            paragraph.paragraphSpacing = fontSize * 0.28
            paragraph.firstLineHeadIndent = 16
            paragraph.headIndent = 16
            style([.paragraphStyle: paragraph, .markdownQuoteBlockID: "quote"], line)
            conceal([match.range(at: 1)], within: match.range(at: 1))
        }
        matches("^([ \\t]*)(-{3,}|\\*{3,}|_{3,})[ \\t]*$") { match in
            style([.foregroundColor: marker], match.range)
        }
        let codeBackground = isDark ? NSColor(markdownHex: 0x2E2F30) : NSColor(markdownHex: 0xF3F5F7)
        let codeFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.88, weight: .regular)
        for range in literalRanges {
            guard range.length > 1, !localFences.contains(where: { NSIntersectionRange(NSRange(location: full.location + $0.location, length: $0.length), range).length > 0 }) else { continue }
            let literalText = content.substring(with: range)
            let count = literalText.prefix(while: { $0 == "`" }).count
            guard count > 0, range.length >= count * 2 else { continue }
            style([.font: codeFont, .foregroundColor: foreground, .backgroundColor: codeBackground, .strikethroughStyle: 0], range)
            storage.removeAttribute(.link, range: range)
            storage.removeAttribute(.markdownHiddenSyntax, range: range)
            conceal([NSRange(location: range.location, length: count), NSRange(location: NSMaxRange(range) - count, length: count)], within: range)
        }
        // Cached source fence ranges remain valid across ordinary paragraph edits.
        for (blockIndex, sourceRange) in fencedCodeRanges.enumerated() {
            if tokens.contains(where: { $0.kind == .fold && NSLocationInRange(sourceRange.location, $0.sourceRange) }) { continue }
            let range = displayRange(for: sourceRange)
            guard NSIntersectionRange(range, full).length > 0 else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.25
            paragraph.paragraphSpacing = 0
            paragraph.headIndent = 12
            paragraph.firstLineHeadIndent = 12
            paragraph.tailIndent = -12
            style([.font: codeFont, .foregroundColor: foreground, .strikethroughStyle: 0,
                   .paragraphStyle: paragraph, .markdownCodeBlockID: "code-\(blockIndex)"], range)
            let affected = NSIntersectionRange(range, full)
            for attribute in [NSAttributedString.Key.link, .backgroundColor, .markdownHiddenSyntax] {
                storage.removeAttribute(attribute, range: affected)
            }
            style([.foregroundColor: marker], content.lineRange(for: NSRange(location: range.location, length: 0)))
        }
        for (blockIndex, block) in presentation.codeBlocks.enumerated() {
            if tokens.contains(where: { $0.kind == .fold && NSLocationInRange(block.range.location, $0.sourceRange) }) { continue }
            let body = displayRange(for: block.contentRange)
            if NSIntersectionRange(body, full).length > 0 {
                let source = markdown as NSString
                let code = source.substring(with: block.contentRange)
                let language = block.languageRange.map { source.substring(with: $0) }
                if codeHighlights[blockIndex]?.source != code || codeHighlights[blockIndex]?.language != language {
                    codeHighlights[blockIndex] = (code, language, MarkdownSyntaxHighlighter.tokens(in: code, language: language))
                }
                for token in codeHighlights[blockIndex]?.tokens ?? [] {
                    let mapped = displayRange(for: NSRange(location: block.contentRange.location + token.range.location, length: token.range.length))
                    style(MarkdownSyntaxHighlighter.attributes(for: token.kind, dark: isDark), mapped)
                }
            }
            let opening = displayRange(for: block.openingFenceRange)
            if NSIntersectionRange(opening, full).length > 0 {
                var syntax = opening
                while syntax.length > 0 && [10, 13].contains(Int(content.character(at: NSMaxRange(syntax) - 1))) { syntax.length -= 1 }
                if let language = block.languageRange {
                    let label = displayRange(for: language)
                    conceal([NSRange(location: syntax.location, length: max(0, label.location - syntax.location))], within: syntax)
                    style([.font: NSFont.systemFont(ofSize: fontSize * 0.72, weight: .medium), .foregroundColor: secondary], label)
                } else { conceal([syntax], within: syntax) }
            }
            if let closing = block.closingFenceRange {
                var syntax = displayRange(for: closing)
                while syntax.length > 0 && [10, 13].contains(Int(content.character(at: NSMaxRange(syntax) - 1))) { syntax.length -= 1 }
                conceal([syntax], within: syntax)
            }
        }
        for heading in presentation.headings {
            for markerRange in heading.markerRanges.dropFirst() {
                // Folded markers are represented by the disclosure attachment.
                if tokens.contains(where: { $0.kind == .fold && NSIntersectionRange($0.sourceRange, markerRange).length > 0 }) { continue }
                let range = displayRange(for: markerRange)
                conceal([range], within: range, always: true)
            }
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
        if let manager = textView.layoutManager as? MarkdownLayoutManager {
            manager.codeBlockBackgroundColor = codeBackground
            manager.quoteVerticalBarColor = accent
            if storage.editedMask.isEmpty { manager.invalidatePresentation(in: full) }
        }
        // Projection callers restore selection and typing attributes after their
        // outer storage edit finishes. Setting selection here can make Writing
        // Tools query stale layout while a character replacement is still pending.
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
        guard textView.isEditable else { return }
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

    private func finishTableEditing() {
        guard let field = tableEditor else { return }
        field.validateEditing()
        let callback = field.onCommit
        field.onCommit = nil
        callback?(field.stringValue, 0)
    }

    /// Update one source cell through the same undo/save path as ordinary typing.
    @discardableResult
    func editTableCell(atUTF16Index index: Int, row: Int, column: Int, value: String) -> Bool {
        guard textView.isEditable, let table = presentation.tables.first(where: { $0.range.location == index }),
              table.rows.indices.contains(row), table.rows[row].cells.indices.contains(column) else { return false }
        let source = markdown as NSString
        let rowValue = table.rows[row]
        let range = rowValue.cells[column].contentRange
        let original = source.substring(with: range)
        var replacement = value == MarkdownTableCellEditor.decodedCellText(original)
            ? original : MarkdownTableCellEditor.escapedCellText(value)
        var end = NSMaxRange(rowValue.range)
        while end > rowValue.range.location && [10, 13].contains(Int(source.character(at: end - 1))) { end -= 1 }
        if range.length == 0, range.location == end {
            // Short Markdown rows have implicit empty cells. Materialize the
            // needed separators when one of those cells is edited.
            let firstMissing = rowValue.cells.firstIndex { $0.range.length == 0 && $0.range.location == end } ?? column
            var last = end
            while last > rowValue.range.location && [32, 9].contains(Int(source.character(at: last - 1))) { last -= 1 }
            let trailingPipe = rowValue.markerRanges.contains { $0.location == last - 1 }
            replacement = (trailingPipe ? " " : " | ") + String(repeating: " | ", count: column - firstMissing) + replacement + (trailingPipe ? " |" : "")
        }
        return replace(range, with: replacement, selection: NSRange(location: index, length: 0), actionName: "Edit Table Cell", scrollToSelection: false)
    }

    private func beginTableEditing(atUTF16Index index: Int, row: Int, column: Int,
                                   draft: String? = nil, selection: NSRange? = nil) {
        guard textView.isEditable else { return }
        let previousEditingIndex = tableEditingSourceIndex
        let previousLength = (markdown as NSString).length
        finishTableEditing()
        // A clicked table was identified before committing the previous field.
        // Carry its source position through edits to an earlier table, including
        // Unicode text and cells that became shorter when committed.
        let target = index + ((previousEditingIndex.map { $0 < index } ?? false)
            ? (markdown as NSString).length - previousLength : 0)
        guard let token = tokens.first(where: { $0.kind == .table && $0.sourceRange.location == target }),
              let cell = token.attachment.attachmentCell as? MarkdownTableAttachmentCell,
              let manager = textView.layoutManager, let container = textView.textContainer,
              let value = cell.sourceText(row: row, column: column) else { return }
        let glyphs = manager.glyphRange(forCharacterRange: token.displayRange, actualCharacterRange: nil)
        manager.ensureLayout(forGlyphRange: glyphs)
        let frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
        guard let bounds = cell.cellFrame(row: row, column: column, in: frame) else { return }
        let field = MarkdownTableCellEditor(frame: bounds.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y).insetBy(dx: 2, dy: 2),
            text: value, fontSize: fontSize, dark: isDark, alignment: MarkdownTableAttachmentCell.textAlignment(cell.table.alignments[column]))
        if let draft { field.stringValue = draft }
        tableEditor = field
        tableEditingSourceIndex = target
        field.setAccessibilityLabel("Table row \(row + 1), column \(column + 1)")
        field.onCancel = { [weak self, weak field] in
            field?.onCommit = nil
            field?.removeFromSuperview()
            self?.tableEditor = nil
            self?.tableEditingSourceIndex = nil
            self?.focus()
        }
        field.onCommit = { [weak self, weak field] value, direction in
            guard let self, self.tableEditor === field else { return }
            let draftSelection = (field?.currentEditor() as? NSTextView)?.selectedRange()
            let requestedExit = field?.requestedExit == true
            field?.onCommit = nil
            self.tableEditor = nil
            self.tableEditingSourceIndex = nil
            if field?.currentEditor() === self.window?.firstResponder { self.focus() }
            field?.removeFromSuperview()
            _ = self.editTableCell(atUTF16Index: target, row: row, column: column, value: value)
            if direction != 0 {
                let next = row * cell.table.columnCount + column + direction
                if next >= 0 && next < cell.table.rows.count * cell.table.columnCount {
                    self.beginTableEditing(atUTF16Index: target, row: next / cell.table.columnCount, column: next % cell.table.columnCount)
                } else {
                    // At a boundary, retain the original draft and native caret
                    // after saving instead of moving into the table's Markdown.
                    self.beginTableEditing(atUTF16Index: target, row: row, column: column,
                                           draft: value, selection: draftSelection)
                }
            } else if requestedExit,
                      let table = self.presentation.tables.first(where: { $0.range.location == target }) {
                let source = self.markdown as NSString
                let end = NSMaxRange(table.range)
                let endsWithNewline = end > 0 && [10, 13].contains(Int(source.character(at: end - 1)))
                var separator = endsWithNewline ? "\n" : "\n\n"
                let caret = end + (separator as NSString).length
                if end < source.length && ![10, 13].contains(Int(source.character(at: end))) { separator += "\n" }
                _ = self.replace(NSRange(location: end, length: 0), with: separator,
                                 selection: NSRange(location: caret, length: 0), actionName: "Edit Table Cell")
                self.focus()
            } else if self.window?.firstResponder == nil { self.focus() }
        }
        textView.addSubview(field)
        textView.scrollToVisible(field.frame)
        window?.makeFirstResponder(field)
        if let selection, let native = field.currentEditor() as? NSTextView {
            native.setSelectedRange(clamped(selection, length: (native.string as NSString).length))
        }
        field.resizeToFitText()
        textView.scrollToVisible(field.frame)
    }

    private func activateAttachment(atDisplayIndex index: Int, point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let token = tokens.first(where: { $0.displayRange.location == index }) else { return false }
        if token.kind == .rule { return false }
        if token.kind == .table, let cell = token.attachment.attachmentCell as? MarkdownTableAttachmentCell,
           let manager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: token.displayRange, actualCharacterRange: nil)
            let frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
            if modifiers.contains(.command), let link = cell.link(at: point, in: frame) {
                NSWorkspace.shared.open(link)
            } else if let coordinate = cell.cellCoordinates(at: point, in: frame) {
                beginTableEditing(atUTF16Index: token.sourceRange.location, row: coordinate.row, column: coordinate.column)
            }
            return true
        }
        if token.kind == .fold {
            if let heading = presentation.headings.first(where: { isHeadingFolded($0) && foldedSourceRange(for: $0).location == token.sourceRange.location }) {
                return toggleHeadingFold(atUTF16Index: heading.range.location)
            }
            return true
        }
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
    enum Kind { case checkbox, image, file, fold, table, rule }
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

private final class RuleAttachmentCell: NSTextAttachmentCell {
    private let width: CGFloat
    private let size: CGFloat
    private let dark: Bool
    init(width: CGFloat, size: CGFloat, dark: Bool) {
        self.width = width; self.size = size; self.dark = dark
        super.init(textCell: "Horizontal rule")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: width, height: size) }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.15).setFill()
        NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: 1).fill()
    }
}

private final class FoldAttachmentCell: NSTextAttachmentCell {
    private let size: CGFloat
    private let dark: Bool
    init(size: CGFloat, dark: Bool) {
        self.size = size; self.dark = dark
        super.init(textCell: "Unfold section")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func cellSize() -> NSSize { NSSize(width: size * 1.9, height: size * 0.9) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -1) }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        (dark ? NSColor.lightGray : NSColor.gray).setFill()
        for index in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: frame.midX + CGFloat(index - 1) * 5 - 1.5, y: frame.midY - 1.5, width: 3, height: 3)).fill()
        }
    }
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
    var headingControls: [(range: NSRange, sourceIndex: Int, folded: Bool, bodyEnd: Int)] = []
    var foldControlColor = NSColor(white: 0.42, alpha: 1)
    var onToggleFold: ((Int) -> Bool)?
    var onToggleCurrentFold: (() -> Void)?

    private func headingControlFrames() -> [(NSRect, Int, Bool)] {
        guard let manager = layoutManager, let container = textContainer else { return [] }
        let viewport = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = manager.glyphRange(forBoundingRect: viewport, in: container)
        let visibleCharacters = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        return headingControls.compactMap { heading in
            guard NSLocationInRange(heading.range.location, visibleCharacters), heading.range.location < (string as NSString).length else { return nil }
            let glyph = manager.glyphIndexForCharacter(at: heading.range.location)
            guard glyph < manager.numberOfGlyphs else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let frame = NSRect(x: textContainerOrigin.x - 23, y: textContainerOrigin.y + line.minY + 4, width: 18, height: 18)
            guard visibleRect.intersects(frame) else { return nil }
            return (frame, heading.sourceIndex, heading.folded)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        foldControlColor.setFill()
        for (frame, _, folded) in headingControlFrames() where dirtyRect.intersects(frame) {
            let path = NSBezierPath()
            if folded {
                path.move(to: NSPoint(x: frame.midX - 2, y: frame.midY - 4))
                path.line(to: NSPoint(x: frame.midX + 3, y: frame.midY))
                path.line(to: NSPoint(x: frame.midX - 2, y: frame.midY + 4))
            } else {
                path.move(to: NSPoint(x: frame.midX - 4, y: frame.midY - 2))
                path.line(to: NSPoint(x: frame.midX + 4, y: frame.midY - 2))
                path.line(to: NSPoint(x: frame.midX, y: frame.midY + 3))
            }
            path.close(); path.fill()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        for (frame, _, _) in headingControlFrames() {
            addCursorRect(frame, cursor: .pointingHand)
            addToolTip(frame, owner: self, userData: nil)
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        let folded = headingControlFrames().first { $0.0.contains(point) }?.2 ?? false
        return folded ? "Unfold section (⌘')" : "Fold section (⌘')"
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndex = characterIndexForInsertion(at: point)
        guard let heading = headingControls.last(where: { $0.range.location <= clickedIndex && clickedIndex < $0.bodyEnd }) else { return menu }
        menu.addItem(.separator())
        let item = NSMenuItem(title: heading.folded ? "Unfold Section" : "Fold Section", action: #selector(toggleCurrentFold(_:)), keyEquivalent: "")
        item.representedObject = heading.sourceIndex
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc private func toggleCurrentFold(_ sender: NSMenuItem) {
        if let index = sender.representedObject as? Int { _ = onToggleFold?(index) }
        else { onToggleCurrentFold?() }
    }

    var onFormat: ((String) -> Void)?
    var onAttachmentClick: ((Int, NSPoint, NSEvent.ModifierFlags) -> Bool)?
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
        let click = convert(event.locationInWindow, from: nil)
        if let (_, index, _) = headingControlFrames().first(where: { $0.0.contains(click) }), onToggleFold?(index) == true { return }
        if event.clickCount == 1, let manager = layoutManager, let container = textContainer {
            let location = convert(event.locationInWindow, from: nil)
            let point = NSPoint(x: location.x - textContainerOrigin.x, y: location.y - textContainerOrigin.y)
            manager.ensureLayout(forBoundingRect: NSRect(origin: point, size: NSSize(width: 1, height: 1)), in: container)
            let glyph = manager.glyphIndex(for: point, in: container)
            if glyph < manager.numberOfGlyphs {
                let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                if bounds.contains(point), onAttachmentClick?(manager.characterIndexForGlyph(at: glyph), point, event.modifierFlags) == true {
                    if window?.firstResponder == nil { window?.makeFirstResponder(self) }
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
