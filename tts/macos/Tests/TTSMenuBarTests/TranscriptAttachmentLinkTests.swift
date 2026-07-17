import AppKit
import Foundation
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test
    func rendersAttachmentLinksWithVisibleLabelsForReadAlong() throws {
        let rendered = TranscriptMarkdown.render(
            "Open [Why this matters](attachment:) now.",
            accent: .systemPink
        )
        let labelRange = (rendered.string as NSString).range(of: "Why this matters")
        let link = try #require(
            rendered.attribute(.link, at: labelRange.location, effectiveRange: nil) as? URL
        )
        let document = TranscriptDocument.build(
            attributedText: rendered,
            timings: [
                timing("Open", 0, 0.2),
                timing("Why", 0.2, 0.4),
                timing("this", 0.4, 0.6),
                timing("matters", 0.6, 0.9),
                timing("now", 0.9, 1.1),
            ],
            duration: 1.1
        )
        let spokenWords = document.words.map {
            (document.text as NSString).substring(with: $0.range).lowercased()
        }

        #expect(rendered.string == "Open Why this matters now.")
        #expect(link.absoluteString == TranscriptAttachmentLink.destination)
        #expect(spokenWords == ["open", "why", "this", "matters", "now"])
    }

    @Test
    func attachmentLinksResolveOnlyOneExactLabel() {
        let expected = attachment()
        let link = URL(string: TranscriptAttachmentLink.destination)

        #expect(TranscriptAttachmentLink.resolve(
            link: link,
            visibleLabel: expected.label,
            attachments: [expected]
        ) == expected)
        #expect(TranscriptAttachmentLink.resolve(
            link: link,
            visibleLabel: expected.label.lowercased(),
            attachments: [expected]
        ) == nil)
        #expect(TranscriptAttachmentLink.resolve(
            link: link,
            visibleLabel: expected.label,
            attachments: [expected, expected]
        ) == nil)
        #expect(TranscriptAttachmentLink.resolve(
            link: URL(string: "https://example.com"),
            visibleLabel: expected.label,
            attachments: [expected]
        ) == nil)
        #expect(TranscriptAttachmentLink.resolve(
            link: URL(string: "attachment:why"),
            visibleLabel: expected.label,
            attachments: [expected]
        ) == nil)
    }

    @Test @MainActor
    func transcriptTextViewResolvesAttachmentAtLinkedLabel() throws {
        let expected = attachment()
        let textView = InteractiveTranscriptTextView()
        textView.update(
            text: "Open [Why this matters](attachment:).",
            timings: nil,
            currentTime: 0,
            duration: 0,
            accent: .systemPink,
            onSeek: { _ in },
            attachments: [expected],
            onOpenAttachment: nil
        )
        let labelRange = (try #require(textView.textStorage).string as NSString)
            .range(of: expected.label)

        #expect(textView.attachment(atCharacterIndex: labelRange.location) == expected)
        #expect(textView.attachment(atCharacterIndex: 0) == nil)
    }
}
