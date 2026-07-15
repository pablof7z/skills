import AppKit

enum SyntaxHighlighter {
    private static let keywordColor = NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.92, alpha: 1.0)
    private static let stringColor = NSColor(calibratedRed: 0.36, green: 0.64, blue: 0.38, alpha: 1.0)
    private static let numberColor = NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.32, alpha: 1.0)
    private static let commentColor = NSColor.labelColor.withAlphaComponent(0.45)
    private static let plainColor = NSColor.labelColor.withAlphaComponent(0.82)
    private static let jsonKeyColor = NSColor(calibratedRed: 0.40, green: 0.58, blue: 0.82, alpha: 1.0)

    private static let keywords: [String: Set<String>] = [
        "ts": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "await", "async", "new", "class", "extends", "import", "export", "from", "default", "try", "catch", "finally", "throw", "typeof", "instanceof", "this", "super", "null", "undefined", "true", "false", "void", "yield", "delete", "in", "of", "as", "type", "interface", "enum", "public", "private", "protected", "readonly", "static", "get", "set", "namespace"],
        "js": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "await", "async", "new", "class", "extends", "import", "export", "from", "default", "try", "catch", "finally", "throw", "typeof", "instanceof", "this", "super", "null", "undefined", "true", "false", "void", "yield", "delete", "in", "of"],
        "swift": ["let", "var", "func", "return", "if", "else", "for", "while", "guard", "defer", "switch", "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "throws", "rethrows", "try", "catch", "where", "in", "as", "is", "public", "private", "internal", "fileprivate", "open", "static", "final", "lazy", "weak", "unowned", "some", "any", "async", "await", "actor", "associatedtype", "typealias", "subscript", "didSet", "willSet", "get", "set", "mutating", "nonmutating", "convenience", "required", "optional", "inout", "break", "continue", "fallthrough"],
        "rs": ["let", "mut", "fn", "return", "if", "else", "for", "while", "loop", "match", "struct", "enum", "trait", "impl", "use", "pub", "mod", "crate", "self", "Self", "super", "as", "in", "ref", "move", "async", "await", "dyn", "static", "const", "unsafe", "extern", "true", "false", "break", "continue", "where", "type", "union", "box", "Some", "None", "Ok", "Err"],
        "py": ["def", "return", "if", "elif", "else", "for", "while", "import", "from", "as", "class", "try", "except", "finally", "with", "raise", "yield", "lambda", "pass", "break", "continue", "global", "nonlocal", "assert", "del", "in", "is", "not", "and", "or", "True", "False", "None", "self", "cls", "async", "await", "print"],
        "go": ["func", "return", "if", "else", "for", "range", "switch", "case", "default", "type", "struct", "interface", "package", "import", "var", "const", "go", "defer", "select", "chan", "map", "make", "new", "nil", "true", "false", "break", "continue", "fallthrough", "goto", "defer"],
        "json": ["true", "false", "null"],
        "sh": ["if", "then", "else", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "exit", "set", "unset", "source", "alias", "readonly", "shift"],
        "bash": ["if", "then", "else", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "exit", "set", "unset", "source", "alias", "readonly", "shift"],
    ]

    static func render(_ source: String, language: String, font: NSFont) -> NSAttributedString {
        let normalized = language.lowercased()
        let keywordSet = keywords[normalized] ?? []
        let isJSON = normalized == "json"
        let lineComment = commentMarker(for: normalized)

        let result = NSMutableAttributedString()
        var scanner = Scanner(text: source)
        while !scanner.isAtEnd {
            if let lineComment, scanner.consume(if: lineComment) {
                let comment = scanner.consumeUntilNewline()
                result.append(colored(comment, color: commentColor, font: font))
                continue
            }
            if scanner.consume("\"") {
                let literal = "\"" + scanner.consumeUntil("\"") + "\""
                result.append(colored(literal, color: stringColor, font: font))
                continue
            }
            if scanner.consume("'") {
                let literal = "'" + scanner.consumeUntil("'") + "'"
                result.append(colored(literal, color: stringColor, font: font))
                continue
            }
            if isJSON, scanner.consume("`") {
                let literal = "`" + scanner.consumeUntil("`") + "`"
                result.append(colored(literal, color: stringColor, font: font))
                continue
            }
            if let number = scanner.consumeNumber() {
                result.append(colored(number, color: numberColor, font: font))
                continue
            }
            if let identifier = scanner.consumeIdentifier() {
                if keywordSet.contains(identifier) {
                    result.append(colored(identifier, color: keywordColor, font: font))
                } else if isJSON {
                    result.append(colored(identifier, color: jsonKeyColor, font: font))
                } else {
                    result.append(colored(identifier, color: plainColor, font: font))
                }
                continue
            }
            let next = scanner.consumeAny()
            result.append(colored(String(next), color: plainColor, font: font))
        }
        return result
    }

    private static func commentMarker(for language: String) -> String? {
        switch language {
        case "py", "sh", "bash": return "#"
        case "rs", "go", "swift", "ts", "js": return "//"
        case "json": return nil
        default: return "//"
        }
    }

    private static func colored(_ text: String, color: NSColor, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
            ]
        )
    }
}

struct Scanner {
    private let text: String
    private var index: String.Index
    private let end: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
        self.end = text.endIndex
    }

    var isAtEnd: Bool { index >= end }

    func consume(if marker: String) -> Bool {
        text[index...].hasPrefix(marker)
    }

    mutating func consume(_ marker: String) -> Bool {
        if text[index...].hasPrefix(marker) {
            index = text.index(index, offsetBy: marker.count)
            return true
        }
        return false
    }

    mutating func consumeUntil(_ terminator: String) -> String {
        let start = index
        while index < end {
            if text[index...].hasPrefix(terminator) {
                let captured = String(text[start..<index])
                index = text.index(index, offsetBy: terminator.count)
                return captured
            }
            index = text.index(after: index)
        }
        return String(text[start...])
    }

    mutating func consumeUntilNewline() -> String {
        let start = index
        while index < end, text[index] != "\n" {
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    mutating func consumeNumber() -> String? {
        let start = index
        if index < end, text[index] == "0" {
            let next = text.index(after: index)
            if next < end, text[next] == "x" || text[next] == "X" {
                index = text.index(after: next)
                while index < end, text[index].isHexDigit { index = text.index(after: index) }
                return String(text[start..<index])
            }
        }
        var sawDigit = false
        while index < end {
            let c = text[index]
            if c.isNumber { sawDigit = true; index = text.index(after: index) }
            else if c == "." {
                let next = text.index(after: index)
                if next < end, text[next].isNumber { index = next; sawDigit = true }
                else { break }
            }
            else { break }
        }
        return sawDigit ? String(text[start..<index]) : nil
    }

    mutating func consumeIdentifier() -> String? {
        guard index < end else { return nil }
        let first = text[index]
        guard first.isLetter || first == "_" else { return nil }
        let start = index
        while index < end {
            let c = text[index]
            if c.isLetter || c.isNumber || c == "_" { index = text.index(after: index) }
            else { break }
        }
        return String(text[start..<index])
    }

    mutating func consumeAny() -> Character {
        let c = text[index]
        index = text.index(after: index)
        return c
    }
}
