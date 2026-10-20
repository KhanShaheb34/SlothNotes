import Foundation

/// Source-only Markdown structure shared by the editor's visual presentation.
/// Every range indexes the original UTF-16 source; parsing never changes notes.
enum MarkdownPresentation {
    struct Document: Equatable {
        let headings: [Heading]
        let codeBlocks: [CodeBlock]
        let tables: [Table]

        /// Reuses structure for ordinary edits in prose or code content. The
        /// caller must pass the source this document was parsed from. Structural
        /// lines and edits return nil so their boundaries are parsed afresh.
        func updating(previous: String, range edit: NSRange, replacement: String) -> Document? {
            let source = previous as NSString
            guard edit.location != NSNotFound, edit.location >= 0, edit.length >= 0,
                  edit.location <= source.length, edit.length <= source.length - edit.location else { return nil }
            let removed = source.substring(with: edit)
            guard replacement.rangeOfCharacter(from: .newlines) == nil,
                  removed.rangeOfCharacter(from: .newlines) == nil else { return nil }
            let line = source.lineRange(for: edit)
            let lineText = source.substring(with: line).trimmingCharacters(in: .newlines)
            let structural = CharacterSet(charactersIn: "#|`~<>-")
            guard replacement.rangeOfCharacter(from: structural) == nil,
                  lineText.rangeOfCharacter(from: structural) == nil,
                  !headings.contains(where: { $0.range.location == line.location }),
                  !tables.contains(where: { NSIntersectionRange($0.range, line).length > 0 }),
                  !codeBlocks.contains(where: {
                      $0.openingFenceRange.location == line.location || $0.closingFenceRange?.location == line.location
                  }) else { return nil }
            let delta = (replacement as NSString).length - edit.length
            guard delta != 0 else { return self }
            let editEnd = NSMaxRange(edit)
            func moved(_ range: NSRange, containsInsertion: Bool = false) -> NSRange {
                if edit.length == 0 && containsInsertion && range.location <= edit.location && edit.location <= NSMaxRange(range) {
                    return NSRange(location: range.location, length: range.length + delta)
                }
                if NSMaxRange(range) <= edit.location { return range }
                if range.location >= editEnd { return NSRange(location: range.location + delta, length: range.length) }
                return NSRange(location: range.location, length: range.length + delta)
            }
            let shiftedHeadings = headings.map { heading in
                Heading(range: moved(heading.range), prefixRange: moved(heading.prefixRange), contentRange: moved(heading.contentRange),
                        markerRanges: heading.markerRanges.map { moved($0) }, foldMarkerRange: heading.foldMarkerRange.map { moved($0) },
                        level: heading.level, isFolded: heading.isFolded, bodyRange: moved(heading.bodyRange, containsInsertion: true))
            }
            let shiftedCode = codeBlocks.map { block in
                let inside = NSLocationInRange(edit.location, block.contentRange) ||
                    (block.closingFenceRange == nil && edit.location == NSMaxRange(block.contentRange))
                return CodeBlock(range: moved(block.range, containsInsertion: inside), openingFenceRange: moved(block.openingFenceRange),
                                 closingFenceRange: block.closingFenceRange.map { moved($0) },
                                 contentRange: moved(block.contentRange, containsInsertion: inside), languageRange: block.languageRange.map { moved($0) })
            }
            let shiftedTables = tables.map { table in
                Table(range: moved(table.range), delimiterRange: moved(table.delimiterRange), rows: table.rows.map { row in
                    Row(range: moved(row.range), cells: row.cells.map { Cell(range: moved($0.range), contentRange: moved($0.contentRange)) },
                        markerRanges: row.markerRanges.map { moved($0) }, isHeader: row.isHeader)
                }, alignments: table.alignments)
            }
            return Document(headings: shiftedHeadings, codeBlocks: shiftedCode, tables: shiftedTables)
        }

        /// Nested folded headings keep their own flag, but projection only needs
        /// the outermost hidden range. Empty sections do not hide anything.
        var foldedBodyRanges: [NSRange] {
            var result: [NSRange] = []
            for heading in headings where heading.isFolded && heading.bodyRange.length > 0 {
                if let last = result.last, heading.bodyRange.location < NSMaxRange(last) {
                    result[result.count - 1].length = max(NSMaxRange(last), NSMaxRange(heading.bodyRange)) - last.location
                } else { result.append(heading.bodyRange) }
            }
            return result
        }
    }

    struct Heading: Equatable {
        let range: NSRange
        let prefixRange: NSRange
        let contentRange: NSRange
        let markerRanges: [NSRange]
        let foldMarkerRange: NSRange?
        let level: Int
        let isFolded: Bool
        var bodyRange: NSRange
    }

    struct CodeBlock: Equatable {
        let range: NSRange
        let openingFenceRange: NSRange
        let closingFenceRange: NSRange?
        let contentRange: NSRange
        let languageRange: NSRange?
    }

    enum Alignment: Equatable { case unspecified, left, center, right }

    struct Table: Equatable {
        let range: NSRange
        let delimiterRange: NSRange
        let rows: [Row]
        let alignments: [Alignment]
        var columnCount: Int { alignments.count }
    }

    struct Row: Equatable {
        let range: NSRange
        let cells: [Cell]
        let markerRanges: [NSRange]
        let isHeader: Bool
    }

    struct Cell: Equatable {
        /// Original contents between separators, including surrounding spaces.
        let range: NSRange
        /// Cell contents excluding surrounding spaces; escapes stay in source.
        let contentRange: NSRange
    }

    private struct Line {
        let range: NSRange
        let contentRange: NSRange
    }

    static func parse(_ text: String) -> Document {
        let source = text as NSString
        let lines = sourceLines(source)
        let fencedRanges = AttachmentStore.fencedCodeRanges(in: text)
        let codeBlocks = fencedRanges.map { codeBlock($0, in: source) }
        var fenceIndex = 0
        var fencedLines = Set<Int>()
        for (index, line) in lines.enumerated() {
            while fenceIndex < fencedRanges.count && NSMaxRange(fencedRanges[fenceIndex]) <= line.range.location { fenceIndex += 1 }
            if fenceIndex < fencedRanges.count && NSIntersectionRange(line.range, fencedRanges[fenceIndex]).length > 0 {
                fencedLines.insert(index)
            }
        }

        var headings: [Heading] = []
        var headingLines = Set<Int>()
        for (index, line) in lines.enumerated() where !fencedLines.contains(index) {
            if let heading = heading(line, in: source) {
                headings.append(heading)
                headingLines.insert(index)
            }
        }
        // A stack resolves all section ends in one pass, including nested folds.
        var ancestors: [Int] = []
        for index in headings.indices {
            while let previous = ancestors.last, headings[previous].level >= headings[index].level {
                headings[previous].bodyRange.length = headings[index].range.location - headings[previous].bodyRange.location
                ancestors.removeLast()
            }
            ancestors.append(index)
        }
        for index in ancestors { headings[index].bodyRange.length = source.length - headings[index].bodyRange.location }

        var tables: [Table] = []
        var index = 0
        while index + 1 < lines.count {
            guard !fencedLines.contains(index), !fencedLines.contains(index + 1), !headingLines.contains(index),
                  let header = tableRow(lines[index], in: source, isHeader: true),
                  let delimiter = tableRow(lines[index + 1], in: source, isHeader: false),
                  header.cells.count == delimiter.cells.count,
                  let alignments = delimiterAlignments(delimiter, in: source) else {
                index += 1
                continue
            }
            var rows = [header]
            var end = index + 2
            while end < lines.count, !fencedLines.contains(end), !headingLines.contains(end),
                  let row = tableRow(lines[end], in: source, isHeader: false) {
                var cells = Array(row.cells.prefix(alignments.count))
                // A missing cell has a valid zero-length source range immediately
                // before the newline. Editing it can insert a new source cell.
                let empty = NSRange(location: NSMaxRange(lines[end].contentRange), length: 0)
                while cells.count < alignments.count { cells.append(Cell(range: empty, contentRange: empty)) }
                rows.append(Row(range: row.range, cells: cells, markerRanges: row.markerRanges, isHeader: false))
                end += 1
            }
            let lastRange = end > index + 2 ? lines[end - 1].range : lines[index + 1].range
            tables.append(Table(range: NSRange(location: lines[index].range.location, length: NSMaxRange(lastRange) - lines[index].range.location),
                                delimiterRange: lines[index + 1].range, rows: rows, alignments: alignments))
            index = end
        }
        return Document(headings: headings, codeBlocks: codeBlocks, tables: tables)
    }

    private static func sourceLines(_ source: NSString) -> [Line] {
        var result: [Line] = []
        var cursor = 0
        while cursor < source.length {
            let range = source.lineRange(for: NSRange(location: cursor, length: 0))
            var end = NSMaxRange(range)
            while end > range.location && isNewline(source.character(at: end - 1)) { end -= 1 }
            result.append(Line(range: range, contentRange: NSRange(location: range.location, length: end - range.location)))
            cursor = NSMaxRange(range)
        }
        return result
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 0x2028 || character == 0x2029
    }
    private static func isSpace(_ character: unichar) -> Bool { character == 32 || character == 9 }
    private static func trimmed(_ range: NSRange, in source: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end && isSpace(source.character(at: start)) { start += 1 }
        while end > start && isSpace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
    private static func escaped(_ index: Int, in source: NSString) -> Bool {
        var cursor = index
        while cursor > 0 && source.character(at: cursor - 1) == 92 { cursor -= 1 }
        return (index - cursor) % 2 == 1
    }

    private static let headingPrefix = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#)
    private static let foldSuffix = try! NSRegularExpression(pattern: #"(<!--[ \t]*(\{[^\r\n]*\})[ \t]*-->)[ \t]*$"#)
    private static let headingSuffix = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    private static let delimiterPattern = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)

    private static func heading(_ line: Line, in source: NSString) -> Heading? {
        let value = source.substring(with: line.contentRange)
        let full = NSRange(location: 0, length: (value as NSString).length)
        guard let match = headingPrefix.firstMatch(in: value, range: full) else { return nil }
        let prefix = NSRange(location: line.range.location, length: match.range.length)
        var end = NSMaxRange(line.contentRange)
        var markerRanges = [prefix]
        var foldMarkerRange: NSRange?
        var isFolded = false
        if let fold = foldSuffix.firstMatch(in: value, range: full), fold.range.location >= NSMaxRange(match.range),
           let data = (value as NSString).substring(with: fold.range(at: 2)).data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let flag = object["fold"] as? NSNumber, String(cString: flag.objCType) == "c" {
            let range = NSRange(location: line.range.location + fold.range(at: 1).location, length: fold.range(at: 1).length)
            foldMarkerRange = range
            isFolded = flag.boolValue
            markerRanges.append(range)
            end = range.location
        }
        var content = trimmed(NSRange(location: NSMaxRange(prefix), length: max(0, end - NSMaxRange(prefix))), in: source)
        let title = source.substring(with: content)
        if let suffix = headingSuffix.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)),
           !escaped(content.location + suffix.range.location + 1, in: source) {
            markerRanges.append(NSRange(location: content.location + suffix.range.location, length: suffix.range.length))
            content.length = suffix.range.location
            content = trimmed(content, in: source)
        }
        return Heading(range: line.range, prefixRange: prefix, contentRange: content,
                       markerRanges: markerRanges.sorted { $0.location < $1.location }, foldMarkerRange: foldMarkerRange,
                       level: match.range(at: 1).length, isFolded: isFolded,
                       bodyRange: NSRange(location: NSMaxRange(line.range), length: 0))
    }

    private static func codeBlock(_ range: NSRange, in source: NSString) -> CodeBlock {
        let opening = source.lineRange(for: NSRange(location: range.location, length: 0))
        var fenceStart = opening.location
        while fenceStart < NSMaxRange(opening) && isSpace(source.character(at: fenceStart)) { fenceStart += 1 }
        let character = source.character(at: fenceStart)
        var fenceEnd = fenceStart
        while fenceEnd < NSMaxRange(opening) && source.character(at: fenceEnd) == character { fenceEnd += 1 }
        var languageStart = fenceEnd
        while languageStart < NSMaxRange(opening) && isSpace(source.character(at: languageStart)) { languageStart += 1 }
        var languageEnd = languageStart
        while languageEnd < NSMaxRange(opening) && !isSpace(source.character(at: languageEnd)) && !isNewline(source.character(at: languageEnd)) { languageEnd += 1 }
        let language = languageEnd > languageStart ? NSRange(location: languageStart, length: languageEnd - languageStart) : nil
        var closing: NSRange?
        if NSMaxRange(opening) < NSMaxRange(range) {
            let last = source.lineRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            let literal = source.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines)
            let mark = character == 96 ? Character("`") : Character("~")
            let count = literal.prefix(while: { $0 == mark }).count
            if count >= fenceEnd - fenceStart && literal.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { closing = last }
        }
        let contentStart = NSMaxRange(opening)
        let contentEnd = closing?.location ?? NSMaxRange(range)
        return CodeBlock(range: range, openingFenceRange: opening, closingFenceRange: closing,
                         contentRange: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)), languageRange: language)
    }

    private static func tableRow(_ line: Line, in source: NSString, isHeader: Bool) -> Row? {
        let content = trimmed(line.contentRange, in: source)
        guard content.length > 0 else { return nil }
        let code = inlineCodeRanges(in: content, source: source)
        var separators: [Int] = []
        var codeIndex = 0
        for index in content.location..<NSMaxRange(content) {
            while codeIndex < code.count && NSMaxRange(code[codeIndex]) <= index { codeIndex += 1 }
            if source.character(at: index) == 124 && !escaped(index, in: source),
               !(codeIndex < code.count && NSLocationInRange(index, code[codeIndex])) { separators.append(index) }
        }
        guard !separators.isEmpty else { return nil }
        let markers = separators.map { NSRange(location: $0, length: 1) }
        var start = line.contentRange.location
        var end = NSMaxRange(line.contentRange)
        if separators.first == content.location { start = separators.removeFirst() + 1 }
        if separators.last == NSMaxRange(content) - 1 { end = separators.removeLast() }
        // A line containing only one pipe has no table cells.
        guard start <= end else { return nil }
        var cells: [Cell] = []
        for separator in separators + [end] {
            let range = NSRange(location: start, length: max(0, separator - start))
            cells.append(Cell(range: range, contentRange: trimmed(range, in: source)))
            start = separator + 1
        }
        return Row(range: line.range, cells: cells, markerRanges: markers, isHeader: isHeader)
    }

    private static func delimiterAlignments(_ row: Row, in source: NSString) -> [Alignment]? {
        var result: [Alignment] = []
        for cell in row.cells {
            let value = source.substring(with: cell.contentRange)
            guard delimiterPattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil else { return nil }
            switch (value.hasPrefix(":"), value.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.unspecified)
            }
        }
        return result
    }

    /// Only matched backtick runs establish code spans. An unfinished code span
    /// leaves later pipes usable as cell separators while the user is typing.
    private static func inlineCodeRanges(in range: NSRange, source: NSString) -> [NSRange] {
        var result: [NSRange] = []
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end {
            guard source.character(at: cursor) == 96, !escaped(cursor, in: source) else { cursor += 1; continue }
            let start = cursor
            while cursor < end && source.character(at: cursor) == 96 { cursor += 1 }
            let count = cursor - start
            var search = cursor
            var found = false
            while search < end {
                guard source.character(at: search) == 96 else { search += 1; continue }
                let close = search
                while search < end && source.character(at: search) == 96 { search += 1 }
                if search - close == count {
                    result.append(NSRange(location: start, length: search - start))
                    cursor = search
                    found = true
                    break
                }
            }
            if !found { cursor = start + count }
        }
        return result
    }
}
