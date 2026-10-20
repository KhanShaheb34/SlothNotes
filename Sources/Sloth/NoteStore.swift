import Foundation

/// The complete, portable contents of a note. No data is read from the Bear app.
struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var modifiedAt: Date
    var pinned: Bool
    var archived: Bool
    var trashed: Bool

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(),
         modifiedAt: Date? = nil, pinned: Bool = false,
         archived: Bool = false, trashed: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.pinned = pinned
        self.archived = archived
        self.trashed = trashed
    }

    fileprivate static let todoRegex = try! NSRegularExpression(pattern: #"(?m)^[ \t]*[-*+][ \t]+\[ \]"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:[’'][\p{L}\p{M}\p{N}]+)*"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let leadingMarkupRegex = try! NSRegularExpression(pattern: #"^(?:#{1,6}(?:\s+|$)|>\s*|[-*+]\s+(?:\[[ xX]\]\s*)?|\d+\.\s+)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"!?\[([^\]]+)\]\([^)]*\)"#)
    private static let emphasisRegex = try! NSRegularExpression(pattern: #"[*_`~]"#)

    var title: String {
        var title = "Untitled note"
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, _, stop in
            guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let clean = Self.plainLine(line)
            if !clean.isEmpty { title = clean }
            stop = true
        }
        return title
    }

    var preview: String {
        var foundTitle = false
        var body = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, _, stop in
            guard let line else { return }
            if !foundTitle {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { foundTitle = true }
                return
            }
            let clean = Self.plainLine(line)
            guard !clean.isEmpty, !clean.hasPrefix("#") else { return }
            if !body.isEmpty { body += " " }
            body += String(clean.prefix(max(0, 220 - body.count)))
            if body.count >= 220 { stop = true }
        }
        if !foundTitle { return "Start writing…" }
        return body.isEmpty ? "No additional text" : body
    }

    var tags: [String] { Self.tags(in: Self.prose(text)) }

    fileprivate static func tags(in source: String) -> [String] {
        var seen = Set<String>()
        return MarkdownTagSyntax.matches(in: source).compactMap { match in
            seen.insert(match.name.lowercased()).inserted ? match.name : nil
        }
    }

    var hasTodo: Bool {
        let source = Self.prose(text)
        return Self.todoRegex.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) != nil
    }

    var wordCount: Int {
        Self.wordRegex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    var characterCount: Int { text.count }

    fileprivate static func prose(_ text: String) -> String {
        // ASCII delimiter detection avoids Unicode substring searching for the
        // common case of plain prose with no code markers at all.
        if !text.utf8.contains(96), !text.utf8.contains(126) { return text }
        if !text.contains("```"), !text.contains("~~~") {
            return text.contains("`") ? replace(inlineCodeRegex, in: text, with: " ") : text
        }
        // Match the editor's fence rules: the closing run must use the same
        // character and be at least as long as the opening run. A shorter or
        // mismatched run remains code, and an unfinished block runs to EOF.
        let source = text as NSString
        var cursor = 0
        var proseStart = 0
        var opening: (character: Character, count: Int)?
        var pieces: [String] = []
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = line.first, first == "`" || first == "~" {
                let count = line.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if let start = opening {
                        if first == start.character, count >= start.count,
                           line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                            pieces.append(" ")
                            proseStart = NSMaxRange(lineRange)
                            opening = nil
                        }
                    } else {
                        pieces.append(source.substring(with: NSRange(location: proseStart, length: lineRange.location - proseStart)))
                        opening = (first, count)
                    }
                }
            }
            cursor = NSMaxRange(lineRange)
        }
        if opening == nil {
            pieces.append(source.substring(with: NSRange(location: proseStart, length: source.length - proseStart)))
        }
        return replace(inlineCodeRegex, in: pieces.joined(), with: " ")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: replacement)
    }

    private static func plainLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = replace(leadingMarkupRegex, in: trimmed, with: "")
        let linked = replace(linkRegex, in: leading, with: "$1")
        return replace(emphasisRegex, in: linked, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Immutable text analysis shared by list rows, sidebar filters, and the inspector.
/// Expensive fields are evaluated only when that part of the UI needs them.
final class NoteMetadata {
    fileprivate let note: Note
    init(_ note: Note) { self.note = note }
    lazy var title = note.title
    lazy var preview = note.preview
    private lazy var prose = Note.prose(note.text)
    lazy var tags = Note.tags(in: prose)
    lazy var normalizedTags = tags.map { $0.lowercased() }
    lazy var hasTodo = Note.todoRegex.firstMatch(in: prose, range: NSRange(prose.startIndex..<prose.endIndex, in: prose)) != nil
    lazy var wordCount = note.wordCount
    lazy var characterCount = note.characterCount
}

/// Owns the file state on a serial queue. The previous successfully decoded or
/// written bytes are already known to be valid, so saving need not reread/decode
/// the entire library just to produce a last-good backup.
private final class NoteFileWriter {
    let queue = DispatchQueue(label: "local.sloth.notes.persistence", qos: .utility)
    let storageURL: URL
    var previousData: Data?

    init(storageURL: URL) { self.storageURL = storageURL }

    func persist(_ notes: [Note]) -> String? {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(notes)
            if let previousData {
                try previousData.write(to: directory.appendingPathComponent("notes.backup.json"), options: .atomic)
            }
            try data.write(to: storageURL, options: .atomic)
            previousData = data
            return nil
        } catch {
            return "Notes could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Main-thread library model. Typing updates memory immediately and coalesces
/// disk work on a background queue. Lifecycle boundaries call flush() so the
/// latest edit is durable before quitting, exporting, or replacing the library.
final class NoteStore {
    private(set) var notes: [Note] = []
    let storageURL: URL
    private(set) var lastError: String?
    private(set) var hasPendingChanges = false
    var onPersistenceChange: (() -> Void)?
    private var protectsUnreadableFile = false
    private let fileManager = FileManager.default
    private let writer: NoteFileWriter
    private var autosaveWork: DispatchWorkItem?
    private var firstUnsavedEdit: Date?
    private var revision: UInt64 = 0
    private var completedRevision: UInt64 = 0
    private var writeAttempt: UInt64 = 0
    private var noteIndices: [UUID: Int] = [:]
    private var metadataCache: [UUID: NoteMetadata] = [:]
    private var filterCache: [FilterKey: [Note]] = [:]
    private var cachedTags: [String]?
    private var cachedSectionCounts: [String: Int]?
    private var cacheDay = Calendar.current.startOfDay(for: Date())
    private static let queryRegex = try! NSRegularExpression(pattern: #"(#[^\s#](?:[^#\r\n]*?[^\s#])?#)|"([^"]+)"|(\S+)"#)

    private struct FilterKey: Hashable {
        let section: String
        let query: String
        let sort: String
    }

    init(directory: URL, seed: Bool = true) {
        storageURL = directory.appendingPathComponent("notes.json")
        writer = NoteFileWriter(storageURL: storageURL)
        defer { rebuildIndices() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            notes = seed ? Self.demoNotes() : []
            hasPendingChanges = true
            lastError = "Notes could not be saved: \(error.localizedDescription)"
            return
        }

        guard fileManager.fileExists(atPath: storageURL.path) else {
            notes = seed ? Self.demoNotes() : []
            _ = save()
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            notes = try Self.decode(data)
            writer.previousData = data
        } catch {
            let preserved = directory.appendingPathComponent("notes.corrupt-\(UUID().uuidString).json")
            do {
                try fileManager.copyItem(at: storageURL, to: preserved)
            } catch {
                protectsUnreadableFile = true
                notes = seed ? Self.demoNotes() : []
                lastError = "The notes file could not be read or backed up. It has been left untouched. Changes cannot be saved until the file is recovered: \(storageURL.path)"
                return
            }
            let backupData = try? Data(contentsOf: directory.appendingPathComponent("notes.backup.json"))
            let recovered = backupData.flatMap { try? Self.decode($0) }
            if recovered != nil { writer.previousData = backupData }
            notes = recovered ?? (seed ? Self.demoNotes() : [])
            let message = recovered != nil
                ? "Recovered your notes from the last backup. The unreadable file was preserved at \(preserved.path)."
                : "The notes file could not be read. Its contents were preserved at \(preserved.path)."
            if save() { lastError = message }
        }
    }

    deinit {
        autosaveWork?.cancel()
        if hasPendingChanges && !protectsUnreadableFile {
            let snapshot = notes
            _ = writer.queue.sync { writer.persist(snapshot) }
        }
    }

    var tags: [String] {
        ensureSidebarIndex()
        return cachedTags ?? []
    }

    /// Includes ancestor tag counts without sorting whole note arrays.
    var sectionCounts: [String: Int] {
        ensureSidebarIndex()
        return cachedSectionCounts ?? [:]
    }

    func metadata(for note: Note) -> NoteMetadata {
        if let metadata = metadataCache[note.id], metadata.note.text == note.text { return metadata }
        let metadata = NoteMetadata(note)
        metadataCache[note.id] = metadata
        return metadata
    }

    func note(id: UUID) -> Note? { noteIndices[id].map { notes[$0] } }

    /// A background merge may only replace the exact snapshot it started from.
    /// It is committed to disk before the sync controller advances its checkpoint.
    @discardableResult
    func applySyncedNotes(_ incoming: [Note], baseline: [Note]) -> Bool {
        guard notes == baseline, Set(incoming.map(\.id)).count == incoming.count else { return false }
        if incoming == notes { return flush() }
        let previous = notes
        notes = incoming
        revision &+= 1
        hasPendingChanges = true
        guard persistSynchronously(notify: false) else {
            notes = previous
            rebuildIndices()
            invalidateCollectionCaches()
            onPersistenceChange?()
            return false
        }
        rebuildIndices()
        metadataCache = metadataCache.filter { id, value in note(id: id)?.text == value.note.text }
        invalidateCollectionCaches()
        onPersistenceChange?()
        return true
    }

    @discardableResult
    func create(text: String = "") -> Note {
        createBatch(texts: [text])[0]
    }

    /// Bulk imports rebuild the identity index and schedule persistence once.
    @discardableResult
    func createBatch(texts: [String]) -> [Note] {
        let created = texts.map { Note(text: $0) }
        guard let first = created.first else { return [] }
        notes.insert(contentsOf: created, at: 0)
        rebuildIndices()
        didChange(id: first.id)
        return created
    }

    func update(id: UUID, text: String) {
        guard let index = noteIndices[id], notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        didChange(id: id)
    }

    func togglePin(id: UUID) { mutate(id: id) { $0.pinned.toggle() } }
    func archive(id: UUID) { mutate(id: id) { $0.archived = true; $0.trashed = false } }
    func trash(id: UUID) { mutate(id: id) { $0.trashed = true; $0.archived = false } }
    func restore(id: UUID) { mutate(id: id) { $0.trashed = false; $0.archived = false } }

    @discardableResult
    func duplicate(id: UUID) -> Note? {
        guard let original = note(id: id) else { return nil }
        return create(text: original.text)
    }

    /// Supported sections: all, today, todo, untagged, pinned, archive, trash, tag:<name>.
    /// Search terms are ANDed, with quoted phrases and #tag / @todo / @untagged / @pinned.
    func filtered(section: String, query: String = "", sort: String = "modified") -> [Note] {
        invalidateForDayChange()
        let normalizedSection = section.lowercased()
        let key = FilterKey(section: normalizedSection, query: query, sort: sort)
        if let cached = filterCache[key] { return cached }
        let terms = Self.queryRegex.matches(in: query, range: NSRange(query.startIndex..<query.endIndex, in: query)).compactMap { match -> String? in
            let capture = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range
            guard let range = Range(capture, in: query) else { return nil }
            return String(query[range])
        }
        let result = notes.filter { note in
            switch normalizedSection {
            case "trash": guard note.trashed else { return false }
            case "archive": guard note.archived && !note.trashed else { return false }
            default:
                guard !note.trashed && !note.archived else { return false }
                switch normalizedSection {
                case "today": guard Calendar.current.isDateInToday(note.modifiedAt) else { return false }
                case "todo": guard metadata(for: note).hasTodo else { return false }
                case "untagged": guard metadata(for: note).tags.isEmpty else { return false }
                case "pinned": guard note.pinned else { return false }
                default:
                    if normalizedSection.hasPrefix("tag:"), !containsTag(note, tag: String(normalizedSection.dropFirst(4))) { return false }
                }
            }
            return terms.allSatisfy { term in
                switch term.lowercased() {
                case "@todo": return metadata(for: note).hasTodo
                case "@untagged": return metadata(for: note).tags.isEmpty
                case "@pinned": return note.pinned
                default:
                    if term.hasPrefix("#"), term.count > 1 {
                        var tag = String(term.dropFirst())
                        if tag.hasSuffix("#") { tag.removeLast() }
                        if MarkdownTagSyntax.isIndexableTag(tag) { return containsTag(note, tag: tag) }
                    }
                    return note.text.localizedStandardContains(term)
                }
            }
        }.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            switch sort {
            case "title":
                let comparison = metadata(for: lhs).title.localizedStandardCompare(metadata(for: rhs).title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case "created":
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            default:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Search-as-you-type should not retain an unbounded history of results.
        if filterCache.count >= 32 { filterCache.removeAll(keepingCapacity: true) }
        filterCache[key] = result
        return result
    }

    /// Flush outstanding background work and the newest in-memory revision.
    /// Returns false on failure while retaining the edit for retry.
    @discardableResult
    func flush() -> Bool {
        autosaveWork?.cancel()
        autosaveWork = nil
        firstUnsavedEdit = nil
        guard hasPendingChanges else { return !protectsUnreadableFile }
        return save()
    }

    /// Explicit durability boundary. Also refreshes the last-good backup.
    @discardableResult
    func save() -> Bool { persistSynchronously(notify: true) }

    private func persistSynchronously(notify: Bool) -> Bool {
        autosaveWork?.cancel()
        autosaveWork = nil
        firstUnsavedEdit = nil
        guard !protectsUnreadableFile else { return false }
        writeAttempt &+= 1
        let snapshot = notes
        let error = writer.queue.sync { writer.persist(snapshot) }
        completedRevision = revision
        lastError = error
        hasPendingChanges = error != nil
        if notify { onPersistenceChange?() }
        return error == nil
    }

    private func didChange(id: UUID) {
        metadataCache.removeValue(forKey: id)
        invalidateCollectionCaches()
        revision &+= 1
        hasPendingChanges = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        if firstUnsavedEdit == nil { firstUnsavedEdit = Date() }
        let delay = min(0.3, max(0, 2 - Date().timeIntervalSince(firstUnsavedEdit!)))
        let work = DispatchWorkItem { [weak self] in self?.beginAutosave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginAutosave() {
        autosaveWork = nil
        firstUnsavedEdit = nil
        guard hasPendingChanges, !protectsUnreadableFile else { return }
        let snapshot = notes
        let savedRevision = revision
        writeAttempt &+= 1
        let attempt = writeAttempt
        let writer = self.writer
        writer.queue.async { [weak self] in
            let error = writer.persist(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self, attempt == self.writeAttempt, savedRevision >= self.completedRevision else { return }
                self.completedRevision = savedRevision
                // A completed older save must never mark newly typed text as saved.
                if savedRevision == self.revision {
                    self.lastError = error
                    self.hasPendingChanges = error != nil
                    self.onPersistenceChange?()
                }
            }
        }
    }

    private func mutate(id: UUID, change: (inout Note) -> Void) {
        guard let index = noteIndices[id] else { return }
        change(&notes[index])
        notes[index].modifiedAt = Date()
        didChange(id: id)
    }

    private func rebuildIndices() {
        noteIndices = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func invalidateCollectionCaches() {
        cachedTags = nil
        cachedSectionCounts = nil
        filterCache.removeAll(keepingCapacity: true)
    }

    private func invalidateForDayChange() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != cacheDay { cacheDay = today; invalidateCollectionCaches() }
    }

    private func ensureSidebarIndex() {
        invalidateForDayChange()
        guard cachedTags == nil || cachedSectionCounts == nil else { return }
        var counts = ["all": 0, "today": 0, "todo": 0, "untagged": 0, "pinned": 0, "archive": 0, "trash": 0]
        var labels: [String: String] = [:]
        for note in notes {
            if note.trashed { counts["trash", default: 0] += 1; continue }
            if note.archived { counts["archive", default: 0] += 1; continue }
            counts["all", default: 0] += 1
            if Calendar.current.isDateInToday(note.modifiedAt) { counts["today", default: 0] += 1 }
            if note.pinned { counts["pinned", default: 0] += 1 }
            let metadata = metadata(for: note)
            if metadata.hasTodo { counts["todo", default: 0] += 1 }
            if metadata.tags.isEmpty { counts["untagged", default: 0] += 1 }
            var noteTagKeys = Set<String>()
            for tag in metadata.tags {
                let normalized = tag.lowercased()
                if labels[normalized] == nil { labels[normalized] = tag }
                let components = normalized.split(separator: "/")
                for index in components.indices {
                    noteTagKeys.insert("tag:" + components.prefix(index + 1).joined(separator: "/"))
                }
            }
            for key in noteTagKeys { counts[key, default: 0] += 1 }
        }
        cachedTags = labels.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cachedSectionCounts = counts
    }

    private func containsTag(_ note: Note, tag: String) -> Bool {
        let sought = tag.lowercased()
        return metadata(for: note).normalizedTags.contains { $0 == sought || $0.hasPrefix(sought + "/") }
    }

    private static func decode(_ data: Data) throws -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let notes = try decoder.decode([Note].self, from: data)
        guard Set(notes.map(\.id)).count == notes.count else { throw CocoaError(.fileReadCorruptFile) }
        return notes
    }

    private static func demoNotes() -> [Note] {
        let content: [(String, Bool)] = [
            ("""
            # Welcome to Sloth

            A beautiful place for your thoughts.

            Some ideas arrive fully formed. Others start as a single word, a question, or a sentence you don't want to lose. Give them a home here.

            ## Make yourself at home

            Write a little. Make a list. Follow a thought wherever it takes you. Everything is saved on this Mac as you go.

            - [x] Find a quiet place to write
            - [ ] Capture your first idea
            - [ ] Make this space your own

            Add #tags anywhere in a note to keep related thoughts together. Try a nested tag like #work/ideas when a little more order feels useful.

            **Small notes. Big possibilities.**

            #welcome
            """, true),
            ("""
            # A place for everything

            A notebook for every part of your day, with room for the unexpected.

            ## A few ways to begin

            - Collect the little things you notice.
            - Keep a running list of questions.
            - Sketch the outline of your next project.
            - Write down a recipe before you forget what made it good.

            Tags are a gentle way to connect things. A note can live in more than one place: a travel idea can be a weekend plan, too.

            Try #personal/travel and #ideas. Select either tag in the sidebar to find your way back.
            """, false),
            ("""
            # A quieter kind of productivity

            The best system is the one that leaves you enough room to think.

            Today, choose one thing that matters. Put it at the top of the page. Give it your attention before the day fills itself up.

            ## Today’s small intentions

            - [ ] Finish the first draft
            - [ ] Take a walk without headphones
            - [x] Clear a little space on the desk

            > You don't have to keep every thought in your head.

            There is something reassuring about a list with an ending.

            #personal #work/ideas
            """, false),
            ("""
            # Weekend notes

            A slow morning, an open window, and no particular hurry.

            ## A small adventure

            Find a new coffee shop. Bring a book. Take the longer way home and pay attention to the street you usually rush past.

            - [ ] Visit the Saturday market
            - [ ] Try making a lemon cake
            - [ ] Call an old friend

            Save a little time for doing absolutely nothing.

            #personal/weekend #ideas
            """, false),
            ("""
            # The reading list

            Books for the nightstand, the train, and those rare afternoons with nowhere to be.

            ## On the shelf

            - A novel with a place you can get lost in
            - Essays that make ordinary things feel new
            - A field guide to something outside your window

            ## Notes to keep

            What surprised me? What did I disagree with? What will I still be thinking about next week?

            A good reading note is a conversation with a book, in your own words.

            #personal/reading
            """, false),
            ("""
            # Design that gets out of the way

            The most useful tools feel obvious after you start using them.

            ## Working principles

            1. Make the next step clear.
            2. Give the important things room to breathe.
            3. Use fewer elements, with more care.
            4. Let the content lead.

            A generous margin. A readable line. A familiar shortcut. Small decisions add up to a place you want to return to.

            **A thought to explore:** what could we remove to make this better?

            #work/design #work/ideas
            """, false)
        ]
        let now = Date()
        return content.enumerated().map { index, entry in
            Note(text: entry.0, createdAt: now.addingTimeInterval(-Double(index + 1) * 86_400),
                 modifiedAt: now.addingTimeInterval(-Double(index) * 3_600), pinned: entry.1)
        }
    }
}
