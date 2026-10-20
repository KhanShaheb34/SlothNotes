import AppKit
import UniformTypeIdentifiers

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
}

enum Palette {
    static var dark = false
    static var paper: NSColor { NSColor(hex: dark ? 0x202122 : 0xFFFEFC) }
    static var secondary: NSColor { NSColor(hex: dark ? 0x2B2C2E : 0xF4F2EF) }
    static var ink: NSColor { NSColor(hex: dark ? 0xE4E2DF : 0x3E4143) }
    static var muted: NSColor { NSColor(hex: dark ? 0xA7A5A2 : 0x7D8284) }
    static var line: NSColor { NSColor(hex: dark ? 0x38393A : 0xEAE7E2) }
    static var accent: NSColor { NSColor(hex: dark ? 0xE36B64 : 0xD65A52) }
    static var sidebar: NSColor { NSColor(hex: dark ? 0x26282A : 0x303438) }
}

class Surface: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    private var hover = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hover || isHighlighted) {
            (contentTintColor ?? Palette.muted).withAlphaComponent(isHighlighted ? 0.17 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; handler = action; target = self; self.action = #selector(run)
        isBordered = false; bezelStyle = .inline; font = .systemFont(ofSize: 13)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = .imageOnly }
        toolTip = title; setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler?() }
}

final class SidebarButton: NSButton {
    let label: String
    let symbol: String
    var count: Int { didSet { if count != oldValue { needsDisplay = true } } }
    var key = ""
    var active = false { didSet { needsDisplay = true } }
    var depth = 0
    var handler: (() -> Void)?
    init(_ label: String, symbol: String, count: Int, action: @escaping () -> Void) {
        self.label = label; self.symbol = symbol; self.count = count; handler = action
        super.init(frame: .zero); title = label; isBordered = false; target = self; self.action = #selector(run)
        setAccessibilityLabel(label); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler?() }
    override func draw(_ dirtyRect: NSRect) {
        if active { NSColor(hex: 0x474B4E).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill() }
        let foreground = NSColor(hex: active ? 0xFFFFFF : 0xD1D1D1)
        let iconX: CGFloat = 18 + CGFloat(min(depth, 5)) * 12
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect); (self.active ? Palette.accent : NSColor(hex: 0x9FA09F)).set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: iconX, y: (bounds.height - 17) / 2, width: 17, height: 17))
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(in: NSRect(x: iconX + 29, y: (bounds.height - 18) / 2, width: bounds.width - iconX - 62, height: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: active ? .medium : .regular), .foregroundColor: foreground, .paragraphStyle: style])
        if count > 0 {
            let text = "\(count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(hex: 0x929799)]
            let w = text.size(withAttributes: attrs).width
            text.draw(at: NSPoint(x: bounds.width - w - 17, y: (bounds.height - 13) / 2), withAttributes: attrs)
        }
    }
}

func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = Palette.ink
    field.lineBreakMode = .byTruncatingTail; return field
}

final class NoteRow: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override func drawBackground(in dirtyRect: NSRect) { Palette.paper.setFill(); bounds.fill() }
    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accent.withAlphaComponent(Palette.dark ? 0.13 : 0.075).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 3), xRadius: 9, yRadius: 9).fill()
        Palette.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 9, y: 17, width: 2.5, height: bounds.height - 34), xRadius: 1.25, yRadius: 1.25).fill()
    }
}

final class NoteCell: NSTableCellView {
    let heading = label(size: 14, weight: .semibold)
    let preview = label(size: 12)
    let date = label(size: 10.5)
    let pin = NSImageView()
    let tagLabel = label(size: 10.5)
    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [heading, preview, date, pin, tagLabel].forEach { addSubview($0) }
        preview.maximumNumberOfLines = 2; preview.cell?.wraps = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ note: Note, metadata: NoteMetadata) {
        heading.stringValue = metadata.title; preview.stringValue = metadata.preview
        heading.textColor = Palette.ink; preview.textColor = Palette.muted; date.textColor = Palette.muted
        let formatter = Calendar.current.isDateInToday(note.modifiedAt) ? Self.timeFormatter : Self.dayFormatter
        date.stringValue = formatter.string(from: note.modifiedAt)
        pin.image = note.pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(paletteColors: [Palette.accent])) : nil
        pin.image?.isTemplate = false
        pin.contentTintColor = Palette.accent
        tagLabel.stringValue = metadata.tags.first.map { "#" + $0 } ?? ""
        tagLabel.textColor = Palette.accent.withAlphaComponent(0.85)
        setAccessibilityLabel(metadata.title); needsLayout = true
    }
    override func layout() {
        super.layout(); let w = bounds.width
        heading.frame = NSRect(x: 22, y: 14, width: w - 45, height: 20)
        preview.frame = NSRect(x: 22, y: 39, width: w - 45, height: 32)
        pin.frame = NSRect(x: 23, y: 74, width: 10, height: 12)
        date.frame = NSRect(x: pin.image == nil ? 22 : 39, y: 73, width: 70, height: 16)
        tagLabel.frame = NSRect(x: 110, y: 73, width: max(0, w - 133), height: 16)
        tagLabel.alignment = .right
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect); Palette.line.setFill(); NSRect(x: 22, y: bounds.height - 1, width: bounds.width - 44, height: 0.5).fill()
    }
}

final class WorkspaceView: Surface {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    let root = WorkspaceView()
    let sidebar = Surface(), listPane = Surface(), editorPane = Surface(), sidebarDocument = Surface()
    let sidebarScroll = NSScrollView(), notesScroll = NSScrollView()
    let table = NSTableView()
    let editor = MarkdownEditorView()
    let search = NSSearchField()
    let brand = label("Sloth", size: 14, weight: .semibold)
    let listTitle = label("Notes", size: 17, weight: .semibold)
    let noteTitle = label(size: 12, weight: .medium)
    let status = label(size: 10.5)
    let noteCount = label(size: 10.5)
    let empty = label("No notes here yet", size: 16, weight: .medium)
    let listEmpty = label("No notes found", size: 12)
    let formatBar = Surface()
    var sidebarButtons: [SidebarButton] = []
    var sidebarKeys: [String] = []
    var editRefresh: DispatchWorkItem?
    var searchRefresh: DispatchWorkItem?
    var readingPositions: [UUID: (selection: NSRange, scroll: NSPoint)] = [:]
    var topButtons: [ActionButton] = [], formatButtons: [ActionButton] = []
    private let fileOperationQueue = DispatchQueue(label: "Sloth.Files", qos: .userInitiated)
    private(set) var pendingFileOperations = 0
    private(set) var fileOperationStatus: String?
    private struct AttachmentImportContext {
        let noteID: UUID
        let baselineText: String
        let selection: NSRange
    }
    var store: NoteStore!
    var attachments: AttachmentStore!
    var cloud: CloudSyncController?
    var cloudStatusText = "On this Mac"
    weak var syncStatusLabel: NSTextField?
    var visible: [Note] = []
    var selectedID: UUID?
    var displayedID: UUID?
    var section = "all", sort = "modified"
    var showSidebar = true, showList = true, showStyles = true
    var refreshing = false
    var popover: NSPopover?
    var footerSettings: ActionButton!, newButton: ActionButton!, sortButton: ActionButton!, attachmentButton: ActionButton!, syncButton: ActionButton!
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["SLOTH_DATA_DIR"]
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let support = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? base.appendingPathComponent("Sloth", isDirectory: true)
        store = NoteStore(directory: support)
        attachments = AttachmentStore(directory: support)
        Palette.dark = defaults.bool(forKey: "darkTheme")
        section = defaults.string(forKey: "selectedSection") ?? "all"
        sort = defaults.string(forKey: "noteSort") ?? "modified"
        selectedID = defaults.string(forKey: "selectedNote").flatMap(UUID.init(uuidString:))
        showSidebar = defaults.object(forKey: "showSidebar") as? Bool ?? true
        setupWindow(); setupMenus(); buildSidebar(); refresh(selectFirst: true); applyTheme()
        store.onPersistenceChange = { [weak self] in
            guard let self, !self.store.hasPendingChanges || self.store.lastError != nil else { return }; self.updateStatus()
        }
        configureSync(directory: support)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); editor.focus()
    }

    func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1250, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Sloth"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 850, height: 520); window.center(); window.delegate = self
        window.setFrameAutosaveName("SlothWorkspace"); window.contentView = root
        root.onLayout = { [weak self] in self?.layout() }
        [sidebar, listPane, editorPane].forEach { root.addSubview($0) }
        brand.textColor = NSColor(hex: 0xE9E6E1); sidebar.addSubview(brand)
        sidebar.addSubview(sidebarScroll); sidebarScroll.documentView = sidebarDocument
        sidebarScroll.hasVerticalScroller = true; sidebarScroll.drawsBackground = false; sidebarScroll.autohidesScrollers = true
        footerSettings = ActionButton("Settings", symbol: "slider.horizontal.3") { [weak self] in self?.showSettings() }; sidebar.addSubview(footerSettings)
        syncButton = ActionButton("iCloud Drive", symbol: "icloud") { [weak self] in self?.showSettings() }; sidebar.addSubview(syncButton)
        noteCount.textColor = .lightGray; sidebar.addSubview(noteCount)
        listPane.addSubview(listTitle)
        newButton = ActionButton("New note", symbol: "square.and.pencil") { [weak self] in self?.newNote() }; listPane.addSubview(newButton)
        sortButton = ActionButton("Sort notes", symbol: "arrow.up.arrow.down") { [weak self] in self?.showSort() }; listPane.addSubview(sortButton)
        search.placeholderString = "Search notes, #tags…"; search.delegate = self; search.sendsSearchStringImmediately = true; search.font = .systemFont(ofSize: 12)
        search.setAccessibilityLabel("Search notes"); listPane.addSubview(search)
        let column = NSTableColumn(identifier: .init("notes")); table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 96; table.intercellSpacing = .zero
        table.style = .plain; table.selectionHighlightStyle = .regular; table.backgroundColor = Palette.paper
        table.delegate = self; table.dataSource = self; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Notes"); table.allowsEmptySelection = false
        table.menu = noteMenu(); notesScroll.documentView = table; notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true; notesScroll.drawsBackground = false; listPane.addSubview(notesScroll)
        listEmpty.alignment = .center; listPane.addSubview(listEmpty)
        [editor, noteTitle, status, empty, formatBar].forEach { editorPane.addSubview($0) }
        empty.alignment = .center
        let buttons: [(String, String, () -> Void)] = [
            ("Toggle sidebar", "sidebar.left", { [weak self] in self?.toggleSidebar() }),
            ("Pin note", "pin", { [weak self] in
                guard let self else { return }
                if let note = self.selectedID.flatMap({ self.store.note(id: $0) }), note.trashed || note.archived { self.restoreNote() }
                else { self.pinNote() }
            }),
            ("Note information", "info.circle", { [weak self] in self?.showInfo() }),
            ("More actions", "ellipsis", { [weak self] in self?.showMore() })
        ]
        for (title, symbol, action) in buttons { let b = ActionButton(title, symbol: symbol, action: action); topButtons.append(b); editorPane.addSubview(b) }
        let formats = [("Heading", "textformat.size", "heading"), ("Todo", "checkmark.square", "todo"), ("Bullet list", "list.bullet", "bullet"), ("Bold", "bold", "bold"), ("Italic", "italic", "italic"), ("Strikethrough", "strikethrough", "strike"), ("Code", "chevron.left.forwardslash.chevron.right", "code"), ("Link", "link", "link"), ("Quote", "text.quote", "quote")]
        for (title, symbol, format) in formats {
            let b = ActionButton(title, symbol: symbol) { [weak self] in self?.editor.applyFormat(format) }
            formatBar.addSubview(b); formatButtons.append(b)
        }
        attachmentButton = ActionButton("Add image or file", symbol: "paperclip") { [weak self] in self?.addAttachment() }
        formatBar.addSubview(attachmentButton); formatButtons.append(attachmentButton)
        formatBar.wantsLayer = true; formatBar.layer?.cornerRadius = 10
        formatBar.layer?.borderWidth = 0.5
        editor.onChange = { [weak self] text in
            guard let self, let id = self.displayedID ?? self.selectedID else { return }
            self.store.update(id: id, text: text)
            self.refreshAfterEditing(editedID: id)
        }
        editor.onOpenNoteLink = { [weak self] target in self?.openNoteLink(target) ?? false }
        editor.attachmentResolver = { [weak self] path in self?.attachments.resolve(path) }
        editor.onImportFiles = { [weak self] urls in self?.importAttachmentFiles(urls) ?? [] }
        editor.onImportImage = { [weak self] data in
            self?.importAttachmentImage(data)
            // The pasteboard is consumed immediately; the copied image is
            // inserted on completion against its captured destination note.
            return nil
        }
        editor.fontSize = defaults.object(forKey: "fontSize") == nil ? 16 : CGFloat(defaults.double(forKey: "fontSize"))
    }

    func layout() {
        let w = root.bounds.width, h = root.bounds.height
        let side: CGFloat = showSidebar ? 198 : 0
        let list: CGFloat = showList ? (w < 1050 ? 270 : 310) : 0
        sidebar.isHidden = !showSidebar; listPane.isHidden = !showList
        sidebar.frame = NSRect(x: 0, y: 0, width: side, height: h)
        listPane.frame = NSRect(x: side, y: 0, width: list, height: h)
        let ew = w - side - list
        editorPane.frame = NSRect(x: side + list + 1, y: 0, width: ew - 1, height: h)
        brand.frame = NSRect(x: 92, y: 17, width: 85, height: 22)
        sidebarScroll.frame = NSRect(x: 0, y: 66, width: side, height: max(0, h - 112))
        sidebarDocument.frame.size.width = side
        footerSettings.frame = NSRect(x: 16, y: h - 37, width: 25, height: 25)
        noteCount.frame = NSRect(x: 51, y: h - 31, width: 100, height: 18)
        syncButton.frame = NSRect(x: 161, y: h - 37, width: 25, height: 25)
        listTitle.frame = NSRect(x: 23, y: 18, width: max(60, list - 110), height: 26)
        sortButton.frame = NSRect(x: list - 79, y: 17, width: 26, height: 26)
        newButton.frame = NSRect(x: list - 43, y: 15, width: 29, height: 29)
        search.frame = NSRect(x: 17, y: 59, width: list - 34, height: 27)
        notesScroll.frame = NSRect(x: 0, y: 100, width: list, height: h - 100)
        table.tableColumns.first?.width = list
        listEmpty.frame = NSRect(x: 20, y: 147, width: list - 40, height: 24)
        noteTitle.frame = NSRect(x: 52, y: 22, width: max(0, ew - 185), height: 20)
        topButtons[0].frame = NSRect(x: 15, y: 17, width: 25, height: 26)
        for i in 1..<topButtons.count { topButtons[i].frame = NSRect(x: ew - 118 + CGFloat(i - 1) * 35, y: 16, width: 28, height: 28) }
        editor.frame = NSRect(x: 1, y: 56, width: ew - 2, height: max(0, h - (showStyles ? 150 : 92)))
        empty.frame = NSRect(x: 40, y: h / 2 - 15, width: ew - 80, height: 30)
        status.frame = NSRect(x: 30, y: h - 25, width: max(0, ew - 60), height: 17)
        let barWidth: CGFloat = min(368, ew - 24)
        formatBar.frame = NSRect(x: (ew - barWidth) / 2, y: h - 79, width: barWidth, height: 38)
        let buttonSpace = (barWidth - 12) / CGFloat(formatButtons.count)
        for (i, b) in formatButtons.enumerated() { b.frame = NSRect(x: 6 + CGFloat(i) * buttonSpace, y: 5, width: buttonSpace - 5, height: 27) }
    }

    func buildSidebar() {
        let sections = [("Notes", "note.text", "all"), ("Untagged", "tray", "untagged"), ("Todo", "checkmark.square", "todo"), ("Today", "calendar", "today"), ("Pinned", "pin", "pinned"), ("Archive", "archivebox", "archive"), ("Trash", "trash", "trash")]
        var tagSet = Set<String>()
        for tag in store.tags {
            let parts = tag.split(separator: "/")
            guard !parts.isEmpty else { continue }
            for depth in 1...parts.count { tagSet.insert(parts.prefix(depth).joined(separator: "/")) }
        }
        let tags = tagSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let keys = sections.map { $0.2 } + tags.map { "tag:" + $0 }
        let counts = store.sectionCounts
        if keys != sidebarKeys {
            let position = sidebarScroll.contentView.bounds.origin
            sidebarDocument.subviews.forEach { $0.removeFromSuperview() }; sidebarButtons.removeAll()
            sidebarKeys = keys
            var y: CGFloat = 0
            func row(_ name: String, _ symbol: String, _ key: String, depth: Int = 0) {
                let button = SidebarButton(name, symbol: symbol, count: 0) { [weak self] in self?.selectSection(key) }
                button.key = key; button.depth = depth
                button.frame = NSRect(x: 0, y: y, width: 198, height: 34); y += 35
                sidebarDocument.addSubview(button); sidebarButtons.append(button)
            }
            for (name, icon, key) in sections { row(name, icon, key) }
            y += 25
            let heading = label("TAGS", size: 10, weight: .semibold); heading.textColor = NSColor(hex: 0x92999D)
            heading.frame = NSRect(x: 20, y: y, width: 150, height: 18); sidebarDocument.addSubview(heading); y += 25
            for tag in tags {
                let parts = tag.split(separator: "/")
                row(String(parts.last ?? ""), "number", "tag:" + tag, depth: parts.count - 1)
            }
            sidebarDocument.frame.size.height = y + 20
            sidebarScroll.contentView.scroll(to: position); sidebarScroll.reflectScrolledClipView(sidebarScroll.contentView)
        }
        for button in sidebarButtons {
            button.active = section == button.key
            button.count = counts[button.key.lowercased()] ?? 0
            button.setAccessibilityValue("\(button.count) notes")
        }
        noteCount.stringValue = "\(counts["all"] ?? 0) notes"
    }

    func selectSection(_ key: String) {
        searchRefresh?.cancel(); section = key; defaults.set(key, forKey: "selectedSection"); search.stringValue = ""; refresh(selectFirst: true); buildSidebar()
    }
    func queryNotes() -> [Note] {
        store.filtered(section: section == "pinned" ? "all" : section, query: (section == "pinned" ? "@pinned " : "") + search.stringValue, sort: sort)
    }
    func refresh(selectFirst: Bool = false) {
        if defaults.string(forKey: "selectedSection") != section { defaults.set(section, forKey: "selectedSection") }
        refreshing = true; visible = queryNotes(); table.reloadData()
        if let id = selectedID, let index = visible.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !visible.isEmpty { selectedID = visible[0].id; table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { selectedID = nil; table.deselectAll(nil) }
        refreshing = false; listEmpty.isHidden = !visible.isEmpty
        listTitle.stringValue = section.hasPrefix("tag:") ? String(section.dropFirst(4)) : ["all":"Notes", "todo":"Todo", "today":"Today", "untagged":"Untagged", "pinned":"Pinned", "archive":"Archive", "trash":"Trash"][section] ?? "Notes"
        showSelected()
    }
    func showSelected() {
        let note = selectedID.flatMap { store.note(id: $0) }
        editor.isHidden = note == nil; empty.isHidden = note != nil; formatBar.isHidden = note == nil || !showStyles || note?.trashed == true
        editor.setEditable(note?.trashed != true)
        if displayedID != note?.id || editor.text != (note?.text ?? "") {
            if let id = displayedID { readingPositions[id] = (editor.selectedSourceRange, editor.scrollPosition) }
            editor.setText(note?.text ?? "")
            displayedID = note?.id
            if let id = note?.id, let position = readingPositions[id] {
                editor.selectSourceRange(position.selection, scroll: false)
                editor.restoreScrollPosition(position.scroll)
            }
        }
        if defaults.string(forKey: "selectedNote") != note?.id.uuidString { defaults.set(note?.id.uuidString, forKey: "selectedNote") }
        if note == nil { empty.stringValue = search.stringValue.isEmpty ? "A little space for your next idea." : "No notes match your search." }
        updateStatus()
    }
    func refreshAfterEditing(editedID: UUID) {
        editRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let id = editedID
            // Keep the active row stable while typing; update only its existing view.
            self.refreshVisibleNote(id)
            self.buildSidebar(); self.updateStatus()
        }
        editRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func refreshVisibleNote(_ id: UUID) {
        guard let index = visible.firstIndex(where: { $0.id == id }), let note = store.note(id: id) else { return }
        visible[index] = note
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoteCell {
            cell.configure(note, metadata: store.metadata(for: note))
        }
    }
    func updateStatus() {
        guard let note = selectedID.flatMap({ store.note(id: $0) }) else { noteTitle.stringValue = ""; status.stringValue = fileOperationStatus ?? ""; return }
        let metadata = store.metadata(for: note)
        noteTitle.stringValue = metadata.title
        let minutes = max(1, Int(ceil(Double(metadata.wordCount) / 200)))
        status.stringValue = store.lastError.map { "Save error: " + $0 } ?? "\(metadata.wordCount) words   ·   \(metadata.characterCount) characters   ·   \(minutes) min read" + (note.trashed ? "   ·   In Trash — restore to edit" : (store.hasPendingChanges ? "   ·   Saving…" : "   ·   Saved locally"))
        if let fileOperationStatus { status.stringValue = fileOperationStatus }
        status.textColor = store.lastError == nil ? Palette.muted : .systemRed
        let recoverable = note.trashed || note.archived
        let action = recoverable ? "Restore to Notes" : note.pinned ? "Unpin note" : "Pin note"
        topButtons[1].image = NSImage(systemSymbolName: recoverable ? "arrow.uturn.backward" : note.pinned ? "pin.fill" : "pin", accessibilityDescription: action)
        topButtons[1].toolTip = action; topButtons[1].setAccessibilityLabel(action)
        topButtons[1].contentTintColor = recoverable || note.pinned ? Palette.accent : Palette.muted
    }

    @discardableResult
    func openNoteLink(_ target: String) -> Bool {
        let parts = target.components(separatedBy: "#")
        let title = (parts.first ?? target).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = store.notes.filter({ store.metadata(for: $0).title.localizedCaseInsensitiveCompare(title) == .orderedSame })
            .sorted(by: { lhs, rhs in
                if lhs.trashed != rhs.trashed { return !lhs.trashed }
                if lhs.archived != rhs.archived { return !lhs.archived }
                return lhs.modifiedAt > rhs.modifiedAt
            }).first else { NSSound.beep(); return true }
        searchRefresh?.cancel(); search.stringValue = ""
        section = note.trashed ? "trash" : note.archived ? "archive" : "all"
        selectedID = note.id; refresh(); buildSidebar(); editor.focus()
        if let row = visible.firstIndex(where: { $0.id == note.id }) { table.scrollRowToVisible(row) }
        if parts.count > 1 {
            let heading = parts.dropFirst().joined(separator: "#")
            let source = note.text as NSString
            let range = source.range(of: heading, options: .caseInsensitive)
            if range.location != NSNotFound { editor.selectSourceRange(range, scroll: true) }
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: .init("noteCell"), owner: self) as? NoteCell) ?? NoteCell()
        cell.identifier = .init("noteCell"); cell.configure(visible[row], metadata: store.metadata(for: visible[row])); return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NoteRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, visible.indices.contains(table.selectedRow) else { return }
        if let outgoingID = displayedID { refreshVisibleNote(outgoingID) }
        selectedID = visible[table.selectedRow].id; showSelected()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === search else { return }
        searchRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        searchRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc func newNote() {
        section = "all"; search.stringValue = ""
        let note = store.create(text: "# "); selectedID = note.id
        buildSidebar(); refresh(); editor.focus(); editor.selectSourceRange(NSRange(location: 2, length: 0), scroll: true)
    }
    @objc func pinNote() { guard let id = selectedID else { return }; store.togglePin(id: id); refresh(); buildSidebar() }
    @objc func archiveNote() { guard let id = selectedID else { return }; store.archive(id: id); refresh(); buildSidebar() }
    @objc func trashNote() { guard let id = selectedID else { return }; store.trash(id: id); refresh(); buildSidebar() }
    @objc func restoreNote() { guard let id = selectedID else { return }; store.restore(id: id); refresh(); buildSidebar() }
    @objc func duplicateNote() { guard let id = selectedID, let note = store.duplicate(id: id) else { return }; section = "all"; search.stringValue = ""; selectedID = note.id; refresh(); buildSidebar() }
    @objc func focusSearch() { showList = true; root.needsLayout = true; window.makeFirstResponder(search) }
    @objc func toggleSidebar() { showSidebar.toggle(); defaults.set(showSidebar, forKey: "showSidebar"); root.needsLayout = true }
    @objc func toggleFocus() { showList.toggle(); showSidebar = showList; root.needsLayout = true }
    @objc func toggleStyles() { showStyles.toggle(); showSelected(); root.needsLayout = true }
    @objc func formatCommand(_ sender: NSMenuItem) { if let f = sender.representedObject as? String { editor.applyFormat(f) } }
    @objc func toggleTheme() { Palette.dark.toggle(); defaults.set(Palette.dark, forKey: "darkTheme"); applyTheme(); popover?.close() }
    func applyTheme() {
        window.appearance = NSAppearance(named: Palette.dark ? .darkAqua : .aqua)
        window.backgroundColor = Palette.paper
        root.color = Palette.line; sidebar.color = Palette.sidebar; sidebarDocument.color = Palette.sidebar
        listPane.color = Palette.paper; editorPane.color = Palette.paper; table.backgroundColor = Palette.paper
        formatBar.color = Palette.secondary; formatBar.layer?.borderColor = Palette.line.cgColor; editor.isDark = Palette.dark
        for field in [listTitle, noteTitle, empty] { field.textColor = Palette.ink }
        status.textColor = Palette.muted; listEmpty.textColor = Palette.muted
        for button in topButtons + formatButtons + [newButton, sortButton].compactMap({ $0 }) { button.contentTintColor = Palette.muted }
        footerSettings.contentTintColor = NSColor(hex: 0x9FA09F)
        syncButton.contentTintColor = defaults.bool(forKey: "icloudEnabled") ? Palette.accent : NSColor(hex: 0x9FA09F)
        refreshing = true
        table.reloadData()
        if let id = selectedID, let index = visible.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        refreshing = false
        buildSidebar(); updateStatus()
    }

    func menuItem(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.target = self; i.keyEquivalentModifierMask = modifiers; return i
    }
    func noteMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("Pin / Unpin", action: #selector(pinNote)))
        menu.addItem(menuItem("Duplicate", action: #selector(duplicateNote)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Archive", action: #selector(archiveNote)))
        menu.addItem(menuItem("Restore to Notes", action: #selector(restoreNote)))
        menu.addItem(menuItem("Move to Trash", action: #selector(trashNote)))
        menu.addItem(.separator()); menu.addItem(menuItem("Export Markdown…", action: #selector(exportNote)))
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === table.menu, visible.indices.contains(table.clickedRow) {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        }
    }
    func showMore() { noteMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 30), in: topButtons[3]) }
    func showSort() {
        let menu = NSMenu()
        for (title, key) in [("Modification Date", "modified"), ("Creation Date", "created"), ("Title", "title")] {
            let i = menuItem(title, action: #selector(sortChanged(_:))); i.representedObject = key; i.state = sort == key ? .on : .off; menu.addItem(i)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 30), in: sortButton)
    }
    @objc func sortChanged(_ sender: NSMenuItem) { sort = sender.representedObject as? String ?? "modified"; defaults.set(sort, forKey: "noteSort"); refresh() }

    func presentPopover(_ content: NSView, from anchor: NSView) {
        popover?.close(); let p = NSPopover(); p.behavior = .transient
        let vc = NSViewController(); vc.view = content; p.contentViewController = vc; p.contentSize = content.frame.size
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY); popover = p
    }
    func showSettings() {
        let panel = Surface(frame: NSRect(x: 0, y: 0, width: 300, height: 355)); panel.color = Palette.paper
        let title = label("Make yourself at home", size: 16, weight: .semibold); title.frame = NSRect(x: 22, y: 20, width: 260, height: 25); panel.addSubview(title)
        let theme = ActionButton(Palette.dark ? "Switch to Red Graphite" : "Switch to Dark Graphite") { [weak self] in self?.toggleTheme() }
        theme.frame = NSRect(x: 18, y: 62, width: 234, height: 30); theme.contentTintColor = Palette.accent; panel.addSubview(theme)
        let typography = label("Editor text size", size: 12); typography.frame = NSRect(x: 22, y: 112, width: 145, height: 22); panel.addSubview(typography)
        for (index, delta) in [-1.0, 1.0].enumerated() {
            let b = ActionButton(delta < 0 ? "Smaller text" : "Larger text", symbol: delta < 0 ? "minus" : "plus") { [weak self] in
                guard let self else { return }; self.editor.fontSize = max(12, min(26, self.editor.fontSize + delta)); self.defaults.set(self.editor.fontSize, forKey: "fontSize")
            }; b.frame = NSRect(x: 183 + index * 30, y: 108, width: 25, height: 25); panel.addSubview(b)
        }
        let cloudTitle = label("iCloud Drive", size: 13, weight: .semibold); cloudTitle.frame = NSRect(x: 22, y: 161, width: 240, height: 24); panel.addSubview(cloudTitle)
        let cloudToggle = ActionButton(defaults.bool(forKey: "icloudEnabled") ? "Turn off iCloud Drive" : "Enable iCloud Drive") { [weak self] in self?.toggleCloud() }
        cloudToggle.frame = NSRect(x: 18, y: 190, width: 260, height: 29); cloudToggle.contentTintColor = Palette.accent; panel.addSubview(cloudToggle)
        let syncNow = ActionButton("Sync now", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.cloud?.syncNow() }
        syncNow.frame = NSRect(x: 252, y: 160, width: 26, height: 26); syncNow.isEnabled = defaults.bool(forKey: "icloudEnabled"); panel.addSubview(syncNow)
        let detail = label(cloudStatusText, size: 11); detail.maximumNumberOfLines = 3; detail.cell?.wraps = true; detail.frame = NSRect(x: 22, y: 228, width: 256, height: 52); detail.textColor = Palette.muted; panel.addSubview(detail); syncStatusLabel = detail
        let local = label("Sloth keeps a local copy of your notes.\nWhen enabled, attachments sync too.", size: 11); local.maximumNumberOfLines = 2; local.frame = NSRect(x: 22, y: 297, width: 260, height: 40); local.textColor = Palette.muted; panel.addSubview(local)
        presentPopover(panel, from: footerSettings)
    }

    func configureSync(directory: URL) {
        let engine = CloudSync(localDirectory: directory)
        let controller = CloudSyncController(engine: engine, attachmentsDirectory: attachments.rootURL)
        controller.snapshot = { [weak self] in self?.store.notes ?? [] }
        controller.apply = { [weak self] notes, baseline in
            guard let self, !self.editor.hasPendingInput else { return false }
            let changed = notes != self.store.notes
            guard self.store.applySyncedNotes(notes, baseline: baseline) else { return false }
            if changed { self.refresh(); self.buildSidebar() }
            // The editor checks file identities and rebuilds only changed previews.
            self.editor.refreshAttachments()
            return true
        }
        controller.onUpdate = { [weak self] status in
            guard let self else { return }
            self.cloudStatusText = status.message
            self.syncStatusLabel?.stringValue = status.message
            self.syncButton.toolTip = status.message
            self.syncButton.setAccessibilityLabel("iCloud Drive: " + status.message)
            switch status {
            case .working: self.syncButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: status.message)
            case .error, .unavailable: self.syncButton.image = NSImage(systemSymbolName: "exclamationmark.icloud", accessibilityDescription: status.message)
            default: self.syncButton.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: status.message)
            }
        }
        cloud = controller
        if defaults.bool(forKey: "icloudEnabled") { controller.start() }
    }
    func toggleCloud() {
        let enabled = !defaults.bool(forKey: "icloudEnabled")
        defaults.set(enabled, forKey: "icloudEnabled")
        if enabled { cloud?.start() } else { cloud?.stop() }
        syncButton.contentTintColor = enabled ? Palette.accent : NSColor(hex: 0x9FA09F)
        showSettings()
    }
    private func beginFileOperation(_ message: String) {
        precondition(Thread.isMainThread)
        pendingFileOperations += 1
        fileOperationStatus = pendingFileOperations == 1 ? message : "Working with files…"
        updateStatus()
    }
    private func endFileOperation() {
        precondition(Thread.isMainThread)
        pendingFileOperations = max(0, pendingFileOperations - 1)
        fileOperationStatus = pendingFileOperations == 0 ? nil : "Working with files…"
        updateStatus()
    }
    private func captureAttachmentDestination() -> AttachmentImportContext? {
        guard let id = selectedID, let note = store.note(id: id), !note.trashed else { return nil }
        return AttachmentImportContext(noteID: id, baselineText: note.text,
            selection: editor.text == note.text ? editor.selectedSourceRange : NSRange(location: (note.text as NSString).length, length: 0))
    }
    /// Paste/drop starts an asynchronous copy. MarkdownTextView already consumes
    /// the file pasteboard, so no temporary text is inserted into the document.
    func importAttachmentFiles(_ urls: [URL]) -> [String] {
        guard !urls.isEmpty, let context = captureAttachmentDestination() else { return [] }
        enqueueAttachmentFiles(urls, context: context)
        return []
    }
    private func enqueueAttachmentFiles(_ urls: [URL], context: AttachmentImportContext) {
        let destination = attachments!
        beginFileOperation(urls.count == 1 ? "Importing attachment…" : "Importing attachments…")
        fileOperationQueue.async { [weak self] in
            var snippets: [String] = [], errors: [String] = []
            for url in urls {
                do { snippets.append(try destination.importFile(url).markdown) }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let imported = snippets, failures = errors
            DispatchQueue.main.async { [weak self] in
                self?.finishAttachmentImport(imported, context: context, errors: failures)
            }
        }
    }
    private func importAttachmentImage(_ data: Data) {
        guard let context = captureAttachmentDestination() else { return }
        let destination = attachments!
        beginFileOperation("Importing image…")
        fileOperationQueue.async { [weak self] in
            let result = Result { try destination.importPNGData(data, name: "Pasted image").markdown }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let snippet): self?.finishAttachmentImport([snippet], context: context, errors: [])
                case .failure(let error): self?.finishAttachmentImport([], context: context, errors: [error.localizedDescription])
                }
            }
        }
    }
    private func finishAttachmentImport(_ snippets: [String], context: AttachmentImportContext, errors: [String]) {
        precondition(Thread.isMainThread)
        // Provisional IME text is not yet in NoteStore. Wait for composition to
        // finish before comparing the snapshot or touching the editor selection.
        if selectedID == context.noteID, editor.textView.hasMarkedText() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.finishAttachmentImport(snippets, context: context, errors: errors)
            }
            return
        }
        var failures = errors
        if !snippets.isEmpty {
            if let current = store.note(id: context.noteID), !current.trashed {
                let snippet = snippets.joined(separator: "\n\n")
                if selectedID == current.id, editor.text == current.text {
                    if current.text == context.baselineText {
                        editor.selectSourceRange(context.selection, scroll: false)
                        editor.insertMarkdown(snippet)
                    } else {
                        // Typing continued during the copy. Append with native
                        // undo, then restore the person's caret and viewport.
                        let selection = editor.selectedSourceRange, position = editor.scrollPosition
                        editor.selectSourceRange(NSRange(location: (current.text as NSString).length, length: 0), scroll: false)
                        editor.insertMarkdown(snippet)
                        editor.selectSourceRange(selection, scroll: false)
                        editor.restoreScrollPosition(position)
                    }
                } else {
                    let separator = current.text.isEmpty || current.text.hasSuffix("\n") ? "" : "\n"
                    store.update(id: current.id, text: current.text + separator + snippet + "\n")
                    if selectedID == current.id { showSelected() }
                    if let index = visible.firstIndex(where: { $0.id == current.id }), let updated = store.note(id: current.id) {
                        visible[index] = updated
                        (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NoteCell)?.configure(updated, metadata: store.metadata(for: updated))
                    }
                    buildSidebar()
                }
            } else {
                failures.append("The destination note was moved to Trash or is no longer available. Copied files were kept, but no attachment was inserted.")
            }
        }
        endFileOperation()
        if !failures.isEmpty { showError(failures.joined(separator: "\n\n")) }
    }
    @objc func addAttachment() {
        guard let context = captureAttachmentDestination() else { return }
        let panel = NSOpenPanel(); panel.title = "Add images or files"; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = []; panel.allowsOtherFileTypes = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, !panel.urls.isEmpty else { return }
            self.enqueueAttachmentFiles(panel.urls, context: context)
        }
    }
    @objc func showInfo() {
        guard let note = selectedID.flatMap({ store.note(id: $0) }) else { return }
        let metadata = store.metadata(for: note)
        let headings = note.text.components(separatedBy: "\n").filter { $0.hasPrefix("#") && $0.contains(" ") && $0.prefix(6).contains("#") }.filter { $0.range(of: "^#{1,6} ", options: .regularExpression) != nil }
        let panel = Surface(frame: NSRect(x: 0, y: 0, width: 300, height: min(520, 240 + CGFloat(headings.count) * 31))); panel.color = Palette.paper
        let title = label("Note information", size: 16, weight: .semibold); title.frame = NSRect(x: 22, y: 20, width: 250, height: 25); panel.addSubview(title)
        let stats = label("\(metadata.wordCount)  words\n\(metadata.characterCount)  characters\n\(max(1, Int(ceil(Double(metadata.wordCount) / 200)))) min  reading time", size: 13); stats.maximumNumberOfLines = 3; stats.frame = NSRect(x: 22, y: 63, width: 255, height: 65); panel.addSubview(stats)
        let date = label("Edited " + note.modifiedAt.formatted(date: .abbreviated, time: .shortened), size: 10.5); date.textColor = Palette.muted; date.frame = NSRect(x: 22, y: 142, width: 255, height: 20); panel.addSubview(date)
        let outline = label("TABLE OF CONTENTS", size: 10, weight: .semibold); outline.textColor = Palette.muted; outline.frame = NSRect(x: 22, y: 188, width: 250, height: 18); panel.addSubview(outline)
        for (index, heading) in headings.prefix(9).enumerated() {
            let name = heading.replacingOccurrences(of: "^#+ ", with: "", options: .regularExpression)
            let b = ActionButton(name) { [weak self] in
                guard let self else { return }; let range = (self.editor.text as NSString).range(of: heading)
                if range.location != NSNotFound { self.editor.selectSourceRange(range, scroll: true) }; self.popover?.close(); self.editor.focus()
            }; b.alignment = .left; b.frame = NSRect(x: 22, y: 216 + index * 31, width: 254, height: 27); b.contentTintColor = Palette.ink; panel.addSubview(b)
        }
        presentPopover(panel, from: topButtons[2])
    }

    @objc func importNotes() {
        let panel = NSOpenPanel(); panel.title = "Import Markdown notes"; panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, !panel.urls.isEmpty else { return }
            self.importMarkdownFiles(panel.urls)
        }
    }
    func importMarkdownFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let destination = attachments!, startingSelection = selectedID
        let startingText = selectedID.flatMap { store.note(id: $0)?.text }, startingRange = editor.selectedSourceRange
        beginFileOperation("Importing notes…")
        fileOperationQueue.async { [weak self] in
            var texts: [String] = [], failures: [String] = []
            for url in urls {
                do {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    texts.append(try destination.importMarkdown(text: raw, relativeTo: url.deletingLastPathComponent()))
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            let imported = texts, errors = failures
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let lastCreated = self.store.createBatch(texts: imported).last?.id
                // Do not take the person away from a note they selected while
                // the files were loading. Imported notes remain in the library.
                if let lastCreated, self.selectedID == startingSelection,
                   self.selectedID.flatMap({ self.store.note(id: $0)?.text }) == startingText,
                   self.editor.selectedSourceRange == startingRange, !self.editor.textView.hasMarkedText() {
                    self.section = "all"; self.search.stringValue = ""; self.selectedID = lastCreated
                }
                self.refresh(); self.buildSidebar(); self.endFileOperation()
                if !errors.isEmpty { self.showError("Could not import:\n\n" + errors.joined(separator: "\n\n")) }
            }
        }
    }
    @objc func exportNote() {
        guard let note = selectedID.flatMap({ store.note(id: $0) }) else { return }
        let panel = NSSavePanel(); panel.title = "Export Markdown"; panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = panel.url else { return }
            self.exportMarkdown(text: note.text, to: url)
        }
    }
    func exportMarkdown(text: String, to url: URL) {
        let source = attachments!
        beginFileOperation("Exporting note…")
        fileOperationQueue.async { [weak self] in
            let result = Result { try source.exportMarkdown(text: text, to: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.endFileOperation()
                if case .failure(let error) = result { self.showError(error.localizedDescription) }
            }
        }
    }
    func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "Unable to complete action"; alert.informativeText = message; alert.beginSheetModal(for: window) }
    func setupMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func add(_ name: String) -> NSMenu { let item = NSMenuItem(); item.title = name; let menu = NSMenu(title: name); item.submenu = menu; main.addItem(item); return menu }
        let app = add("Sloth")
        let about = NSMenuItem(title: "About Sloth", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""); app.addItem(about)
        app.addItem(menuItem("Switch Theme", action: #selector(toggleTheme), key: "d", modifiers: [.command, .shift])); app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Sloth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let file = add("File"); file.addItem(menuItem("New Note", action: #selector(newNote), key: "n")); file.addItem(.separator())
        file.addItem(menuItem("Import Markdown…", action: #selector(importNotes), key: "i", modifiers: [.command, .shift])); file.addItem(menuItem("Export Markdown…", action: #selector(exportNote), key: "e", modifiers: [.command, .shift]))
        file.addItem(menuItem("Add Images or Files…", action: #selector(addAttachment), key: "a", modifiers: [.command, .option]))
        file.addItem(.separator()); file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let edit = add("Edit")
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: name, action: Selector(selector), keyEquivalent: key)) }
        edit.addItem(.separator()); edit.addItem(menuItem("Search Notes", action: #selector(focusSearch), key: "f", modifiers: [.command, .shift]))
        let view = add("View"); view.addItem(menuItem("Toggle Sidebar", action: #selector(toggleSidebar), key: "1")); view.addItem(menuItem("Focus Mode", action: #selector(toggleFocus), key: "2")); view.addItem(menuItem("Show Styles Bar", action: #selector(toggleStyles), key: "y", modifiers: [.command, .shift])); view.addItem(menuItem("Note Information", action: #selector(showInfo), key: "i", modifiers: [.command, .option]))
        let format = add("Format")
        for (name, value, key) in [("Bold", "bold", "b"), ("Italic", "italic", "i"), ("Strikethrough", "strike", ""), ("Heading", "heading", "h"), ("Todo", "todo", "t"), ("Bullet List", "bullet", "l"), ("Code", "code", "k"), ("Link", "link", ""), ("Quote", "quote", "")] {
            let i = menuItem(name, action: #selector(formatCommand(_:)), key: key, modifiers: value == "bold" || value == "italic" ? .command : [.command, .shift]); i.representedObject = value; format.addItem(i)
        }
        let note = add("Note"); note.addItem(menuItem("Pin / Unpin", action: #selector(pinNote), key: "p", modifiers: [.command, .shift])); note.addItem(menuItem("Duplicate", action: #selector(duplicateNote), key: "d")); note.addItem(menuItem("Archive", action: #selector(archiveNote), key: "a", modifiers: [.command, .shift])); note.addItem(menuItem("Move to Trash", action: #selector(trashNote), key: "\u{8}", modifiers: .command)); note.addItem(menuItem("Restore to Notes", action: #selector(restoreNote)))
        let win = add("Window"); NSApp.windowsMenu = win; win.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")); win.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    }
    func applicationDidResignActive(_ notification: Notification) { editor.finishPendingComposition(); _ = store?.flush() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor.finishPendingComposition()
        if pendingFileOperations > 0 {
            window.makeKeyAndOrderFront(nil)
            let alert = NSAlert(); alert.messageText = "Sloth is finishing a file operation"
            alert.informativeText = "Your import or export is still running. You can keep writing and quit once it finishes."
            alert.addButton(withTitle: "Keep Sloth Open"); alert.runModal()
            return .terminateCancel
        }
        guard store.flush() else {
            let alert = NSAlert(); alert.messageText = "Your latest changes could not be saved"; alert.informativeText = store.lastError ?? "Check the notes folder and try again."; alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                return .terminateCancel
            }
            return .terminateNow
        }; cloud?.stop(); return .terminateNow
    }
}

#if !SLOTH_TESTING
@main struct SlothApp {
    static func main() {
        let app = NSApplication.shared; let delegate = AppController(); app.delegate = delegate
        app.setActivationPolicy(.regular); withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
