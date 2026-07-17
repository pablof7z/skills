import AppKit
import SwiftUI

struct ReadAlongTranscriptView: NSViewRepresentable {
    final class Coordinator {
        var measuredText = ""
        var measuredWidth: CGFloat = 0
    }

    let text: String
    let timings: [TTSWordTiming]?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let accent: Color
    let onSeek: (TimeInterval) -> Void
    var onContentHeightChange: ((CGFloat) -> Void)? = nil
    var allowsVerticalScrolling = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InteractiveTranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Interactive transcript")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = allowsVerticalScrolling
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = allowsVerticalScrolling ? .automatic : .none
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? InteractiveTranscriptTextView else { return }
        textView.update(
            text: text,
            timings: timings,
            currentTime: currentTime,
            duration: duration,
            accent: NSColor(accent),
            onSeek: onSeek
        )
        scrollView.hasVerticalScroller = allowsVerticalScrolling
        scrollView.verticalScrollElasticity = allowsVerticalScrolling ? .automatic : .none
        guard let onContentHeightChange else { return }
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak scrollView, weak textView] in
            guard let scrollView, let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let width = max(1, scrollView.contentSize.width)
            guard coordinator.measuredText != text || abs(coordinator.measuredWidth - width) > 0.5 else {
                return
            }
            coordinator.measuredText = text
            coordinator.measuredWidth = width
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let contentHeight = ceil(usedHeight + (textView.textContainerInset.height * 2))
            if !allowsVerticalScrolling, abs(textView.frame.height - contentHeight) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: contentHeight))
            }
            onContentHeightChange(contentHeight)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NSCursor.arrow.set()
    }
}

final class InteractiveTranscriptTextView: NSTextView {
    private var document = TranscriptDocument(text: "", words: [], phrases: [])
    private var sourceText = ""
    private var timings: [TTSWordTiming]?
    private var playbackState = TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: nil)
    private var hoveredWordIndex: Int?
    private var lastScrolledPhraseIndex: Int?
    private var accent = NSColor.controlAccentColor
    private var duration: TimeInterval = 0
    private var onSeek: ((TimeInterval) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    func update(
        text: String,
        timings: [TTSWordTiming]?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        accent: NSColor,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        let contentChanged = sourceText != text || self.timings != timings || self.duration != duration
        self.timings = timings
        self.duration = duration
        self.accent = accent
        self.onSeek = onSeek

        if contentChanged {
            sourceText = text
            let rendered = TranscriptMarkdown.render(text, accent: accent)
            document = TranscriptDocument.build(
                attributedText: rendered,
                timings: timings,
                duration: duration
            )
            installText(rendered)
            lastScrolledPhraseIndex = nil
        }

        let nextState = document.playbackState(at: currentTime, duration: duration)
        guard contentChanged || nextState != playbackState else { return }
        playbackState = nextState
        applyPlaybackDecoration()
        followActivePhraseIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        let next = wordIndex(at: convert(event.locationInWindow, from: nil))
        guard next != hoveredWordIndex else { return }
        hoveredWordIndex = next
        (next == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        applyPlaybackDecoration()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredWordIndex != nil else { return }
        hoveredWordIndex = nil
        NSCursor.arrow.set()
        applyPlaybackDecoration()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = wordIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onSeek?(document.seekTime(forWordAt: index, duration: duration))
    }

    private func installText(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    private func applyPlaybackDecoration() {
        guard let layoutManager, !document.text.isEmpty else { return }
        let wholeRange = NSRange(location: 0, length: (document.text as NSString).length)
        for attribute in [
            NSAttributedString.Key.foregroundColor,
            .backgroundColor,
            .underlineStyle,
            .underlineColor,
        ] {
            layoutManager.removeTemporaryAttribute(attribute, forCharacterRange: wholeRange)
        }

        if let activeWordIndex = playbackState.activeWordIndex,
           document.words.indices.contains(activeWordIndex) {
            for completedWord in document.words[..<activeWordIndex] {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.86)],
                    forCharacterRange: completedWord.range
                )
            }
        }

        if let activePhraseIndex = playbackState.activePhraseIndex,
           document.phrases.indices.contains(activePhraseIndex) {
            let phrase = document.phrases[activePhraseIndex]
            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.91),
                    .backgroundColor: accent.withAlphaComponent(0.11),
                ],
                forCharacterRange: phrase.range
            )
        }

        if let activeWordIndex = playbackState.activeWordIndex,
           document.words.indices.contains(activeWordIndex) {
            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: accent,
                    .backgroundColor: accent.withAlphaComponent(0.28),
                ],
                forCharacterRange: document.words[activeWordIndex].range
            )
        }

        if let hoveredWordIndex, document.words.indices.contains(hoveredWordIndex) {
            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: accent,
                    .backgroundColor: accent.withAlphaComponent(0.17),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: accent.withAlphaComponent(0.9),
                ],
                forCharacterRange: document.words[hoveredWordIndex].range
            )
        }

        needsDisplay = true
    }

    private func followActivePhraseIfNeeded() {
        guard let phraseIndex = playbackState.activePhraseIndex,
              phraseIndex != lastScrolledPhraseIndex,
              document.phrases.indices.contains(phraseIndex) else { return }
        lastScrolledPhraseIndex = phraseIndex
        scrollRangeToVisible(document.phrases[phraseIndex].range)
    }

    private func wordIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        guard containerPoint.x >= 0, containerPoint.y >= 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return document.wordIndex(at: characterIndex)
    }
}
