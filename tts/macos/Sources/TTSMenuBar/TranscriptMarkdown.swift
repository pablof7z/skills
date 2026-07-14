import AppKit
import Foundation

enum TranscriptMarkdown {
    static func render(_ markdown: String, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var codeBlockLanguage: String? = nil
        var inCodeBlock = false

        var index = 0
        while index < lines.count {
            if !inCodeBlock,
               let table = parseTable(in: lines, startingAt: index) {
                result.append(renderTable(table, accent: accent))
                index = table.endIndex
                continue
            }

            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    inCodeBlock = false
                    codeBlockLanguage = nil
                    if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
                    index += 1
                    continue
                }
                let fence = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCodeBlock = true
                codeBlockLanguage = fence.isEmpty ? nil : fence
                if !fence.isEmpty {
                    let labelStart = result.length
                    result.append(NSAttributedString(
                        string: fence.uppercased(),
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                            .foregroundColor: accent.withAlphaComponent(0.85),
                            .backgroundColor: accent.withAlphaComponent(0.10),
                        ]
                    ))
                    let labelParagraph = NSMutableParagraphStyle()
                    labelParagraph.lineSpacing = 2
                    labelParagraph.paragraphSpacing = 2
                    labelParagraph.lineBreakMode = .byWordWrapping
                    labelParagraph.firstLineHeadIndent = 12
                    result.addAttribute(.paragraphStyle, value: labelParagraph, range: NSRange(location: labelStart, length: result.length - labelStart))
                }
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
                index += 1
                continue
            }

            let descriptor = describe(rawLine, inCodeBlock: inCodeBlock)
            let lineStart = result.length
            if descriptor.isCode {
                if let language = codeBlockLanguage {
                    result.append(SyntaxHighlighter.render(
                        descriptor.text,
                        language: language,
                        font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
                    ))
                } else {
                    result.append(NSAttributedString(
                        string: descriptor.text,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.78),
                            .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                        ]
                    ))
                }
            } else if let checked = descriptor.taskChecked {
                result.append(renderTaskItem(
                    descriptor.text,
                    checked: checked,
                    font: descriptor.font,
                    accent: accent
                ))
            } else {
                result.append(renderInline(
                    descriptor.text,
                    font: descriptor.font,
                    accent: accent
                ))
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
            let lineRange = NSRange(location: lineStart, length: result.length - lineStart)
            if lineRange.length > 0 {
                result.addAttribute(.paragraphStyle, value: descriptor.paragraphStyle, range: lineRange)
            }
            index += 1
        }

        return result
    }

    private struct LineDescriptor {
        let text: String
        let font: NSFont
        let paragraphStyle: NSParagraphStyle
        let isCode: Bool
        let taskChecked: Bool?
    }

    private static func describe(_ rawLine: String, inCodeBlock: Bool) -> LineDescriptor {
        var text = rawLine
        var font = NSFont.systemFont(ofSize: 18, weight: .regular)
        var listIndent: CGFloat = 0
        var paragraphSpacing: CGFloat = rawLine.isEmpty ? 8 : 5

        if inCodeBlock {
            return LineDescriptor(
                text: rawLine,
                font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                paragraphStyle: paragraphStyle(spacing: 3, indent: 12),
                isCode: true,
                taskChecked: nil
            )
        }

        if let match = match(#"^(\s*)(#{1,6})\s+"#, in: text) {
            let hashes = (text as NSString).substring(with: match.range(at: 2))
            text = (text as NSString).substring(from: NSMaxRange(match.range))
            font = NSFont.systemFont(ofSize: hashes.count <= 2 ? 22 : 19, weight: .semibold)
            paragraphSpacing = 10
        } else if let match = match(#"^(\s*)[-*+]\s+\[([ xX])\]\s+"#, in: text) {
            let indentation = (text as NSString).substring(with: match.range(at: 1)).count
            let marker = (text as NSString).substring(with: match.range(at: 2))
            text = (text as NSString).substring(from: NSMaxRange(match.range))
            listIndent = CGFloat(30 + min(indentation, 8) * 3)
            paragraphSpacing = 4
            return LineDescriptor(
                text: text,
                font: font,
                paragraphStyle: paragraphStyle(spacing: paragraphSpacing, indent: listIndent),
                isCode: false,
                taskChecked: marker.lowercased() == "x"
            )
        } else if let match = match(#"^(\s*)[-*+]\s+"#, in: text) {
            let indentation = (text as NSString).substring(with: match.range(at: 1)).count
            text = "• " + (text as NSString).substring(from: NSMaxRange(match.range))
            listIndent = CGFloat(20 + min(indentation, 8) * 3)
            paragraphSpacing = 3
        } else if let match = match(#"^(\s*)(\d+)[.)]\s+"#, in: text) {
            let indentation = (text as NSString).substring(with: match.range(at: 1)).count
            let number = (text as NSString).substring(with: match.range(at: 2))
            text = "\(number). " + (text as NSString).substring(from: NSMaxRange(match.range))
            listIndent = CGFloat(24 + min(indentation, 8) * 3)
            paragraphSpacing = 3
        } else if let match = match(#"^\s*>\s?"#, in: text) {
            text = "› " + (text as NSString).substring(from: NSMaxRange(match.range))
            listIndent = 20
        }

        return LineDescriptor(
            text: text,
            font: font,
            paragraphStyle: paragraphStyle(spacing: paragraphSpacing, indent: listIndent),
            isCode: false,
            taskChecked: nil
        )
    }

    private struct MarkdownTable {
        let rows: [[String]]
        let alignments: [NSTextAlignment]
        let endIndex: Int
    }

    private static func parseTable(in lines: [String], startingAt startIndex: Int) -> MarkdownTable? {
        guard startIndex + 1 < lines.count,
              lines[startIndex].contains("|"),
              lines[startIndex + 1].contains("|") else { return nil }

        let header = tableCells(in: lines[startIndex])
        let separators = tableCells(in: lines[startIndex + 1])
        guard header.count >= 2,
              header.count == separators.count,
              separators.allSatisfy({ match(#"^:?-{3,}:?$"#, in: $0) != nil }) else { return nil }

        let alignments = separators.map { separator -> NSTextAlignment in
            let leading = separator.hasPrefix(":")
            let trailing = separator.hasSuffix(":")
            if leading && trailing { return .center }
            if trailing { return .right }
            return .left
        }

        var rows = [header]
        var cursor = startIndex + 2
        while cursor < lines.count,
              !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[cursor].contains("|") {
            var cells = tableCells(in: lines[cursor])
            guard cells.count >= 2 else { break }
            if cells.count < header.count {
                cells.append(contentsOf: repeatElement("", count: header.count - cells.count))
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            cursor += 1
        }

        return MarkdownTable(rows: rows, alignments: alignments, endIndex: cursor)
    }

    private static func tableCells(in line: String) -> [String] {
        var source = line.trimmingCharacters(in: .whitespaces)
        if source.hasPrefix("|") { source.removeFirst() }
        if source.hasSuffix("|") { source.removeLast() }

        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in source {
            if escaped {
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func renderTable(_ markdownTable: MarkdownTable, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = markdownTable.alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        let borderColor = NSColor.separatorColor.withAlphaComponent(0.45)
        for (rowIndex, row) in markdownTable.rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(
                    100 / CGFloat(markdownTable.alignments.count),
                    type: .percentageValueType
                )
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(borderColor)
                block.verticalAlignment = .middleAlignment
                if rowIndex == 0 {
                    block.backgroundColor = accent.withAlphaComponent(0.12)
                } else if rowIndex.isMultiple(of: 2) {
                    block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = markdownTable.alignments[columnIndex]
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.lineSpacing = 3

                let font = NSFont.systemFont(ofSize: 16, weight: rowIndex == 0 ? .semibold : .regular)
                let cellText = renderInline(cell, font: font, accent: accent).mutableCopy() as! NSMutableAttributedString
                cellText.addAttributes(
                    [.paragraphStyle: paragraph],
                    range: NSRange(location: 0, length: cellText.length)
                )
                cellText.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                result.append(cellText)
            }
        }
        return result
    }

    private static func renderTaskItem(
        _ source: String,
        checked: Bool,
        font: NSFont,
        accent: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: checked ? "☑  " : "☐  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                .foregroundColor: checked ? accent.withAlphaComponent(0.92) : NSColor.secondaryLabelColor,
            ]
        )
        let content = renderInline(source, font: font, accent: accent).mutableCopy() as! NSMutableAttributedString
        if checked, content.length > 0 {
            content.addAttributes(
                [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor,
                ],
                range: NSRange(location: 0, length: content.length)
            )
        }
        result.append(content)
        return result
    }

    private static func paragraphStyle(spacing: CGFloat, indent: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = spacing
        paragraph.lineBreakMode = .byWordWrapping
        if indent > 0 {
            paragraph.firstLineHeadIndent = 5
            paragraph.headIndent = indent
        }
        return paragraph
    }

    private static func renderInline(_ source: String, font: NSFont, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var cursor = source.startIndex
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            result.append(fragment(plain, font: font))
            plain = ""
        }

        while cursor < source.endIndex {
            let suffix = source[cursor...]
            if suffix.hasPrefix("**"),
               let end = source.range(of: "**", range: source.index(cursor, offsetBy: 2)..<source.endIndex) {
                flushPlain()
                let contentStart = source.index(cursor, offsetBy: 2)
                result.append(fragment(String(source[contentStart..<end.lowerBound]), font: bold(font)))
                cursor = end.upperBound
            } else if suffix.hasPrefix("__"),
                      let end = source.range(of: "__", range: source.index(cursor, offsetBy: 2)..<source.endIndex) {
                flushPlain()
                let contentStart = source.index(cursor, offsetBy: 2)
                result.append(fragment(String(source[contentStart..<end.lowerBound]), font: bold(font)))
                cursor = end.upperBound
            } else if suffix.hasPrefix("`"),
                      let end = source.range(of: "`", range: source.index(after: cursor)..<source.endIndex) {
                flushPlain()
                let content = String(source[source.index(after: cursor)..<end.lowerBound])
                result.append(NSAttributedString(
                    string: content,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: max(14, font.pointSize - 1), weight: .medium),
                        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82),
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                    ]
                ))
                cursor = end.upperBound
            } else if suffix.hasPrefix("["),
                      let labelEnd = source.range(of: "](", range: source.index(after: cursor)..<source.endIndex),
                      let urlEnd = source.range(of: ")", range: labelEnd.upperBound..<source.endIndex) {
                flushPlain()
                let label = String(source[source.index(after: cursor)..<labelEnd.lowerBound])
                let url = String(source[labelEnd.upperBound..<urlEnd.lowerBound])
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
                if let link = URL(string: url) { attributes[.link] = link }
                result.append(NSAttributedString(string: label, attributes: attributes))
                cursor = urlEnd.upperBound
            } else if (suffix.hasPrefix("*") || suffix.hasPrefix("_")) {
                let marker = String(source[cursor])
                if let end = source.range(of: marker, range: source.index(after: cursor)..<source.endIndex) {
                    flushPlain()
                    let content = String(source[source.index(after: cursor)..<end.lowerBound])
                    result.append(fragment(content, font: italic(font)))
                    cursor = end.upperBound
                } else {
                    plain.append(source[cursor])
                    cursor = source.index(after: cursor)
                }
            } else {
                plain.append(source[cursor])
                cursor = source.index(after: cursor)
            }
        }
        flushPlain()
        return result
    }

    private static func fragment(_ text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.58),
            ]
        )
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func match(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expression.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }
}

private enum SyntaxHighlighter {
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

private struct Scanner {
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
