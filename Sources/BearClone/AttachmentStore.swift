import AppKit
import ImageIO

struct ImportedAttachment {
    let relativePath: String
    let displayName: String
    let isImage: Bool
    let url: URL

    var markdown: String {
        let label = displayName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\(isImage ? "!" : "")[\(label)](\(relativePath))"
    }
}

struct AttachmentReference {
    let range: NSRange
    let destinationRange: NSRange
    let path: String
    let isImage: Bool
    let label: String
}

/// Owns immutable, copied files beside notes.json. Markdown stores portable relative
/// links; source files are never moved, modified, or opened as applications.
final class AttachmentStore {
    let rootURL: URL
    private let fileManager = FileManager.default

    enum Failure: LocalizedError {
        case invalidPath, notRegularFile, invalidImage, missingAttachment(String), collision(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath: return "This attachment path is not allowed. Use a regular file inside the selected folder."
            case .notRegularFile: return "Attachments must be regular files. Folders, apps, and symbolic links cannot be attached."
            case .invalidImage: return "The pasted image could not be read."
            case .missingAttachment(let name): return "The attachment \(name) is missing or unavailable."
            case .collision(let name): return "A different file already exists at \(name). No existing attachment was replaced."
            }
        }
    }

    init(directory: URL) {
        // Resolve the selected data directory, but not the attachment directory:
        // an attachments symlink must be detected rather than silently followed.
        rootURL = directory.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("attachments", isDirectory: true)
    }

    func importFile(_ source: URL) throws -> ImportedAttachment {
        guard source.isFileURL else { throw Failure.invalidPath }
        try requireRegularFile(source)
        try prepareRoot()
        let ext = Self.safeExtension(source.pathExtension)
        let target = rootURL.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
        // Sync ignores this private staging name. Publish a UUID path only after
        // the complete file is present, so a background exchange cannot copy a
        // partially imported attachment or permanently record the wrong digest.
        let temporary = rootURL.appendingPathComponent(".sloth-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try requireRegularFile(temporary)
        try fileManager.moveItem(at: temporary, to: target)
        return ImportedAttachment(relativePath: "attachments/\(target.lastPathComponent)",
                                  displayName: source.lastPathComponent,
                                  isImage: Self.isImage(at: target), url: target)
    }

    func importImage(_ image: NSImage, name: String = "Pasted image") throws -> ImportedAttachment {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.invalidImage
        }
        return try importPNGData(png, name: name)
    }

    func importPNGData(_ data: Data, name: String = "Pasted image") throws -> ImportedAttachment {
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.invalidImage
        }
        try prepareRoot()
        let target = rootURL.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        let temporary = rootURL.appendingPathComponent(".sloth-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try png.write(to: temporary, options: .withoutOverwriting)
        try fileManager.moveItem(at: temporary, to: target)
        return ImportedAttachment(relativePath: "attachments/\(target.lastPathComponent)",
                                  displayName: name, isImage: true, url: target)
    }

    /// Resolves owned attachments only. Absolute URLs, traversal, directories, and
    /// symlinks are rejected even if the Markdown was pasted from another source.
    func resolve(_ relativePath: String) -> URL? {
        guard let filename = Self.ownedFilename(relativePath),
              (try? requireDirectory(rootURL)) != nil else { return nil }
        let url = rootURL.appendingPathComponent(filename)
        guard (try? requireRegularFile(url)) != nil,
              Self.isInside(url.resolvingSymlinksInPath(), directory: rootURL.resolvingSymlinksInPath()) else { return nil }
        return url
    }

    static func isImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let detectedType = CGImageSourceGetType(source) as String?,
              // ImageIO also decodes PDF pages. A PDF is a document attachment,
              // including when its filename has a misleading image extension.
              // Use its detected type; Launch Services UTI conformance can be
              // unavailable to the command-line test process.
              detectedType != "com.adobe.pdf", CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
    }

    /// Imports local links from an explicitly selected Markdown file's directory.
    /// Internet links remain unchanged and are never fetched. A failed import
    /// rolls back all files copied by this operation.
    func importMarkdown(text: String, relativeTo directory: URL) throws -> String {
        guard directory.isFileURL else { throw Failure.invalidPath }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        var imported: [String: ImportedAttachment] = [:]
        var result = text as NSString
        do {
            for reference in references(in: text).reversed() {
                let path = reference.path
                if path.isEmpty || path.hasPrefix("#") || path.hasPrefix("//") || URLComponents(string: path)?.scheme != nil { continue }
                guard !path.hasPrefix("/"), !path.contains("\0"),
                      !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw Failure.invalidPath }
                let source = base.appendingPathComponent(path).standardizedFileURL
                guard Self.isInside(source.resolvingSymlinksInPath(), directory: base) else { throw Failure.invalidPath }
                if !fileManager.fileExists(atPath: source.path) { throw Failure.missingAttachment(path) }
                let attachment: ImportedAttachment
                if let previous = imported[source.path] {
                    attachment = previous
                } else {
                    attachment = try importFile(source)
                    imported[source.path] = attachment
                }
                result = result.replacingCharacters(in: reference.destinationRange, with: attachment.relativePath) as NSString
            }
            return result as String
        } catch {
            for attachment in imported.values { try? fileManager.removeItem(at: attachment.url) }
            throw error
        }
    }

    /// Exports a Markdown file plus its referenced attachments/ files. Stages all
    /// payloads first, rejects conflicting existing assets, and writes the note
    /// atomically last. Failure removes only assets created by this operation.
    func exportMarkdown(text: String, to destination: URL) throws {
        guard destination.isFileURL else { throw Failure.invalidPath }
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try requireDirectory(parent)
        let noteURL = parent.appendingPathComponent(destination.lastPathComponent)
        guard !Self.isInside(noteURL, directory: rootURL.resolvingSymlinksInPath()) else { throw Failure.invalidPath }
        if fileManager.fileExists(atPath: noteURL.path) { try requireRegularFile(noteURL) }
        let exportRoot = parent.appendingPathComponent("attachments", isDirectory: true)
        var sources: [String: URL] = [:]
        for reference in references(in: text) {
            guard reference.path.hasPrefix("attachments/") else { continue }
            guard let filename = Self.ownedFilename(reference.path), let source = resolve(reference.path) else {
                throw Failure.missingAttachment(reference.path)
            }
            sources[filename] = source
        }
        if !sources.isEmpty, fileManager.fileExists(atPath: exportRoot.path) { try requireDirectory(exportRoot) }
        // Do not start copying until all potential collisions have been checked.
        for (filename, source) in sources {
            let target = exportRoot.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: target.path) {
                try requireRegularFile(target)
                guard fileManager.contentsEqual(atPath: source.path, andPath: target.path) else { throw Failure.collision(filename) }
            }
        }
        let stage = parent.appendingPathComponent(".sloth-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stage) }
        for (filename, source) in sources { try fileManager.copyItem(at: source, to: stage.appendingPathComponent(filename)) }
        let noteData = Data(text.utf8)
        try noteData.write(to: stage.appendingPathComponent("note.md"), options: .atomic)
        var created: [URL] = []
        var createdRoot = false
        do {
            if !sources.isEmpty, !fileManager.fileExists(atPath: exportRoot.path) {
                try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: false)
                createdRoot = true
            }
            for (filename, source) in sources {
                let target = exportRoot.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: target.path) {
                    try requireRegularFile(target)
                    guard fileManager.contentsEqual(atPath: source.path, andPath: target.path) else { throw Failure.collision(filename) }
                } else {
                    try fileManager.copyItem(at: stage.appendingPathComponent(filename), to: target)
                    created.append(target)
                }
            }
            try noteData.write(to: noteURL, options: .atomic)
        } catch {
            for url in created { try? fileManager.removeItem(at: url) }
            if createdRoot, (try? fileManager.contentsOfDirectory(atPath: exportRoot.path).isEmpty) == true {
                try? fileManager.removeItem(at: exportRoot)
            }
            throw error
        }
    }

    /// Inline Markdown file/image references, with escaped labels, angle-wrapped
    /// paths, spaces, optional quoted titles, and one level of nested parentheses.
    /// Fenced and inline code are excluded so examples do not become attachments.
    func references(in text: String) -> [AttachmentReference] {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let pattern = #"(!?)\[((?:\\.|[^\]\\\n])*)\]\(\s*(<[^>\n]*>|(?:\\.|[^()\n]|\([^()\n]*\))*)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ignored = Self.codeRanges(in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard !Self.isEscaped(at: match.range.location, source: source),
                  !ignored.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            var range = match.range(at: 3)
            var raw = source.substring(with: range)
            while raw.last?.isWhitespace == true { raw.removeLast(); range.length -= 1 }
            if raw.hasPrefix("<"), raw.hasSuffix(">") {
                raw = String(raw.dropFirst().dropLast()); range.location += 1; range.length -= 2
            } else if let title = raw.range(of: #"\s+[\"'][^\"']*[\"']$"#, options: .regularExpression) {
                let prefix = String(raw[..<title.lowerBound])
                range.length = (prefix as NSString).length
                raw = prefix
            }
            guard !raw.isEmpty else { return nil }
            let decoded = Self.unescape(raw)
            let label = Self.unescape(source.substring(with: match.range(at: 2)))
            return AttachmentReference(range: match.range, destinationRange: range,
                                       path: decoded.removingPercentEncoding ?? decoded,
                                       isImage: match.range(at: 1).length > 0, label: label)
        }
    }

    private func prepareRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireDirectory(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try requireDirectory(rootURL)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        guard url.isFileURL,
              try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.notRegularFile
        }
    }

    private func requireDirectory(_ url: URL) throws {
        guard try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidPath
        }
    }

    private static func safeExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        return !lower.isEmpty && lower.count <= 12 && lower.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) ? lower : "bin"
    }

    private static func ownedFilename(_ path: String) -> String? {
        guard !path.contains("\\"), !path.contains("\0"), !path.contains("%") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "attachments", !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", !parts[1].hasPrefix(".") else { return nil }
        return String(parts[1])
    }

    private static func isInside(_ url: URL, directory: URL) -> Bool {
        url.path.hasPrefix(directory.path + "/")
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!<> -])"#, with: "$1", options: .regularExpression)
    }

    private static func isEscaped(at index: Int, source: NSString) -> Bool {
        var cursor = index - 1
        var slashes = 0
        while cursor >= 0 && source.character(at: cursor) == 92 { slashes += 1; cursor -= 1 }
        return slashes % 2 == 1
    }

    private static func codeRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let patterns = [#"(?ms)^[ \t]*(`{3,}|~{3,})[^\n]*(?:\n|$).*?(?:^[ \t]*\1[ \t]*(?:\n|$)|\z)"#, #"(`+)[^\n]*?\1"#]
        return patterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: full).map(\.range) ?? []
        }
    }
}
