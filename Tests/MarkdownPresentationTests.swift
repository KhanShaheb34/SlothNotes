import AppKit

@main
enum MarkdownPresentationTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func slice(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    static func main() {
        let source = "# Title 😊\r\n## Parent <!-- {\"fold\":true} -->\r\nPrivate body\r\n### Child\r\nNested body\r\n## Sibling\r\nVisible\r\n"
        let parsed = MarkdownPresentation.parse(source)
        expect(parsed.headings.count == 4, "ATX headings include Unicode and CRLF lines")
        let parent = parsed.headings[1]
        expect(parent.level == 2 && parent.isFolded, "Persisted fold metadata is recognized")
        expect(slice(source, parent.contentRange) == "Parent", "Fold metadata is excluded from heading content")
        expect(slice(source, parent.prefixRange) == "## ", "Heading prefix has an exact source range")
        expect(slice(source, parent.foldMarkerRange!) == "<!-- {\"fold\":true} -->", "Fold metadata source is retained exactly")
        expect(slice(source, parent.bodyRange) == "Private body\r\n### Child\r\nNested body\r\n", "A folded section includes nested headings but stops at its sibling")
        expect(slice(source, parsed.headings[2].bodyRange) == "Nested body\r\n", "Nested heading body stops at a shallower heading")
        expect(NSMaxRange(parsed.headings[0].bodyRange) == (source as NSString).length, "Root heading extends through its descendants")
        expect(parsed.foldedBodyRanges == [parent.bodyRange], "Folded ranges are available to projection")
        let nested = MarkdownPresentation.parse("# A <!-- {\"fold\":true} -->\n## B <!-- {\"fold\":true} -->\nhidden\n# C\nend")
        expect(nested.headings[0].isFolded && nested.headings[1].isFolded, "Nested fold flags remain independent")
        expect(nested.foldedBodyRanges == [nested.headings[0].bodyRange], "Projection fold ranges coalesce nested bodies")
        let headings = MarkdownPresentation.parse("   ### With closing ###\n    # Indented code\n####### Too many\n#Missing space\n## <!-- {\"fold\":false} -->\n### End")
        expect(headings.headings.count == 3, "ATX syntax rejects indented and malformed headings")
        expect(headings.headings[0].contentRange.length == 12, "Closing hashes are excluded from heading content")
        expect(headings.headings[0].markerRanges.count == 2, "Opening and closing heading markers are reported")
        expect(!headings.headings[1].isFolded && headings.headings[1].contentRange.length == 0, "Explicitly unfolded empty headings remain valid")
        expect(headings.headings.last!.bodyRange.length == 0, "Final heading can have an empty body")

        let fenced = "Before\n```swift linenums\n# Literal\n| A | B |\n| --- | --- |\n```\n## Real\n~~~json\n{\"x\":1}\n~~~~\n```\nunclosed"
        let blocks = MarkdownPresentation.parse(fenced)
        expect(blocks.codeBlocks.count == 3, "Both fence types and unfinished blocks are parsed")
        expect(blocks.headings.count == 1 && blocks.tables.isEmpty, "Fenced heading and table examples remain literal")
        expect(slice(fenced, blocks.codeBlocks[0].languageRange!) == "swift", "Fence language range excludes other info text")
        expect(slice(fenced, blocks.codeBlocks[0].contentRange) == "# Literal\n| A | B |\n| --- | --- |\n", "Code content excludes both fences")
        expect(slice(fenced, blocks.codeBlocks[1].closingFenceRange!) == "~~~~\n", "Longer closing fences are retained as their own range")
        expect(blocks.codeBlocks[2].closingFenceRange == nil, "Unfinished fence has no synthesized closing marker")
        expect(slice(fenced, blocks.codeBlocks[2].contentRange) == "unclosed", "Unfinished code content extends to document end")

        let tableSource = "Tables 😊\n| Name | Count | Center |\n| :--- | ---: | :---: |\n| café | 2 | `x|y` |\n| escaped \\| pipe | 3 | z |\n\nAfter"
        let tables = MarkdownPresentation.parse(tableSource).tables
        expect(tables.count == 1, "A valid pipe table is parsed")
        let table = tables[0]
        expect(table.columnCount == 3 && table.rows.count == 3, "Delimiter row does not become visible cells")
        expect(table.alignments == [.left, .right, .center], "Column alignment follows delimiter markers")
        expect(table.rows[0].isHeader && !table.rows[1].isHeader, "Header row is identified")
        expect(slice(tableSource, table.rows[1].cells[2].contentRange) == "`x|y`", "Pipes inside inline code do not split cells")
        expect(slice(tableSource, table.rows[2].cells[0].contentRange) == "escaped \\| pipe", "Escaped pipes stay in their source cell")
        expect(table.rows[1].markerRanges.count == 4, "Only actual column pipes are reported as markers")
        expect(slice(tableSource, table.delimiterRange) == "| :--- | ---: | :---: |\n", "Delimiter source range includes its newline")
        expect(slice(tableSource, table.range).hasSuffix("| z |\n"), "Table stops before a blank paragraph")
        let bare = MarkdownPresentation.parse("A | B\n--- | ---\n1 | 2\n").tables
        expect(bare.count == 1 && bare[0].rows[1].cells.count == 2, "Outer pipes are optional")
        expect(bare[0].alignments == [.unspecified, .unspecified], "Columns without colons retain default alignment")
        let uneven = MarkdownPresentation.parse("| A | B |\n| --- | --- |\n| one |\n| two | three | four |\n").tables[0]
        expect(uneven.rows[1].cells.count == 2 && uneven.rows[1].cells[1].contentRange.length == 0, "Short rows receive an empty cell range")
        expect(uneven.rows[2].cells.count == 2, "Extra source cells are not presented as extra columns")
        expect(MarkdownPresentation.parse("A | B\n--- | --- | ---\n").tables.isEmpty, "Header and delimiter column counts must agree")
        let compactSource = "| Service | Monthly | Annual | Paid |\n| --------------------- | ----------: | ---------: | :-: |\n| Example | 12 | 144 | Yes |\n"
        let compact = MarkdownPresentation.parse(compactSource).tables
        expect(compact.count == 1, "Compact centered delimiters from existing Markdown notes render as tables")
        expect(compact[0].alignments == [.unspecified, .right, .right, .center], "Compact delimiters preserve per-column alignment")
        expect(slice(compactSource, compact[0].rows[1].cells[3].contentRange) == "Yes", "Compact delimiter parsing keeps editable source cell ranges")
        expect(MarkdownPresentation.parse("A | B\n- | --\n1 | 2\n").tables.count == 1, "A nonempty run of hyphens is sufficient for a compact delimiter cell")
        expect(MarkdownPresentation.parse("A | B\n: | ---\n").tables.isEmpty, "Table delimiters still require a hyphen in every column")
        expect(MarkdownPresentation.parse("text\n---\n").tables.isEmpty, "Setext-like text is not mistaken for a one-column table")
        expect(MarkdownPresentation.parse("| A |\n| --- |\n| B |\n").tables.first?.columnCount == 1, "Explicit one-column tables are valid")
        let multiCode = "| A | B |\n| --- | --- |\n| ``a`|b`` | c |\n"
        expect(MarkdownPresentation.parse(multiCode).tables[0].rows[1].cells.count == 2, "Matching multiple-backtick code spans protect inner pipes")
        let unmatched = "| A | B |\n| --- | --- |\n| `unfinished | value |\n"
        expect(slice(unmatched, MarkdownPresentation.parse(unmatched).tables[0].rows[1].cells[1].contentRange) == "value", "Unmatched backticks do not swallow column delimiters")
        let escaped = "| A | B |\n| --- | --- |\n| a\\\\| b |\n"
        expect(slice(escaped, MarkdownPresentation.parse(escaped).tables[0].rows[1].cells[0].contentRange) == "a\\\\", "An even backslash run does not escape a delimiter")
        let empty = MarkdownPresentation.parse("")
        expect(empty.headings.isEmpty && empty.tables.isEmpty && empty.codeBlocks.isEmpty, "Empty documents contain no presentation blocks")
        for documentSource in [source, fenced, tableSource, multiCode, unmatched] {
            let document = MarkdownPresentation.parse(documentSource)
            let length = (documentSource as NSString).length
            var ranges: [NSRange] = []
            for heading in document.headings { ranges += [heading.range, heading.contentRange, heading.bodyRange] + heading.markerRanges }
            for block in document.codeBlocks {
                ranges += [block.range, block.contentRange, block.openingFenceRange]
                ranges += [block.closingFenceRange, block.languageRange].compactMap { $0 }
            }
            for table in document.tables {
                ranges += [table.range, table.delimiterRange]
                for row in table.rows {
                    ranges += [row.range] + row.markerRanges
                    for cell in row.cells { ranges += [cell.range, cell.contentRange] }
                }
            }
            expect(ranges.allSatisfy { $0.location >= 0 && $0.length >= 0 && NSMaxRange($0) <= length }, "Every presentation range stays within UTF-16 source bounds")
        }
        var incremental = "# Root\nA plain 😊 paragraph\n## Child <!-- {\"fold\":true} -->\nHidden body\n## Next\n```swift\nlet value = 42\n```\n| A | B |\n| --- | --- |\n| 1 | 2 |\nFinal line\n"
        var incrementalDocument = MarkdownPresentation.parse(incremental)
        for (needle, replacement) in [("plain 😊", "longer 🦥 Unicode"), ("Hidden", "Private"), ("value", "result"), ("Final line", ""), ("paragraph", "x")] {
            let edit = (incremental as NSString).range(of: needle)
            guard let updated = incrementalDocument.updating(previous: incremental, range: edit, replacement: replacement) else {
                expect(false, "Ordinary paragraph and code-content edits use the incremental parser")
                continue
            }
            incremental = (incremental as NSString).replacingCharacters(in: edit, with: replacement)
            expect(updated == MarkdownPresentation.parse(incremental), "Incremental ranges exactly match a full parse after Unicode length changes")
            incrementalDocument = updated
        }
        let appended = "# Heading\n"
        let appendedDocument = MarkdownPresentation.parse(appended)
        let append = NSRange(location: (appended as NSString).length, length: 0)
        expect(appendedDocument.updating(previous: appended, range: append, replacement: "New body") == MarkdownPresentation.parse(appended + "New body"),
               "Insertion into an empty final heading body expands its range")
        let unclosed = "# Heading\n```swift\nlet value = 1"
        expect(MarkdownPresentation.parse(unclosed).updating(previous: unclosed, range: NSRange(location: (unclosed as NSString).length, length: 0), replacement: "0") == MarkdownPresentation.parse(unclosed + "0"),
               "Appending inside an unfinished fence extends content and block ranges")
        let stable = "# Heading\nPlain text\n| A | B |\n| --- | --- |\n| one | two |\n"
        let stableDocument = MarkdownPresentation.parse(stable)
        let plainEdit = (stable as NSString).range(of: "Plain")
        for insertion in ["\n", "\r\n", "#", "|", "`", "~", "<", ">", "-"] {
            expect(stableDocument.updating(previous: stable, range: plainEdit, replacement: insertion) == nil,
                   "Structural replacement requests a full parse")
        }
        expect(stableDocument.updating(previous: stable, range: (stable as NSString).range(of: "Heading"), replacement: "Title") == nil,
               "Heading edits use full parsing")
        expect(stableDocument.updating(previous: stable, range: (stable as NSString).range(of: "one"), replacement: "three") == nil,
               "Table edits use full parsing")
        let possibleHeading = "before\nx# Heading\n"
        expect(MarkdownPresentation.parse(possibleHeading).updating(previous: possibleHeading, range: (possibleHeading as NSString).range(of: "x"), replacement: "") == nil,
               "Removing plain text beside existing structure requests a full parse")
        expect(stableDocument.updating(previous: stable, range: NSRange(location: NSNotFound, length: 0), replacement: "x") == nil,
               "Invalid source ranges are rejected")
        print("Markdown presentation tests passed: \(assertions) assertions")
    }
}
