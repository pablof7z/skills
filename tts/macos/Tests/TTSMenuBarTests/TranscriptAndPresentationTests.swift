import AVFAudio
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test
    func rendersMarkdownAsStructuredTranscriptText() {
        let rendered = TranscriptMarkdown.render(
            "# Update\n\n- **First** item\n- `Second` item",
            accent: .systemPink
        )

        #expect(rendered.string == "Update\n\n• First item\n• Second item")
    }

    @Test
    func rendersTaskItemsAsDistinctCheckboxes() {
        let rendered = TranscriptMarkdown.render(
            "- [ ] Still open\n- [x] Already done",
            accent: .systemPink
        )

        #expect(rendered.string == "☐  Still open\n☑  Already done")
        let checkedRange = (rendered.string as NSString).range(of: "Already done")
        let style = rendered.attribute(.strikethroughStyle, at: checkedRange.location, effectiveRange: nil) as? Int
        #expect(style == NSUnderlineStyle.single.rawValue)
    }

    @Test
    func rendersMarkdownTableAsStyledCellsWithoutPipeScaffolding() {
        let rendered = TranscriptMarkdown.render(
            """
            | Claim | Method |
            |:------|-------:|
            | API exists | source inspection |
            """,
            accent: .systemPink
        )

        #expect(rendered.string == "Claim\nMethod\nAPI exists\nsource inspection\n")
        #expect(!rendered.string.contains("|"))

        let claimParagraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(claimParagraph?.textBlocks.first is NSTextTableBlock)
        #expect(claimParagraph?.alignment == .left)

        let methodRange = (rendered.string as NSString).range(of: "Method")
        let methodParagraph = rendered.attribute(
            .paragraphStyle,
            at: methodRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(methodParagraph?.alignment == .right)
    }

    @Test
    @MainActor
    func structuredMarkdownLaysOutWithinTheTranscriptWidth() {
        let rendered = TranscriptMarkdown.render(
            """
            | Claim | Method | Result |
            |:------|:-------|-------:|
            | API exists | source inspection | verified |
            | App fold | unit test | passing |

            - [ ] Failure path remains explicit
            - [x] Happy path verified
            """,
            accent: .systemPink
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.containerSize = NSSize(width: 744, height: 1_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(rendered)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            Issue.record("NSTextView did not provide its text system")
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        #expect(usedRect.width <= textContainer.containerSize.width)
        #expect(usedRect.height > 100)
    }

    @Test
    func preservesPipesInsideTableCodeSpans() {
        let rendered = TranscriptMarkdown.render(
            """
            | Expression | Meaning |
            | --- | --- |
            | `left | right` | alternatives |
            """,
            accent: .systemPink
        )

        #expect(rendered.string.contains("left | right"))
        #expect(rendered.string.contains("alternatives"))
    }

    @Test
    func rendersLanguageTaggedCodeBlockWithLabelAndCode() {
        let source = """
        Here is a snippet:

        ```ts
        const x = 5;
        ```
        Done.
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        #expect(rendered.string == "Here is a snippet:\n\nTS\nconst x = 5;\n\nDone.")
    }

    @Test
    func hidesSpeechOnlyCodeDescriptionFromTranscript() {
        let rendered = TranscriptMarkdown.render(
            """
            ```swift
            let passed = true
            ```
            ["The Swift sample returns true."]
            """,
            accent: .systemPink
        )

        #expect(rendered.string.contains("let passed = true"))
        #expect(!rendered.string.contains("The Swift sample returns true"))
    }

    @Test
    func excludesLanguageTaggedCodeFromReadAlongTiming() throws {
        let rendered = TranscriptMarkdown.render(
            """
            Before code.
            ```swift
            let passed = true
            ```
            ["The Swift sample describes a true result in detail."]
            After code.
            """,
            accent: .systemPink
        )
        let timings = [
            timing("Before", 0.0, 0.3),
            timing("code", 0.3, 0.5),
            timing("The", 0.7, 0.9),
            timing("Swift", 0.9, 1.2),
            timing("sample", 1.2, 1.5),
            timing("describes", 1.5, 1.9),
            timing("a", 1.9, 2.0),
            timing("true", 2.0, 2.2),
            timing("result", 2.2, 2.5),
            timing("in", 2.5, 2.6),
            timing("detail", 2.6, 3.0),
            timing("After", 3.2, 3.5),
            timing("code", 3.5, 3.8),
        ]

        let document = TranscriptDocument.build(
            attributedText: rendered,
            timings: timings,
            duration: 3.8
        )
        let codeRange = (rendered.string as NSString).range(of: "passed")
        let afterRange = (rendered.string as NSString).range(of: "After")

        #expect(document.words.count == 4)
        #expect(document.wordIndex(at: codeRange.location) == nil)
        #expect(document.playbackState(at: 1.5, duration: 3.8).activeWordIndex == nil)
        #expect(document.wordIndex(at: afterRange.location) == 2)
        #expect(document.playbackState(at: 3.3, duration: 3.8).activeWordIndex == 2)
        #expect(document.seekTime(forWordAt: 2, duration: 3.8) == 3.2)
    }

    @Test
    func rendersBareCodeBlockWithoutLabel() {
        let source = """
        Run this:

        ```
        echo hello
        ```
        Done.
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        #expect(rendered.string == "Run this:\n\n\necho hello\n\nDone.")
        let codeRange = (rendered.string as NSString).range(of: "echo")
        #expect(rendered.attribute(
            .transcriptNonSpoken,
            at: codeRange.location,
            effectiveRange: nil
        ) == nil)
    }

    @Test
    func highlightsKeywordsInLanguageTaggedCodeBlock() {
        let source = """
        ```swift
        let x = 5
        ```
        """
        let rendered = TranscriptMarkdown.render(source, accent: .systemPink)

        let string = rendered.string
        #expect(string.contains("SWIFT"))
        #expect(string.contains("let x = 5"))

        let keywordColor = NSColor(calibratedRed: 0.55, green: 0.34, blue: 0.92, alpha: 1.0)
        var foundKeywordColor = false
        rendered.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: rendered.length),
            options: []
        ) { value, _, stop in
            if let color = value as? NSColor, color == keywordColor {
                foundKeywordColor = true
                stop.pointee = true
            }
        }
        #expect(foundKeywordColor)
        let codeRange = (rendered.string as NSString).range(of: "let")
        #expect(rendered.attribute(
            .transcriptNonSpoken,
            at: codeRange.location,
            effectiveRange: nil
        ) as? Bool == true)
    }

    @Test
    func mermaidPreviewLoadsRendererAndKeepsReadableFallback() {
        let source = "flowchart LR\nA[Message] --> B{Type}"
        let document = MermaidHTML.document(source: source, darkMode: true, accentHue: 87)

        #expect(document.contains("mermaid@11"))
        #expect(document.contains("mermaid.render"))
        #expect(document.contains("Diagram preview unavailable"))
        #expect(document.contains("flowchart LR\\nA[Message] --> B{Type}"))
    }

    @Test
    func measuredPauseCreatesPhraseWithoutPunctuation() {
        let text = "A calm phrase then another thought"
        let timings = [
            timing("A", 0, 0.1),
            timing("calm", 0.1, 0.4),
            timing("phrase", 0.4, 0.8),
            timing("then", 1.2, 1.5),
            timing("another", 1.5, 1.9),
            timing("thought", 1.9, 2.2),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 2.2)

        #expect(document.phrases.map(\.wordRange) == [0..<3, 3..<6])
    }

    @Test
    func legacyTranscriptShowsPhraseProgressWithoutFakeWordPrecision() {
        let document = TranscriptDocument.build(
            text: "First sentence. Second sentence.",
            timings: nil,
            duration: 10
        )
        let state = document.playbackState(at: 7, duration: 10)

        #expect(state.activeWordIndex == nil)
        #expect(state.activePhraseIndex == 1)
        #expect(document.seekTime(forWordAt: 2, duration: 10) == 5)
    }

    @Test
    func lingerCountdownPreservesRemainingTimeAcrossHoverPause() {
        var countdown = LingerCountdown(duration: 8)
        countdown.start(at: 100)

        countdown.pause(at: 103)
        #expect(countdown.timeRemaining(at: 150) == 5)

        countdown.resume(at: 150)
        #expect(countdown.timeRemaining(at: 152) == 3)

        countdown.pause(at: 154)
        #expect(countdown.timeRemaining(at: 300) == 1)

        countdown.cancel()
        #expect(countdown.timeRemaining(at: 300) == 8)
    }

    @Test
    func pendingQuestionRetentionIdentifiesUnresolvedItems() {
        var question = item(id: "pending-question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        var answered = question
        answered.questionStatus = .answered

        #expect(PendingQuestionRetention.shouldRetain(
            lastCurrentItem: question,
            lingeringItem: nil
        ))
        #expect(PendingQuestionRetention.shouldRetain(
            lastCurrentItem: nil,
            lingeringItem: question
        ))
        #expect(!PendingQuestionRetention.shouldRetain(
            lastCurrentItem: answered,
            lingeringItem: nil
        ))
        #expect(PendingQuestionRetention.retainedItem(
            currentItem: nil,
            lingeringItem: question,
            lastCurrentItem: nil
        )?.id == question.id)
    }

    @Test
    func playerBackNavigationSuppressesOnlyTheCurrentItem() {
        #expect(!PlayerHistoryToolbarPolicy.rootItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.backItemIdentifier
        ))
        #expect(PlayerHistoryToolbarPolicy.allowedItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.backItemIdentifier
        ))
        #expect(!PlayerNavigationPolicy.shouldDisplay(
            itemID: "question",
            hiddenItemID: "question"
        ))
        #expect(PlayerNavigationPolicy.shouldDisplay(
            itemID: "next-update",
            hiddenItemID: "question"
        ))
        #expect(PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: "question",
            currentlyHidden: "question"
        ) == "question")
        #expect(PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: "next-update",
            currentlyHidden: "question"
        ) == nil)
    }

    @Test
    func playerHoverRetainsFinishedContentThroughTheExitGracePeriod() {
        #expect(PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: true,
            isGracePeriodActive: false,
            hasCurrentContent: true
        ))
        #expect(PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: false,
            isGracePeriodActive: true,
            hasCurrentContent: true
        ))
        #expect(!PlayerHoverContinuation.shouldRetainCurrentContent(
            isHovered: false,
            isGracePeriodActive: false,
            hasCurrentContent: true
        ))
    }

    @Test
    func completedPendingQuestionAudioRemainsReplayableFromItsAnswerView() {
        var question = item(id: "pending-question", createdAt: 10)
        question.kind = .question
        question.questionStatus = .pending
        question.status = .played

        #expect(QuestionAudioReview.canReplay(question, fileExists: { _ in true }))
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in false }))

        question.status = .generating
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in true }))

        question.status = .played
        question.kind = .speech
        question.questionStatus = nil
        #expect(!QuestionAudioReview.canReplay(question, fileExists: { _ in true }))
    }

    @Test
    func unchangedHUDLayoutDoesNotRequestAnotherAnimation() {
        let frame = CGRect(x: 20, y: 20, width: 540, height: 470)

        #expect(!HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: frame,
            currentAlpha: 1,
            targetAlpha: 1
        ))
        #expect(HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: CGRect(x: 20, y: 20, width: 470, height: 226),
            currentAlpha: 1,
            targetAlpha: 1
        ))
        #expect(HUDLayoutUpdate.isNeeded(
            currentFrame: frame,
            targetFrame: frame,
            currentAlpha: 0.84,
            targetAlpha: 1
        ))
    }

}
