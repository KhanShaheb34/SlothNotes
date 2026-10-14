import Foundation
import CryptoKit

/// A local folder exchange is not proof of upload or delivery to another device.
enum CloudSyncStatus {
    case disabled
    case unavailable(String)
    case working
    case ready(Date)
    case error(String)

    var message: String {
        switch self {
        case .disabled: return "iCloud Drive is off"
        case .unavailable(let message), .error(let message): return message
        case .working: return "Updating iCloud Drive…"
        case .ready: return "iCloud Drive folder updated"
        }
    }
}

enum CloudSyncError: LocalizedError {
    case unavailable(String)
    case invalid(String)
    case waiting(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalid(let message), .waiting(let message): return message
        }
    }
}

private struct SyncCheckpoint: Codable {
    var fingerprint: String
    var heads: [String]
}

private struct SyncState: Codable {
    var schemaVersion = 1
    var notes: [String: SyncCheckpoint] = [:]
}

private struct RevisionPayload: Codable {
    let parents: [String]
    let note: Note
}

private struct SyncRevision: Codable {
    let schemaVersion: Int
    let id: String
    let parents: [String]
    let note: Note
}

struct CloudSyncResult {
    let notes: [Note]
    let conflictCount: Int
    let completedAt: Date
    fileprivate let stateData: Data
    fileprivate let destination: URL
}

/// Exchanges immutable revisions with an iCloud Drive folder. The local NoteStore
/// remains authoritative until its caller has saved a result and calls commit.
/// Instantiate and call on a single serial queue; UI scheduling is supplied below.
final class CloudSync {
    let cloudDirectory: URL
    private let localDirectory: URL
    private let usesDefaultCloud: Bool
    private let manager = FileManager.default

    static var iCloudDriveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    init(localDirectory: URL, cloudDirectory: URL? = nil) {
        self.localDirectory = localDirectory
        self.usesDefaultCloud = cloudDirectory == nil
        self.cloudDirectory = cloudDirectory ?? Self.iCloudDriveDirectory.appendingPathComponent("Sloth", isDirectory: true)
    }

    /// The explicit cloudDirectory test/custom transport must already exist.
    /// The default creates only Sloth, never a replacement iCloud Drive root.
    func sync(notes: [Note], attachmentsDirectory: URL? = nil) throws -> CloudSyncResult {
        guard Set(notes.map(\.id)).count == notes.count else {
            throw CloudSyncError.invalid("Duplicate local note IDs; iCloud update was stopped.")
        }
        try checkAvailability()
        let state = try readState()
        var records = try readRevisions()
        var pending: [SyncRevision] = []

        // Publish edits against the last versions this device actually applied,
        // not against newly arrived remote heads. This detects offline conflicts.
        for note in notes {
            let fingerprint = try Self.fingerprint(note)
            let checkpoint = state.notes[note.id.uuidString]
            let missingAppliedHead = checkpoint?.heads.contains { records[note.id]?[$0] == nil } ?? false
            if checkpoint?.fingerprint != fingerprint || missingAppliedHead {
                let revision = try Self.revision(note: note, parents: checkpoint?.heads ?? [])
                if records[note.id]?[revision.id] == nil {
                    records[note.id, default: [:]][revision.id] = revision
                    pending.append(revision)
                }
            }
        }

        var merged: [UUID: Note] = [:]
        var nextState = SyncState()
        var conflictCount = 0
        var work = records.keys.sorted { $0.uuidString < $1.uuidString }
        var visited = Set<UUID>()
        while !work.isEmpty {
            let noteID = work.removeFirst()
            guard visited.insert(noteID).inserted, let group = records[noteID] else { continue }
            let referenced = Set(group.values.flatMap(\.parents))
            let heads = group.values.filter { !referenced.contains($0.id) }.sorted {
                if $0.note.modifiedAt != $1.note.modifiedAt { return $0.note.modifiedAt > $1.note.modifiedAt }
                return $0.id > $1.id
            }
            guard let winner = heads.first else {
                throw CloudSyncError.invalid("The iCloud revision history is invalid. Local notes were preserved.")
            }
            var fingerprints = Set<String>()
            fingerprints.insert(try Self.fingerprint(winner.note))
            for other in heads.dropFirst() {
                let fingerprint = try Self.fingerprint(other.note)
                guard fingerprints.insert(fingerprint).inserted else { continue }
                // The same conflict gets the same identity on every device.
                // An already edited/restored conflict copy must not be replaced.
                var copy = other.note
                copy.id = Self.conflictID(original: noteID, fingerprint: fingerprint)
                if records[copy.id] == nil {
                    copy.text = Self.conflictText(copy.text)
                    copy.trashed = false
                    copy.archived = false
                    copy.pinned = false
                    let revision = try Self.revision(note: copy, parents: [])
                    records[copy.id] = [revision.id: revision]
                    pending.append(revision)
                    work.append(copy.id)
                    conflictCount += 1
                }
            }

            // Collapse observed heads only after retaining every different version.
            // Deterministic IDs keep simultaneous reconciliation idempotent.
            let resolved: SyncRevision
            if heads.count > 1 {
                resolved = try Self.revision(note: winner.note, parents: heads.map(\.id))
                if group[resolved.id] == nil { pending.append(resolved) }
            } else {
                resolved = winner
            }
            merged[noteID] = resolved.note
            nextState.notes[noteID.uuidString] = SyncCheckpoint(
                fingerprint: try Self.fingerprint(resolved.note), heads: [resolved.id])
        }

        guard Set(notes.map(\.id)).isSubset(of: Set(merged.keys)) else {
            throw CloudSyncError.invalid("An iCloud update omitted local notes and was stopped. Local notes were preserved.")
        }
        let localAttachments = attachmentsDirectory ?? localDirectory.appendingPathComponent("attachments", isDirectory: true)
        try exchangeAttachments(local: localAttachments)
        try validateAttachments(in: Array(merged.values), directory: localAttachments)
        // Attachments arrive before a note that references them is published.
        for revision in pending { try writeRevision(revision) }

        let localIDs = Set(notes.map(\.id))
        let ordered = notes.compactMap { merged[$0.id] } + merged.values
            .filter { !localIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return CloudSyncResult(notes: ordered, conflictCount: conflictCount,
                               completedAt: Date(), stateData: try Self.encode(nextState), destination: stateURL)
    }

    /// Call only after all result.notes have been successfully saved locally.
    func commit(_ result: CloudSyncResult) throws {
        guard result.destination == stateURL else {
            throw CloudSyncError.invalid("This update belongs to a different iCloud folder.")
        }
        try manager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try result.stateData.write(to: stateURL, options: .atomic)
    }

    private var stateURL: URL {
        let folderID = Self.digest(Data(cloudDirectory.standardizedFileURL.path.utf8)).prefix(16)
        return localDirectory.appendingPathComponent("icloud-state-\(folderID).json")
    }

    private func checkAvailability() throws {
        let required = usesDefaultCloud ? Self.iCloudDriveDirectory : cloudDirectory
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: required.path, isDirectory: &directory), directory.boolValue else {
            throw CloudSyncError.unavailable(usesDefaultCloud
                ? "iCloud Drive is unavailable. Sign in and enable iCloud Drive in System Settings."
                : "The sync folder is unavailable. Local notes are safe on this Mac.")
        }
        try requireDirectory(required)
        if !manager.fileExists(atPath: cloudDirectory.path) {
            try createDirectory(cloudDirectory)
        }
        try requireDirectory(cloudDirectory)
    }

    private func readState() throws -> SyncState {
        guard manager.fileExists(atPath: stateURL.path) else { return SyncState() }
        let state = try Self.decode(SyncState.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1 else {
            throw CloudSyncError.invalid("This Sloth sync state needs a newer app. Local notes were preserved.")
        }
        guard state.notes.allSatisfy({ UUID(uuidString: $0.key) != nil && Self.isDigest($0.value.fingerprint)
            && !$0.value.heads.isEmpty && $0.value.heads.allSatisfy(Self.isDigest) }) else {
            throw CloudSyncError.invalid("The local iCloud checkpoint is invalid. Local notes were preserved.")
        }
        return state
    }

    private func readRevisions() throws -> [UUID: [String: SyncRevision]] {
        let root = cloudDirectory.appendingPathComponent("revisions", isDirectory: true)
        guard manager.fileExists(atPath: root.path) else { return [:] }
        try requireDirectory(root)
        var result: [UUID: [String: SyncRevision]] = [:]
        for directory in try children(root) {
            if directory.lastPathComponent == ".DS_Store" { continue }
            guard let noteID = UUID(uuidString: directory.lastPathComponent) else {
                throw CloudSyncError.invalid("An unexpected item was found in the iCloud note history.")
            }
            try requireDirectory(directory)
            for file in try children(directory) {
                if file.lastPathComponent == ".DS_Store" { continue }
                try requireRegularFile(file)
                try requestDownloadIfNeeded(file)
                guard file.pathExtension == "json" else {
                    throw CloudSyncError.invalid("An unexpected revision file was found in iCloud Drive.")
                }
                let data = try coordinatedRead(file) { try Data(contentsOf: $0) }
                let record = try Self.decode(SyncRevision.self, from: data)
                let actual = try Self.revision(note: record.note, parents: record.parents)
                guard record.schemaVersion == 1, record.note.id == noteID,
                      Self.isDigest(record.id), record.parents.allSatisfy(Self.isDigest),
                      record.parents == Array(Set(record.parents)).sorted(),
                      !record.parents.contains(record.id), record.id == actual.id,
                      file.deletingPathExtension().lastPathComponent == record.id else {
                    throw CloudSyncError.invalid("An iCloud note revision could not be verified. Local notes were preserved.")
                }
                result[noteID, default: [:]][record.id] = record
            }
        }
        try validateGraph(result)
        return result
    }

    private func validateGraph(_ records: [UUID: [String: SyncRevision]]) throws {
        let ownership = Dictionary(uniqueKeysWithValues: records.flatMap { id, group in group.keys.map { ($0, id) } })
        for (noteID, group) in records {
            var remaining: [String: Int] = [:]
            var children: [String: [String]] = [:]
            for (id, revision) in group {
                remaining[id] = 0
                for parent in revision.parents {
                    if let owner = ownership[parent], owner != noteID {
                        throw CloudSyncError.invalid("An iCloud revision references a different note. Local notes were preserved.")
                    }
                    if group[parent] != nil {
                        remaining[id, default: 0] += 1
                        children[parent, default: []].append(id)
                    }
                }
            }
            // Iterative topological validation avoids deep recursion as immutable
            // history grows. Missing ancestors can legitimately arrive later.
            var ready = remaining.filter { $0.value == 0 }.map(\.key)
            var index = 0
            while index < ready.count {
                let id = ready[index]
                index += 1
                for child in children[id] ?? [] {
                    remaining[child, default: 0] -= 1
                    if remaining[child] == 0 { ready.append(child) }
                }
            }
            guard ready.count == group.count else {
                throw CloudSyncError.invalid("An iCloud revision cycle was found. Local notes were preserved.")
            }
        }
    }

    private func writeRevision(_ revision: SyncRevision) throws {
        let root = cloudDirectory.appendingPathComponent("revisions", isDirectory: true)
        try createDirectory(root)
        let directory = root.appendingPathComponent(revision.note.id.uuidString, isDirectory: true)
        try createDirectory(directory)
        let file = directory.appendingPathComponent(revision.id + ".json")
        let data = try Self.encode(revision)
        try coordinatedWrite(file) { url in
            if self.manager.fileExists(atPath: url.path) {
                try self.requireRegularFile(url)
                let existing = try Data(contentsOf: url)
                guard existing == data else {
                    throw CloudSyncError.invalid("An immutable iCloud revision has conflicting contents.")
                }
            } else {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    private func exchangeAttachments(local: URL) throws {
        let remote = cloudDirectory.appendingPathComponent("attachments", isDirectory: true)
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        try requireDirectory(local)
        try createDirectory(remote)
        try requireDirectory(remote)
        // Copy only. Imported UUID names are immutable; mismatched bytes stop the
        // update instead of replacing either copy. No cleanup deletes user files.
        try copyMissing(from: local, to: remote)
        try copyMissing(from: remote, to: local)
    }

    private func copyMissing(from source: URL, to destination: URL) throws {
        for file in try children(source) {
            if file.lastPathComponent == ".DS_Store" { continue }
            try requireRegularFile(file)
            try requestDownloadIfNeeded(file)
            let target = destination.appendingPathComponent(file.lastPathComponent)
            var coordinationError: NSError?
            var operationError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: file, options: [], writingItemAt: target,
                                   options: [], error: &coordinationError) { readURL, writeURL in
                do {
                    try self.requireRegularFile(readURL)
                    if self.manager.fileExists(atPath: writeURL.path) {
                        try self.requireRegularFile(writeURL)
                        guard try Self.fileDigest(readURL) == Self.fileDigest(writeURL) else {
                            throw CloudSyncError.invalid("Attachment conflict: \(file.lastPathComponent). Both files were preserved.")
                        }
                    } else {
                        // copyItem itself is not atomic. A temporary sibling is
                        // moved into place only after a complete successful copy.
                        let temporary = destination.appendingPathComponent(".sloth-copy-\(UUID().uuidString)")
                        defer { try? self.manager.removeItem(at: temporary) }
                        try self.manager.copyItem(at: readURL, to: temporary)
                        try self.manager.moveItem(at: temporary, to: writeURL)
                    }
                } catch { operationError = error }
            }
            if let error = coordinationError ?? operationError as NSError? { throw error }
        }
    }

    private func validateAttachments(in notes: [Note], directory: URL) throws {
        // Share Markdown parsing with import/export and the editor: fenced code,
        // escaped links and inline examples are not real attachment references.
        let attachments = AttachmentStore(directory: directory.deletingLastPathComponent())
        for note in notes {
            for reference in attachments.references(in: note.text) where reference.path.hasPrefix("attachments/") {
                let name = String(reference.path.dropFirst("attachments/".count))
                guard !name.contains("/"), !name.contains("\\"), !name.isEmpty,
                      name != ".", name != "..", !name.contains("\0") else {
                    throw CloudSyncError.invalid("An attachment link contains an invalid path.")
                }
                let file = directory.appendingPathComponent(name)
                guard manager.fileExists(atPath: file.path) else {
                    throw CloudSyncError.waiting("Waiting for attachment \(name) in iCloud Drive. Local notes are safe.")
                }
                try requireRegularFile(file)
            }
        }
    }

    private func children(_ url: URL) throws -> [URL] {
        try coordinatedRead(url) {
            try self.manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { !$0.lastPathComponent.hasPrefix(".sloth-copy-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private func requestDownloadIfNeeded(_ file: URL) throws {
        if file.lastPathComponent.hasPrefix("."), file.pathExtension == "icloud" {
            let name = String(file.deletingPathExtension().lastPathComponent.dropFirst())
            try? manager.startDownloadingUbiquitousItem(at: file.deletingLastPathComponent().appendingPathComponent(name))
            throw CloudSyncError.waiting("Waiting for iCloud Drive to download \(name)…")
        }
        let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try manager.startDownloadingUbiquitousItem(at: file)
            throw CloudSyncError.waiting("Waiting for iCloud Drive to download \(file.lastPathComponent)…")
        }
    }

    private func createDirectory(_ url: URL) throws {
        if manager.fileExists(atPath: url.path) { try requireDirectory(url); return }
        try coordinatedWrite(url.deletingLastPathComponent()) { parent in
            try self.manager.createDirectory(at: parent.appendingPathComponent(url.lastPathComponent, isDirectory: true), withIntermediateDirectories: false)
        }
        try requireDirectory(url)
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CloudSyncError.invalid("The sync folder contains an unsupported directory or symbolic link.")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CloudSyncError.invalid("The sync folder contains an unsupported file or symbolic link.")
        }
    }

    private func coordinatedRead<T>(_ url: URL, action: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try action(coordinatedURL) }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func coordinatedWrite(_ url: URL, action: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try action(coordinatedURL) }
        }
        if let error = coordinationError { throw error }
        guard let result = result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private static func revision(note: Note, parents: [String]) throws -> SyncRevision {
        let ordered = Array(Set(parents)).sorted()
        // NoteStore persists ISO-8601 seconds. Normalize before comparing heads
        // so subsecond in-memory dates cannot choose different winners per device.
        let canonicalNote = try decode(Note.self, from: encode(note))
        let id = digest(try encode(RevisionPayload(parents: ordered, note: canonicalNote)))
        return SyncRevision(schemaVersion: 1, id: id, parents: ordered, note: canonicalNote)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fingerprint(_ note: Note) throws -> String { digest(try encode(note)) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func conflictID(original: UUID, fingerprint: String) -> UUID {
        let hex = digest(Data((original.uuidString + ":" + fingerprint).utf8))
        let characters = Array(hex.prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }

    private static func conflictText(_ text: String) -> String {
        // Preserve the exact original text below a clearly named wrapper.
        return "# \(Note(text: text).title) (conflict copy)\n\n" + text
    }
}

/// Call public methods on the main thread. File access is serialized off-main;
/// callback application uses an exact baseline to avoid replacing a newer edit.
final class CloudSyncController {
    var snapshot: (() -> [Note])?
    var apply: (([Note], [Note]) -> Bool)?
    var onUpdate: ((CloudSyncStatus) -> Void)?
    private(set) var status: CloudSyncStatus = .disabled
    private let engine: CloudSync
    private let attachmentsDirectory: URL?
    private let queue = DispatchQueue(label: "Sloth.iCloudDrive", qos: .utility)
    private var timer: Timer?
    private var enabled = false
    private var busy = false
    private var generation = 0

    init(engine: CloudSync, attachmentsDirectory: URL? = nil) {
        self.engine = engine
        self.attachmentsDirectory = attachmentsDirectory
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.syncNow() }
        syncNow()
    }

    func stop() {
        enabled = false
        generation += 1
        timer?.invalidate()
        timer = nil
        update(.disabled)
    }

    func syncNow() {
        guard enabled, !busy, let baseline = snapshot?(), apply != nil else { return }
        busy = true
        let token = generation
        update(.working)
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.engine.sync(notes: baseline, attachmentsDirectory: self.attachmentsDirectory) }
            DispatchQueue.main.async { [self] in
                guard self.enabled, self.generation == token else { self.busy = false; return }
                switch result {
                case .failure(let error):
                    self.busy = false
                    if let cloudError = error as? CloudSyncError {
                        switch cloudError {
                        case .unavailable, .waiting: self.update(.unavailable(error.localizedDescription))
                        case .invalid: self.update(.error(error.localizedDescription))
                        }
                    } else { self.update(.error("iCloud Drive: \(error.localizedDescription)")) }
                case .success(let result):
                    guard self.apply?(result.notes, baseline) == true else {
                        self.busy = false
                        self.update(.error("Local notes changed or could not be saved. iCloud update will retry."))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.syncNow() }
                        return
                    }
                    self.queue.async {
                        let commit = Result { try self.engine.commit(result) }
                        DispatchQueue.main.async {
                            self.busy = false
                            guard self.enabled, self.generation == token else { return }
                            switch commit {
                            case .success: self.update(.ready(result.completedAt))
                            case .failure(let error): self.update(.error("Could not save iCloud update state: \(error.localizedDescription)"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func update(_ status: CloudSyncStatus) {
        self.status = status
        onUpdate?(status)
    }

    deinit { timer?.invalidate() }
}
