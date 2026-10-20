import Foundation

/// Shared tag syntax for note indexing, search and editor highlighting.
/// Numeric references remain ordinary Markdown text; named paths can still use
/// numeric components, such as project/123 or 2026/notes.
enum MarkdownTagSyntax {
    struct Match: Equatable {
        /// The complete hashtag, including an optional closing #, in UTF-16.
        let range: NSRange
        let name: String
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/])#(?:([^\s#](?:[^#\r\n]*?[^\s#])?)#(?![\p{L}\p{M}\p{N}_])|([\p{L}\p{N}][\p{L}\p{M}\p{N}_-]*(?:/[\p{L}\p{N}][\p{L}\p{M}\p{N}_-]*)*))"#)

    /// Returns every valid occurrence in source order. Callers exclude literal
    /// code ranges and deduplicate names when building a note's tag index.
    static func matches(in source: String) -> [Match] {
        let utf16 = source as NSString
        return tagRegex.matches(in: source, range: NSRange(location: 0, length: utf16.length)).compactMap { match in
            // Odd backslash runs escape a literal #. Even runs escape each
            // other and leave the following hashtag active.
            var preceding = match.range.location
            var backslashes = 0
            while preceding > 0, utf16.character(at: preceding - 1) == 92 {
                backslashes += 1
                preceding -= 1
            }
            guard backslashes.isMultiple(of: 2) else { return nil }
            let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let range = Range(capture, in: source) else { return nil }
            let name = String(source[range])
            guard isIndexableTag(name) else { return nil }
            return Match(range: match.range, name: name)
        }
    }

    static func isIndexableTag(_ name: String) -> Bool {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else { return false }
        // Character.isNumber covers Unicode decimal digits, letter numbers and
        // other numeric characters, rather than accepting only ASCII 0...9.
        return !components.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
