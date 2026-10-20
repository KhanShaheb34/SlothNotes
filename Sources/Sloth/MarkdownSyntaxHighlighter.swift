import AppKit

/// Lightweight lexical highlighting for fenced code. Ranges always refer to the
/// original UTF-16 source; no text, indentation or existing font is rewritten.
enum MarkdownSyntaxHighlighter {
    enum Kind: Equatable {
        case keyword, type, literal, number, string, comment, function, property
        case tag, attribute, `operator`, variable
    }
    struct Token: Equatable {
        let range: NSRange
        let kind: Kind
    }

    /// Unknown and absent language labels intentionally produce plain code.
    static func tokens(in source: String, language: String?) -> [Token] {
        guard let language = Language(label: language), !source.isEmpty else { return [] }
        return Lexer(source, language: language).scan()
    }

    static func attributes(for kind: Kind, dark: Bool) -> [NSAttributedString.Key: Any] {
        let hex: UInt32
        switch (kind, dark) {
        case (.keyword, false), (.literal, false), (.tag, false): hex = 0xA626A4
        case (.type, false), (.number, false), (.attribute, false): hex = 0x986801
        case (.string, false): hex = 0x407A24
        case (.comment, false): hex = 0x777F8C
        case (.function, false): hex = 0x245EAD
        case (.property, false): hex = 0x9A4A0B
        case (.operator, false): hex = 0x52657A
        case (.variable, false): hex = 0x9B3C4D
        case (.keyword, true), (.literal, true): hex = 0xC792EA
        case (.type, true), (.attribute, true): hex = 0xFFCB6B
        case (.number, true): hex = 0xF78C6C
        case (.string, true): hex = 0xC3E88D
        case (.comment, true): hex = 0x8A919E
        case (.function, true): hex = 0x82AAFF
        case (.property, true), (.tag, true), (.variable, true): hex = 0xF07178
        case (.operator, true): hex = 0x89DDFF
        }
        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                            green: CGFloat((hex >> 8) & 255) / 255,
                            blue: CGFloat(hex & 255) / 255, alpha: 1)
        return [.foregroundColor: color]
    }

    private enum Language: Hashable {
        case rust, swift, javascript, typescript, python, json, jsonc, shell, sql, css, html, yaml
        init?(label: String?) {
            guard let word = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace }).first?.lowercased() else { return nil }
            switch word {
            case "rust", "rs": self = .rust
            case "swift": self = .swift
            case "javascript", "js", "jsx", "node": self = .javascript
            case "typescript", "ts", "tsx": self = .typescript
            case "python", "py", "python3", "py3": self = .python
            case "json": self = .json
            case "jsonc": self = .jsonc
            case "shell", "sh", "bash", "zsh", "shellscript": self = .shell
            case "sql", "mysql", "postgresql", "postgres", "sqlite": self = .sql
            case "css": self = .css
            case "html", "htm", "xml", "svg": self = .html
            case "yaml", "yml": self = .yaml
            default: return nil
            }
        }
        var isJavaScript: Bool { self == .javascript || self == .typescript }
        var isJSON: Bool { self == .json || self == .jsonc }
    }

    private struct Rules {
        let keywords: Set<String>
        let types: Set<String>
        let literals: Set<String>
        let functions: Set<String>
        init(_ keywords: String, types: String = "", literals: String = "", functions: String = "") {
            func words(_ value: String) -> Set<String> { Set(value.split(separator: " ").map(String.init)) }
            self.keywords = words(keywords); self.types = words(types)
            self.literals = words(literals); self.functions = words(functions)
        }
    }
    private static let rules: [Language: Rules] = [
        .rust: Rules("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self static struct super trait type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try union",
            types: "Self bool char str String usize isize u8 u16 u32 u64 u128 i8 i16 i32 i64 i128 f32 f64 Vec Option Result", literals: "true false None Some Ok Err"),
        .swift: Rules("actor as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet",
            types: "Any AnyObject Self Bool Character String Substring Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Float Double Array Dictionary Set Optional Void Never", literals: "true false nil"),
        .javascript: Rules("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield",
            types: "Array Boolean Date Error Function Map Number Object Promise RegExp Set String Symbol WeakMap WeakSet", literals: "true false null undefined NaN Infinity"),
        .typescript: Rules("abstract as asserts async await break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let namespace new of private protected public readonly require return satisfies set static super switch this throw try type typeof unique var void while with yield",
            types: "any bigint boolean never number object string symbol unknown Array Boolean Date Error Function Map Number Object Promise RegExp Set String Symbol Readonly Record Partial Pick Omit", literals: "true false null undefined NaN Infinity"),
        .python: Rules("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
            types: "bool bytes bytearray complex dict float frozenset int list object range set str tuple type", literals: "True False None Ellipsis NotImplemented",
            functions: "print len open enumerate zip map filter sum min max sorted reversed isinstance issubclass super property staticmethod classmethod"),
        .json: Rules("", literals: "true false null"),
        .jsonc: Rules("", literals: "true false null"),
        .shell: Rules("if then else elif fi for while until do done case esac in function select time coproc local declare typeset export readonly unset return break continue",
            functions: "echo printf cd pwd read source test exec eval set shift trap alias unalias exit command builtin true false"),
        .sql: Rules("select from where join inner outer left right full cross on as and or not in exists between like ilike is distinct all union intersect except group by having order asc desc limit offset fetch with recursive insert into values update set delete create alter drop table index view database schema primary foreign key references constraint unique check default nulls first last returning case when then else end begin commit rollback transaction over partition rows range current row unbounded preceding following window cast collate grant revoke truncate explain analyze conflict nothing do using natural cascade if replace temporary temp materialized",
            types: "integer int smallint bigint decimal numeric real double float boolean text varchar char date time timestamp interval json jsonb uuid bytea", literals: "true false null",
            functions: "count sum avg min max coalesce concat lower upper length now round trim substring"),
        .css: Rules("important inherit initial unset revert none auto", types: "", literals: ""),
        .html: Rules(""),
        .yaml: Rules("", literals: "true false null True False Null TRUE FALSE NULL ~")
    ]

    private final class Lexer {
        let units: [UInt16]
        let language: Language
        let rules: Rules
        var result: [Token] = []
        var cursor = 0
        var expectsExpression = true
        var previousWord = ""

        init(_ source: String, language: Language) {
            units = Array(source.utf16); self.language = language
            rules = MarkdownSyntaxHighlighter.rules[language]!
        }
        var end: Int { units.count }
        func u(_ index: Int) -> UInt16 { index >= 0 && index < end ? units[index] : 0 }
        func text(_ start: Int, _ finish: Int) -> String { String(decoding: units[start..<finish], as: UTF16.self) }
        func matches(_ value: String, at start: Int) -> Bool {
            var index = start
            for character in value.utf16 {
                guard index < end, units[index] == character else { return false }
                index += 1
            }
            return true
        }
        func emit(_ kind: Kind, from start: Int, to finish: Int) {
            guard finish > start else { return }
            result.append(Token(range: NSRange(location: start, length: finish - start), kind: kind))
        }
        func newline(_ character: UInt16) -> Bool { [10, 13, 0x2028, 0x2029].contains(character) }
        func whitespace(_ character: UInt16) -> Bool { character == 32 || character == 9 || newline(character) }
        func digit(_ character: UInt16) -> Bool { character >= 48 && character <= 57 }
        func letter(_ character: UInt16) -> Bool { (65...90).contains(character) || (97...122).contains(character) }
        func identifierStart(_ character: UInt16) -> Bool {
            letter(character) || character == 95 || character >= 128 || (language.isJavaScript && character == 36)
        }
        func identifierPart(_ character: UInt16) -> Bool {
            identifierStart(character) || digit(character) || ((language == .css || language == .yaml) && character == 45)
        }
        func nextNonspace(_ start: Int) -> Int {
            var index = start
            while index < end && whitespace(u(index)) { index += 1 }
            return index
        }
        func lineEnd(_ start: Int) -> Int {
            var index = start
            while index < end && !newline(u(index)) { index += 1 }
            return index
        }

        func scan() -> [Token] {
            if language == .html { scanHTML(); return result }
            while cursor < end {
                let start = cursor, character = u(cursor)
                if whitespace(character) { cursor += 1; continue }
                if let stop = commentEnd(at: start) { emit(.comment, from: start, to: stop); cursor = stop; continue }
                if language == .shell, matches("<<", at: start), !matches("<<<", at: start), let stop = heredocEnd(at: start) {
                    emit(.string, from: start, to: stop); cursor = stop; expectsExpression = false; continue
                }
                if language == .yaml, (character == 124 || character == 62), let stop = yamlBlockEnd(at: start) {
                    emit(.string, from: start, to: stop); cursor = stop; continue
                }
                if let stop = stringEnd(at: start) {
                    let kind: Kind = language.isJSON && u(nextNonspace(stop)) == 58 ? .property : .string
                    emit(kind, from: start, to: stop); cursor = stop; expectsExpression = false; continue
                }
                if language == .rust && character == 39 && identifierStart(u(start + 1)) {
                    cursor += 2
                    while identifierPart(u(cursor)) { cursor += 1 }
                    emit(.type, from: start, to: cursor); continue
                }
                if language.isJavaScript && character == 47 && expectsExpression, let stop = regexEnd(at: start) {
                    emit(.string, from: start, to: stop); cursor = stop; expectsExpression = false; continue
                }
                if language == .shell && character == 36 {
                    cursor = variableEnd(at: start); emit(.variable, from: start, to: cursor); continue
                }
                if language == .yaml && (character == 38 || character == 42) && identifierStart(u(start + 1)) {
                    cursor += 2
                    while identifierPart(u(cursor)) { cursor += 1 }
                    emit(.variable, from: start, to: cursor); continue
                }
                if character == 64 && [.swift, .python, .css].contains(language) {
                    cursor += 1
                    while identifierPart(u(cursor)) || u(cursor) == 46 { cursor += 1 }
                    emit(.attribute, from: start, to: cursor); continue
                }
                if language == .css && character == 35 && isHex(u(start + 1)) {
                    cursor += 1
                    while isHex(u(cursor)) { cursor += 1 }
                    emit(.number, from: start, to: cursor); continue
                }
                if digit(character) || (character == 46 && digit(u(start + 1))) {
                    cursor = numberEnd(at: start); emit(.number, from: start, to: cursor); expectsExpression = false; continue
                }
                if identifierStart(character) {
                    cursor += 1
                    while identifierPart(u(cursor)) { cursor += 1 }
                    // A Rust raw identifier is one name, not the keyword after r#.
                    if language == .rust && text(start, cursor) == "r" && u(cursor) == 35 && identifierStart(u(cursor + 1)) {
                        cursor += 2
                        while identifierPart(u(cursor)) { cursor += 1 }
                        previousWord = ""; expectsExpression = false; continue
                    }
                    let word = text(start, cursor)
                    let lookup = language == .sql ? word.lowercased() : word
                    let following = u(nextNonspace(cursor))
                    if [.css, .yaml].contains(language) && following == 58 { emit(.property, from: start, to: cursor) }
                    else if rules.literals.contains(lookup) { emit(.literal, from: start, to: cursor) }
                    else if rules.keywords.contains(lookup) { emit(.keyword, from: start, to: cursor) }
                    else if rules.types.contains(lookup) { emit(.type, from: start, to: cursor) }
                    else if ["fn", "func", "function", "def"].contains(previousWord) || following == 40 || rules.functions.contains(lookup) {
                        emit(.function, from: start, to: cursor)
                    } else if ["class", "struct", "enum", "interface", "trait", "protocol", "typealias"].contains(previousWord) ||
                                ([.rust, .swift, .javascript, .typescript, .python].contains(language) && (65...90).contains(character)) {
                        emit(.type, from: start, to: cursor)
                    } else if language == .css && u(start - 1) == 46 { emit(.tag, from: start, to: cursor) }
                    else if u(start - 1) == 46 && ![.yaml, .sql].contains(language) { emit(.property, from: start, to: cursor) }
                    else if language == .rust && following == 33 { emit(.function, from: start, to: cursor) }
                    previousWord = lookup
                    expectsExpression = ["return", "throw", "case", "yield", "await", "typeof", "void", "delete", "new", "in", "of"].contains(lookup)
                    continue
                }
                if operatorCharacter(character) {
                    cursor += 1
                    // A following slash may begin a comment/regex and must be
                    // examined with its own lexical state on the next iteration.
                    while operatorCharacter(u(cursor)) && u(cursor) != 47 && u(cursor) != 35 && u(cursor) != 64 { cursor += 1 }
                    emit(.operator, from: start, to: cursor); expectsExpression = true; continue
                }
                expectsExpression = ![41, 93, 125].contains(character)
                cursor += 1
            }
            return result
        }

        func operatorCharacter(_ character: UInt16) -> Bool {
            [43, 45, 42, 47, 61, 33, 60, 62, 124, 38, 37, 94, 126, 63, 58, 46, 35].contains(character)
        }
        func commentEnd(at start: Int) -> Int? {
            let slashComments = [.rust, .swift, .javascript, .typescript, .jsonc].contains(language)
            if slashComments && matches("//", at: start) { return lineEnd(start) }
            if language == .sql && matches("--", at: start) { return lineEnd(start) }
            if [.python, .shell, .yaml].contains(language), u(start) == 35 {
                let boundary = start == 0 || whitespace(u(start - 1)) || [59, 40, 41, 124, 38].contains(u(start - 1))
                if language == .python || boundary { return lineEnd(start) }
            }
            if (slashComments || language == .sql || language == .css) && matches("/*", at: start) {
                let nested = [.rust, .swift, .sql].contains(language)
                var depth = 1, index = start + 2
                while index < end {
                    if matches("*/", at: index) { depth -= 1; index += 2; if depth == 0 { return index } }
                    else if nested && matches("/*", at: index) { depth += 1; index += 2 }
                    else { index += 1 }
                }
                return end
            }
            return nil
        }

        func stringEnd(at start: Int) -> Int? {
            var quote = start, hashes = 0, rustRaw = false
            if language == .rust {
                if u(quote) == 98 && (u(quote + 1) == 114 || u(quote + 1) == 34 || u(quote + 1) == 39) { quote += 1 }
                if u(quote) == 114 {
                    quote += 1
                    while u(quote) == 35 { hashes += 1; quote += 1 }
                    guard u(quote) == 34 else { return nil }
                    rustRaw = true
                }
                if u(quote) == 39 { return rustCharacterEnd(at: quote) }
                guard u(quote) == 34 else { return nil }
            } else if language == .swift {
                // An invalid run of hashes is scanned only once, not again
                // from every character in a long unfinished raw-string marker.
                if u(start) == 35 && u(start - 1) == 35 { return nil }
                while u(quote) == 35 { hashes += 1; quote += 1 }
                guard u(quote) == 34 else { return nil }
            } else if language == .python {
                if ![34, 39].contains(u(quote)) {
                    var prefixEnd = quote
                    while prefixEnd < min(end, start + 2) && letter(u(prefixEnd)) { prefixEnd += 1 }
                    let prefix = text(start, prefixEnd).lowercased()
                    guard ["r", "u", "b", "f", "br", "rb", "fr", "rf"].contains(prefix), [34, 39].contains(u(prefixEnd)) else { return nil }
                    quote = prefixEnd
                }
            } else {
                if language == .sql && u(start) == 36 { return sqlDollarQuoteEnd(at: start) }
                let allowed: [UInt16] = language.isJSON ? [34] : (language == .shell || language.isJavaScript || language == .sql ? [34, 39, 96] : [34, 39])
                guard allowed.contains(u(quote)) else { return nil }
            }
            let character = u(quote)
            let triple = [.swift, .python].contains(language) && u(quote + 1) == character && u(quote + 2) == character
            let count = triple ? 3 : 1
            let multiline = triple || rustRaw || [.rust, .shell, .sql, .yaml].contains(language) || (language.isJavaScript && character == 96)
            let doubled = language == .sql || (language == .yaml && character == 39)
            let escapes = !rustRaw && !(language == .shell && character == 39) && !doubled
            let delimiter = Array(repeating: character, count: count) + Array(repeating: UInt16(35), count: hashes)
            return quotedEnd(from: quote + count, delimiter: delimiter, escapes: escapes, escapeHashes: hashes,
                             multiline: multiline, doubled: doubled)
        }
        func quotedEnd(from start: Int, delimiter: [UInt16], escapes: Bool, escapeHashes: Int = 0,
                       multiline: Bool, doubled: Bool = false) -> Int {
            var index = start
            while index < end {
                if !multiline && newline(u(index)) { return index }
                if escapes && u(index) == 92 {
                    var afterEscape = index + 1
                    while afterEscape < index + 1 + escapeHashes && u(afterEscape) == 35 { afterEscape += 1 }
                    if afterEscape == index + 1 + escapeHashes {
                        index = min(end, afterEscape + (u(afterEscape) == 13 && u(afterEscape + 1) == 10 ? 2 : 1))
                        continue
                    }
                }
                if index + delimiter.count <= end && units[index..<(index + delimiter.count)].elementsEqual(delimiter) {
                    if doubled && u(index + 1) == delimiter[0] { index += 2; continue }
                    return index + delimiter.count
                }
                index += 1
            }
            return end
        }
        func sqlDollarQuoteEnd(at start: Int) -> Int? {
            var index = start + 1
            while letter(u(index)) || digit(u(index)) || u(index) == 95 { index += 1 }
            guard u(index) == 36 else { return nil }
            let delimiter = text(start, index + 1)
            index += 1
            while index < end && !matches(delimiter, at: index) { index += 1 }
            return min(end, index + delimiter.utf16.count)
        }
        func afterLineBreak(_ start: Int) -> Int {
            guard newline(u(start)) else { return start }
            return start + (u(start) == 13 && u(start + 1) == 10 ? 2 : 1)
        }
        func rustCharacterEnd(at quote: Int) -> Int? {
            var index = quote + 1
            if u(index) == 92 {
                index += 1
                if u(index) == 117 && u(index + 1) == 123 {
                    index += 2
                    while index < end && u(index) != 125 && !newline(u(index)) { index += 1 }
                    guard u(index) == 125 else { return nil }; index += 1
                } else if u(index) == 120 { index += 3 }
                else { index += 1 }
            } else {
                guard index < end && !newline(u(index)) else { return nil }
                index += (0xD800...0xDBFF).contains(u(index)) && (0xDC00...0xDFFF).contains(u(index + 1)) ? 2 : 1
            }
            return u(index) == 39 ? index + 1 : nil
        }
        func regexEnd(at start: Int) -> Int? {
            var index = start + 1, inClass = false
            while index < end && !newline(u(index)) {
                if u(index) == 92 { index += 2; continue }
                if u(index) == 91 { inClass = true }
                else if u(index) == 93 { inClass = false }
                else if u(index) == 47 && !inClass {
                    index += 1
                    while letter(u(index)) { index += 1 }
                    return index
                }
                index += 1
            }
            return nil
        }
        func variableEnd(at start: Int) -> Int {
            var index = start + 1
            if u(index) == 123 {
                index += 1
                while index < end && u(index) != 125 && !newline(u(index)) {
                    if u(index) == 92 { index += 1 }; index += 1
                }
                return min(end, index + (u(index) == 125 ? 1 : 0))
            }
            if identifierStart(u(index)) || digit(u(index)) {
                repeat { index += 1 } while identifierPart(u(index))
                return index
            }
            return min(end, index + ([63, 36, 64, 35, 33, 42, 45].contains(u(index)) ? 1 : 0))
        }
        func isHex(_ character: UInt16) -> Bool { digit(character) || (65...70).contains(character) || (97...102).contains(character) }
        func numberEnd(at start: Int) -> Int {
            var index = start
            let hexadecimal = u(index) == 48 && [88, 120].contains(u(index + 1))
            let based = u(index) == 48 && [66, 98, 79, 111].contains(u(index + 1))
            if hexadecimal || based { index += 2 }
            while digit(u(index)) || u(index) == 95 || (hexadecimal && isHex(u(index))) { index += 1 }
            if u(index) == 46 && (digit(u(index + 1)) || (hexadecimal && isHex(u(index + 1)))) {
                index += 1
                while digit(u(index)) || u(index) == 95 || (hexadecimal && isHex(u(index))) { index += 1 }
            }
            if (!hexadecimal && [69, 101].contains(u(index))) || (hexadecimal && [80, 112].contains(u(index))) {
                var exponent = index + 1
                if [43, 45].contains(u(exponent)) { exponent += 1 }
                if digit(u(exponent)) {
                    index = exponent + 1
                    while digit(u(index)) || u(index) == 95 { index += 1 }
                }
            }
            var suffixEnd = index
            while letter(u(suffixEnd)) || digit(u(suffixEnd)) { suffixEnd += 1 }
            let suffix = text(index, suffixEnd)
            if language == .rust && ["u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64"].contains(suffix) { index = suffixEnd }
            else if language.isJavaScript && suffix == "n" { index = suffixEnd }
            else if language == .css {
                if ["px", "em", "rem", "vh", "vw", "vmin", "vmax", "ch", "ex", "cm", "mm", "in", "pt", "pc", "s", "ms", "deg", "rad", "turn", "fr"].contains(suffix.lowercased()) { index = suffixEnd }
                if u(index) == 37 { index += 1 }
            }
            return max(start + 1, index)
        }

        func heredocEnd(at start: Int) -> Int? {
            var index = start + 2
            let stripTabs = u(index) == 45
            if stripTabs { index += 1 }
            while [32, 9].contains(u(index)) { index += 1 }
            let quote = [34, 39].contains(u(index)) ? u(index) : 0
            if quote != 0 { index += 1 }
            let labelStart = index
            while letter(u(index)) || digit(u(index)) || u(index) == 95 { index += 1 }
            guard index > labelStart else { return nil }
            let delimiter = text(labelStart, index)
            if quote != 0 { guard u(index) == quote else { return nil }; index += 1 }
            let declarationEnd = lineEnd(index)
            // Handle the common standalone heredoc declaration; commands after
            // its marker require a shell parser and retain ordinary highlighting.
            guard text(index, declarationEnd).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            index = declarationEnd
            while index < end {
                index = afterLineBreak(index)
                let stop = lineEnd(index)
                var candidate = index
                if stripTabs { while u(candidate) == 9 { candidate += 1 } }
                if text(candidate, stop) == delimiter { return stop }
                if stop == index && stop == end { break }
                index = stop
            }
            return end
        }
        func yamlBlockEnd(at start: Int) -> Int? {
            var declarationEnd = start + 1
            while [43, 45].contains(u(declarationEnd)) || digit(u(declarationEnd)) { declarationEnd += 1 }
            while [32, 9].contains(u(declarationEnd)) { declarationEnd += 1 }
            guard declarationEnd == end || newline(u(declarationEnd)) || u(declarationEnd) == 35 else { return nil }
            var lineStart = start
            while lineStart > 0 && !newline(u(lineStart - 1)) { lineStart -= 1 }
            var indentation = lineStart
            while u(indentation) == 32 { indentation += 1 }
            let required = indentation - lineStart
            var index = lineEnd(declarationEnd)
            while index < end {
                index = afterLineBreak(index)
                let nextLine = index, stop = lineEnd(index)
                while u(index) == 32 { index += 1 }
                if index < stop && index - nextLine <= required { return nextLine }
                if stop == end { return end }
                index = stop
            }
            return end
        }

        func scanHTML() {
            while cursor < end {
                let start = cursor
                if matches("<!--", at: start) {
                    cursor += 4
                    while cursor < end && !matches("-->", at: cursor) { cursor += 1 }
                    cursor = min(end, cursor + 3); emit(.comment, from: start, to: cursor); continue
                }
                if u(start) == 38 {
                    var stop = start + 1
                    while stop < end && stop - start < 32 && (letter(u(stop)) || digit(u(stop)) || u(stop) == 35) { stop += 1 }
                    if u(stop) == 59 { cursor = stop + 1; emit(.literal, from: start, to: cursor); continue }
                }
                guard u(start) == 60 else { cursor += 1; continue }
                var nameStart = start + 1
                if [47, 33, 63].contains(u(nameStart)) { nameStart += 1 }
                guard letter(u(nameStart)) else { cursor += 1; continue }
                var nameEnd = nameStart + 1
                while letter(u(nameEnd)) || digit(u(nameEnd)) || [45, 58].contains(u(nameEnd)) { nameEnd += 1 }
                let name = text(nameStart, nameEnd).lowercased(), closing = u(start + 1) == 47
                emit(.tag, from: start, to: nameEnd); cursor = nameEnd
                var selfClosing = false, expectingValue = false
                while cursor < end {
                    if whitespace(u(cursor)) { cursor += 1; continue }
                    if u(cursor) == 62 || matches("/>", at: cursor) || matches("?>", at: cursor) {
                        selfClosing = u(cursor) == 47
                        let stop = cursor + (u(cursor) == 62 ? 1 : 2)
                        emit(.tag, from: cursor, to: stop); cursor = stop; break
                    }
                    if [34, 39].contains(u(cursor)) {
                        let stop = quotedEnd(from: cursor + 1, delimiter: [u(cursor)], escapes: false, multiline: true)
                        emit(.string, from: cursor, to: stop); cursor = stop; expectingValue = false; continue
                    }
                    if u(cursor) == 61 { emit(.operator, from: cursor, to: cursor + 1); cursor += 1; expectingValue = true; continue }
                    if expectingValue {
                        let value = cursor
                        while cursor < end && !whitespace(u(cursor)) && u(cursor) != 62 && !matches("/>", at: cursor) { cursor += 1 }
                        emit(.string, from: value, to: cursor); expectingValue = false; continue
                    }
                    let attribute = cursor
                    while cursor < end && !whitespace(u(cursor)) && ![61, 62, 47, 34, 39].contains(u(cursor)) { cursor += 1 }
                    if cursor > attribute { emit(.attribute, from: attribute, to: cursor) }
                    else { cursor += 1 }
                }
                if !closing && !selfClosing && ["script", "style"].contains(name), cursor < end {
                    let bodyStart = cursor, closingMarker = "</" + name
                    while cursor < end && !matchesIgnoringCase(closingMarker, at: cursor) { cursor += 1 }
                    let nested = Lexer(text(bodyStart, cursor), language: name == "script" ? .javascript : .css).scan()
                    result.append(contentsOf: nested.map { Token(range: NSRange(location: bodyStart + $0.range.location, length: $0.range.length), kind: $0.kind) })
                }
            }
        }
        func matchesIgnoringCase(_ value: String, at start: Int) -> Bool {
            var index = start
            for expected in value.utf16 {
                let actual = u(index)
                guard index < end, (65...90).contains(actual) ? actual + 32 == expected : actual == expected else { return false }
                index += 1
            }
            return true
        }
    }
}
