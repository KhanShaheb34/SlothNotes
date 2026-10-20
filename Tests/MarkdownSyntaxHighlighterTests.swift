import AppKit

@main
enum MarkdownSyntaxHighlighterTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func token(_ value: String, kind: MarkdownSyntaxHighlighter.Kind,
                      in source: String, language: String) -> Bool {
        let range = (source as NSString).range(of: value)
        return range.location != NSNotFound && MarkdownSyntaxHighlighter.tokens(in: source, language: language).contains {
            $0.range == range && $0.kind == kind
        }
    }
    static func validRanges(_ source: String, language: String) {
        let length = (source as NSString).length
        var previousEnd = 0
        for token in MarkdownSyntaxHighlighter.tokens(in: source, language: language) {
            expect(token.range.location >= previousEnd && token.range.length > 0 && NSMaxRange(token.range) <= length,
                   "\(language) tokens are ordered, non-overlapping UTF-16 ranges")
            previousEnd = NSMaxRange(token.range)
        }
    }
    static func opaque(_ value: String, kind: MarkdownSyntaxHighlighter.Kind,
                       in source: String, language: String) {
        let range = (source as NSString).range(of: value)
        let touching = MarkdownSyntaxHighlighter.tokens(in: source, language: language).filter {
            NSIntersectionRange($0.range, range).length > 0
        }
        expect(touching.count == 1 && touching.first?.range == range && touching.first?.kind == kind,
               "\(language) keeps \(kind) contents opaque to other token rules")
    }

    static func main() {
        let rust = #"""
// fn fake() and "not a string"
use std::collections::HashMap;
pub fn greet<'a>(name: &'a str) -> String {
    let café = "বাংলা 🦥 fn 42";
    let raw = r##"quote "# and fn // not comment"##;
    let bytes = br#"fn bytes"#;
    /* outer let /* nested fn */ still comment */
    let n: u32 = 0xff_u32;
    println!("{name}");
    'label: loop { break 'label; }
    let character = '🦥';
}
"""#
        expect(token("pub", kind: .keyword, in: rust, language: "rust"), "Rust declarations receive keyword highlighting")
        expect(token("HashMap", kind: .type, in: rust, language: "rs"), "Rust type names use the type category")
        expect(token("greet", kind: .function, in: rust, language: "Rust"), "Rust functions receive function highlighting")
        expect(token("'a", kind: .type, in: rust, language: "rust"), "Rust lifetimes do not consume following source as strings")
        expect(token("0xff_u32", kind: .number, in: rust, language: "rust"), "Rust hexadecimal values retain numeric suffixes")
        opaque(#""বাংলা 🦥 fn 42""#, kind: .string, in: rust, language: "rust")
        opaque(###"r##"quote "# and fn // not comment"##"###, kind: .string, in: rust, language: "rust")
        opaque(##"br#"fn bytes"#"##, kind: .string, in: rust, language: "rust")
        opaque("/* outer let /* nested fn */ still comment */", kind: .comment, in: rust, language: "rust")
        opaque("'🦥'", kind: .string, in: rust, language: "rust")
        expect(token("loop", kind: .keyword, in: rust, language: "rust"), "Rust labels do not swallow subsequent keywords")
        validRanges(rust, language: "rust")

        let swift = ##"""
@MainActor
struct Message {
    let text = #"raw \" let // text"#
    let long = """
    বাংলা 🦥 "quoted" and func
    """
    /* outer /* nested */ remainder */
    func printMessage() -> String { return text }
}
"""##
        expect(token("@MainActor", kind: .attribute, in: swift, language: "swift"), "Swift attributes are recognized")
        expect(token("struct", kind: .keyword, in: swift, language: "swift"), "Swift declarations receive keyword highlighting")
        expect(token("printMessage", kind: .function, in: swift, language: "swift"), "Swift function names are highlighted")
        opaque(##"#"raw \" let // text"#"##, kind: .string, in: swift, language: "swift")
        opaque("/* outer /* nested */ remainder */", kind: .comment, in: swift, language: "swift")
        validRanges(swift, language: "swift")

        let javascript = #"""
const text = `template ${value} // const "quoted"`;
const expression = /https?:\/\/[a-z]+/gi;
const ratio = total / count;
function greet(name) { return "if // return"; }
// const ignored = 1
"""#
        expect(token("const", kind: .keyword, in: javascript, language: "js"), "JavaScript aliases resolve")
        opaque("`template ${value} // const \"quoted\"`", kind: .string, in: javascript, language: "javascript")
        opaque(#"/https?:\/\/[a-z]+/gi"#, kind: .string, in: javascript, language: "javascript")
        opaque(#""if // return""#, kind: .string, in: javascript, language: "javascript")
        expect(token("greet", kind: .function, in: javascript, language: "javascript"), "Division does not swallow later functions as a regex")
        validRanges(javascript, language: "javascript")
        let typescript = "interface Entry { readonly name: string; count?: number }\nconst value: Entry | null = null;"
        expect(token("interface", kind: .keyword, in: typescript, language: "ts"), "TypeScript declarations are supported")
        expect(token("string", kind: .type, in: typescript, language: "typescript"), "TypeScript primitive types are distinguished")

        let python = ##"""
@dataclass
class Greeting:
    raw = r"""# not comment
    def not_code(): pass 🦥
    """
    def message(self):
        return f"Hello {self.name}: if # text"
"""##
        expect(token("@dataclass", kind: .attribute, in: python, language: "py"), "Python decorators are recognized")
        expect(token("message", kind: .function, in: python, language: "python"), "Python functions after multiline strings remain highlighted")
        expect(token("return", kind: .keyword, in: python, language: "python"), "Python statements are highlighted")
        opaque(#"f"Hello {self.name}: if # text""#, kind: .string, in: python, language: "python")
        validRanges(python, language: "python")

        let json = #"{"enabled": true, "amount": 12.5e-3, "text": "false // hi 🦥"}"#
        expect(token(#""enabled""#, kind: .property, in: json, language: "json"), "JSON object keys are distinguished from values")
        expect(token("true", kind: .literal, in: json, language: "json"), "JSON booleans receive literal highlighting")
        expect(token("12.5e-3", kind: .number, in: json, language: "json"), "Exponents remain one numeric token")
        opaque(#""false // hi 🦥""#, kind: .string, in: json, language: "json")
        expect(!MarkdownSyntaxHighlighter.tokens(in: "// ordinary JSON text", language: "json").contains { $0.kind == .comment },
               "Strict JSON does not invent comment syntax")
        expect(MarkdownSyntaxHighlighter.tokens(in: "// JSONC comment", language: "jsonc").first?.kind == .comment,
               "JSONC explicitly supports comments")
        validRanges(json, language: "json")

        let shell = "#!/bin/sh\nif test -n \"$HOME # string\"; then\n  printf '%s' $HOME\nfi\ncat <<'END'\nif # literal 🦥\nEND\necho done\n"
        expect(token("if", kind: .keyword, in: shell, language: "bash"), "Shell control flow is highlighted")
        opaque("\"$HOME # string\"", kind: .string, in: shell, language: "shell")
        expect(MarkdownSyntaxHighlighter.tokens(in: shell, language: "sh").contains {
            $0.kind == .variable && (shell as NSString).substring(with: $0.range) == "$HOME"
        }, "Shell variables outside quotes are recognized")
        let heredoc = "<<'END'\nif # literal 🦥\nEND"
        opaque(heredoc, kind: .string, in: shell, language: "zsh")
        expect(token("echo", kind: .function, in: shell, language: "shell"), "Shell resumes highlighting after a heredoc")
        validRanges(shell, language: "shell")

        let sql = "SELECT name FROM users WHERE active = TRUE AND label = 'it''s SELECT -- text';\n-- SELECT ignored\n"
        expect(token("SELECT", kind: .keyword, in: sql, language: "sql"), "SQL keywords ignore case")
        expect(token("TRUE", kind: .literal, in: sql, language: "postgresql"), "SQL booleans are recognized")
        opaque("'it''s SELECT -- text'", kind: .string, in: sql, language: "sql")
        validRanges(sql, language: "sql")

        let css = ".card { color: #d65a52; padding: 12px; content: \"if /* text */\"; }\n/* comment */"
        expect(token("color", kind: .property, in: css, language: "css"), "CSS property names are highlighted")
        expect(token("#d65a52", kind: .number, in: css, language: "css"), "CSS hex colors are recognized")
        expect(token("12px", kind: .number, in: css, language: "css"), "CSS values retain their units")
        opaque("\"if /* text */\"", kind: .string, in: css, language: "css")
        validRanges(css, language: "css")

        let html = "<div class=\"card\" data-label='if > text'>বাংলা 🦥 &amp;</div><!-- <b>comment</b> --><script>const n = 1;</script>"
        expect(token("class", kind: .attribute, in: html, language: "html"), "HTML attributes are distinguished from text")
        opaque("'if > text'", kind: .string, in: html, language: "html")
        opaque("<!-- <b>comment</b> -->", kind: .comment, in: html, language: "html")
        expect(token("const", kind: .keyword, in: html, language: "html"), "HTML script bodies use the JavaScript lexer")
        validRanges(html, language: "html")

        let yaml = "name: Sloth\nenabled: true\nmessage: |\n  # literal comment\n  if 🦥 text\nnext: &default 42\ncopy: *default\n"
        expect(token("name", kind: .property, in: yaml, language: "yml"), "YAML mapping keys receive property highlighting")
        opaque("|\n  # literal comment\n  if 🦥 text\n", kind: .string, in: yaml, language: "yaml")
        expect(token("next", kind: .property, in: yaml, language: "yaml"), "YAML resumes at a dedented mapping after block scalars")
        expect(token("&default", kind: .variable, in: yaml, language: "yaml"), "YAML anchors are recognized")
        validRanges(yaml, language: "yaml")

        expect(MarkdownSyntaxHighlighter.tokens(in: "let value = 42", language: "unknown-language").isEmpty,
               "Unknown languages retain the plain code fallback")
        expect(MarkdownSyntaxHighlighter.tokens(in: "let value = 42", language: nil).isEmpty,
               "Unlabelled code does not guess a language")
        expect(MarkdownSyntaxHighlighter.tokens(in: "", language: "rust").isEmpty, "Empty code is supported")
        let unterminated = "let text = r###\"unfinished fn // text"
        expect(MarkdownSyntaxHighlighter.tokens(in: unterminated, language: "rust").last?.kind == .string,
               "An unfinished raw string stays opaque to its end")
        let sqlRaw = "$body$BEGIN SELECT 'text'; -- still text\nEND$body$; SELECT 1"
        opaque("$body$BEGIN SELECT 'text'; -- still text\nEND$body$", kind: .string, in: sqlRaw, language: "postgresql")
        expect(token("card", kind: .string, in: "<div class=card>", language: "html"),
               "Unquoted HTML attribute values are recognized as values")
        let unicodeLines = "message: |\u{2028}  # opaque 🦥\u{2028}next: true"
        expect(token("next", kind: .property, in: unicodeLines, language: "yaml"),
               "Unicode line separators terminate YAML block strings without stalling")
        let unicodeHeredoc = "cat <<END\u{2028}if # literal\u{2028}END\u{2028}echo done"
        expect(token("echo", kind: .function, in: unicodeHeredoc, language: "shell"),
               "Unicode line separators terminate shell heredocs without stalling")
        expect(token("fn", kind: .keyword, in: "fn main() {}", language: "  RUST linenos  "),
               "Fence info suffixes and surrounding whitespace do not change language detection")
        let unfinishedHashes = String(repeating: "#", count: 16_384)
        let hashTokens = MarkdownSyntaxHighlighter.tokens(in: unfinishedHashes, language: "swift")
        expect(hashTokens.count == unfinishedHashes.utf16.count, "An unfinished raw-string prefix completes a bounded lexical pass")
        let colored = MarkdownSyntaxHighlighter.attributes(for: .keyword, dark: false)
        let darkColored = MarkdownSyntaxHighlighter.attributes(for: .keyword, dark: true)
        expect(colored[.foregroundColor] is NSColor && darkColored[.foregroundColor] is NSColor,
               "Both themes provide native syntax colors")
        expect(colored[.font] == nil && darkColored[.font] == nil,
               "Syntax colors preserve the editor's existing monospace font and layout")
        print("Syntax highlighter tests passed: \(assertions) assertions")
    }
}
