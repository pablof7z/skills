import Foundation

struct TranscriptAttachmentTarget: Equatable {
    let attachment: TTSAttachment
    let range: NSRange
}

enum TranscriptAttachmentLink {
    static let destination = "attachment:"

    static func resolve(
        link: Any?,
        visibleLabel: String,
        attachments: [TTSAttachment]
    ) -> TTSAttachment? {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard url?.absoluteString.caseInsensitiveCompare(destination) == .orderedSame else {
            return nil
        }

        let matches = attachments.filter { $0.label == visibleLabel }
        return matches.count == 1 ? matches[0] : nil
    }

    static func target(
        at characterIndex: Int,
        in text: NSAttributedString,
        attachments: [TTSAttachment]
    ) -> TranscriptAttachmentTarget? {
        guard characterIndex >= 0, characterIndex < text.length else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        let link = text.attribute(.link, at: characterIndex, effectiveRange: &range)
        guard range.location != NSNotFound else { return nil }
        let label = (text.string as NSString).substring(with: range)
        guard let attachment = resolve(link: link, visibleLabel: label, attachments: attachments) else {
            return nil
        }
        return TranscriptAttachmentTarget(attachment: attachment, range: range)
    }

    static func targets(
        in text: NSAttributedString,
        attachments: [TTSAttachment]
    ) -> [TranscriptAttachmentTarget] {
        var results: [TranscriptAttachmentTarget] = []
        var characterIndex = 0
        while characterIndex < text.length {
            var range = NSRange(location: NSNotFound, length: 0)
            _ = text.attribute(.link, at: characterIndex, effectiveRange: &range)
            if let target = target(at: characterIndex, in: text, attachments: attachments),
               results.last?.range != target.range {
                results.append(target)
            }
            characterIndex = range.location == NSNotFound
                ? characterIndex + 1
                : max(characterIndex + 1, NSMaxRange(range))
        }
        return results
    }
}
