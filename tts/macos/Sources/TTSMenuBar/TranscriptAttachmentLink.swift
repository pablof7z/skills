import Foundation

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
}
