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

    var title: String {
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "Untitled note"
        }
        let clean = Self.plainLine(line)
        return clean.isEmpty ? "Untitled note" : clean
    }

    var preview: String {
        let lines = text.components(separatedBy: .newlines)
        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return "Start writing…" }
        let body = lines.dropFirst(titleIndex + 1)
            .map(Self.plainLine)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: " ")
        return body.isEmpty ? "No additional text" : String(body.prefix(220))
    }

    var tags: [String] {
        // A heading's # is followed by whitespace, so it is never a tag.
        // Exclude inline and fenced code, where a hashtag is literal text.
        let source = Self.prose(text)
        let pattern = "(?<![\\p{L}\\p{N}_/])#([\\p{L}\\p{N}][\\p{L}\\p{M}\\p{N}_-]*(?:/[\\p{L}\\p{N}][\\p{L}\\p{M}\\p{N}_-]*)*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var seen = Set<String>()
        return regex.matches(in: source, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            let tag = String(source[range])
            return seen.insert(tag.lowercased()).inserted ? tag : nil
        }
    }

    var hasTodo: Bool {
        Self.prose(text).range(of: "(?m)^[ \\t]*[-*+][ \\t]+\\[ \\]", options: .regularExpression) != nil
    }

    var wordCount: Int {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{M}\\p{N}]*(?:[’'][\\p{L}\\p{M}\\p{N}]+)*") else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    var characterCount: Int { text.count }

    private static func prose(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?ms)^[ \\t]*(`{3,}|~{3,})[^\\n]*(?:\\n|$).*?(?:^[ \\t]*\\1[ \\t]*(?:\\n|$)|\\z)",
            with: " ", options: .regularExpression
        ).replacingOccurrences(of: "`[^`\\n]*`", with: " ", options: .regularExpression)
    }

    private static func plainLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^(?:#{1,6}(?:\\s+|$)|>\\s*|[-*+]\\s+(?:\\[[ xX]\\]\\s*)?|\\d+\\.\\s+)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "!?\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Small, local-first persistence. Files are owned by this reconstruction only.
final class NoteStore {
    private(set) var notes: [Note] = []
    let storageURL: URL
    private(set) var lastError: String?
    private var protectsUnreadableFile = false
    private let fileManager = FileManager.default

    init(directory: URL, seed: Bool = true) {
        storageURL = directory.appendingPathComponent("notes.json")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            notes = seed ? Self.demoNotes() : []
            lastError = "Notes could not be saved: \(error.localizedDescription)"
            return
        }

        guard fileManager.fileExists(atPath: storageURL.path) else {
            notes = seed ? Self.demoNotes() : []
            _ = save()
            return
        }

        do {
            notes = try Self.readNotes(at: storageURL)
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
            let recovered = try? Self.readNotes(at: backupURL)
            notes = recovered ?? (seed ? Self.demoNotes() : [])
            let message = recovered != nil
                ? "Recovered your notes from the last backup. The unreadable file was preserved at \(preserved.path)."
                : "The notes file could not be read. Its contents were preserved at \(preserved.path)."
            if save() { lastError = message }
        }
    }

    var tags: [String] {
        var seen = Set<String>()
        return notes.filter { !$0.trashed && !$0.archived }
            .flatMap(\.tags)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func note(id: UUID) -> Note? { notes.first { $0.id == id } }

    /// A background merge may only replace the exact snapshot it started from.
    /// If typing happened while it ran, the sync controller retries with fresh data.
    @discardableResult
    func applySyncedNotes(_ incoming: [Note], baseline: [Note]) -> Bool {
        guard notes == baseline, Set(incoming.map(\.id)).count == incoming.count else { return false }
        let previous = notes
        notes = incoming
        guard save() else { notes = previous; return false }
        return true
    }

    @discardableResult
    func create(text: String = "") -> Note {
        let note = Note(text: text)
        notes.insert(note, at: 0)
        _ = save()
        return note
    }

    func update(id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        _ = save()
    }

    func togglePin(id: UUID) {
        mutate(id: id) { $0.pinned.toggle() }
    }

    func archive(id: UUID) {
        mutate(id: id) { $0.archived = true; $0.trashed = false }
    }

    func trash(id: UUID) {
        mutate(id: id) { $0.trashed = true; $0.archived = false }
    }

    func restore(id: UUID) {
        mutate(id: id) { $0.trashed = false; $0.archived = false }
    }

    @discardableResult
    func duplicate(id: UUID) -> Note? {
        guard let original = note(id: id) else { return nil }
        return create(text: original.text)
    }

    /// Supported sections: all, today, todo, untagged, archive, trash, tag:<name>.
    /// Search terms are ANDed, with quoted phrases and #tag / @todo / @untagged / @pinned.
    func filtered(section: String, query: String = "", sort: String = "modified") -> [Note] {
        let normalizedSection = section.lowercased()
        var result = notes.filter { note in
            switch normalizedSection {
            case "trash": return note.trashed
            case "archive": return note.archived && !note.trashed
            default:
                guard !note.trashed && !note.archived else { return false }
                switch normalizedSection {
                case "today": return Calendar.current.isDateInToday(note.modifiedAt)
                case "todo": return note.hasTodo
                case "untagged": return note.tags.isEmpty
                default:
                    if normalizedSection.hasPrefix("tag:") {
                        return Self.containsTag(note, tag: String(normalizedSection.dropFirst(4)))
                    }
                    return true
                }
            }
        }
        let regex = try? NSRegularExpression(pattern: "\"([^\"]+)\"|(\\S+)")
        let terms = regex?.matches(in: query, range: NSRange(query.startIndex..<query.endIndex, in: query)).compactMap { match -> String? in
            guard let range = Range(match.range, in: query) else { return nil }
            return String(query[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } ?? []
        result = result.filter { note in
            terms.allSatisfy { term in
                switch term.lowercased() {
                case "@todo": return note.hasTodo
                case "@untagged": return note.tags.isEmpty
                case "@pinned": return note.pinned
                default:
                    if term.hasPrefix("#"), term.count > 1 {
                        return Self.containsTag(note, tag: String(term.dropFirst()))
                    }
                    return note.text.localizedStandardContains(term)
                }
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            switch sort {
            case "title":
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case "created":
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            default:
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @discardableResult
    func save() -> Bool {
        guard !protectsUnreadableFile else { return false }
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(notes)
            // Only a valid existing file can replace the previous good backup.
            if let previous = try? Data(contentsOf: storageURL),
               (try? Self.decode(previous)) != nil {
                try previous.write(to: backupURL, options: .atomic)
            }
            try data.write(to: storageURL, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Notes could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private var backupURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("notes.backup.json")
    }

    private func mutate(id: UUID, change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        notes[index].modifiedAt = Date()
        _ = save()
    }

    private static func containsTag(_ note: Note, tag: String) -> Bool {
        let sought = tag.lowercased()
        return note.tags.contains {
            let candidate = $0.lowercased()
            return candidate == sought || candidate.hasPrefix(sought + "/")
        }
    }

    private static func readNotes(at url: URL) throws -> [Note] {
        try decode(Data(contentsOf: url))
    }

    private static func decode(_ data: Data) throws -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let notes = try decoder.decode([Note].self, from: data)
        guard Set(notes.map(\.id)).count == notes.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
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
