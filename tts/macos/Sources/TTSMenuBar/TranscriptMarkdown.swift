import AppKit
import Foundation

enum TranscriptMarkdown {
    static func render(_ markdown: String, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var inCodeBlock = false

        for (index, rawLine) in lines.enumerated() {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                if index < lines.count - 1 { result.append(NSAttributedString(string: "\n")) }
                continue
            }

            let descriptor = describe(rawLine, inCodeBlock: inCodeBlock)
            let lineStart = result.length
            if descriptor.isCode {
                result.append(NSAttributedString(
                    string: descriptor.text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.78),
                        .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                    ]
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
        }

        return result
    }

    private struct LineDescriptor {
        let text: String
        let font: NSFont
        let paragraphStyle: NSParagraphStyle
        let isCode: Bool
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
                isCode: true
            )
        }

        if let match = match(#"^(\s*)(#{1,6})\s+"#, in: text) {
            let hashes = (text as NSString).substring(with: match.range(at: 2))
            text = (text as NSString).substring(from: NSMaxRange(match.range))
            font = NSFont.systemFont(ofSize: hashes.count <= 2 ? 22 : 19, weight: .semibold)
            paragraphSpacing = 10
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
            isCode: false
        )
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
