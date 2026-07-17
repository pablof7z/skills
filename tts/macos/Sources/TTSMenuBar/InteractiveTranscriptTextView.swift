import AppKit

final class InteractiveTranscriptTextView: NSTextView {
    private var document = TranscriptDocument(text: "", words: [], phrases: [])
    private var sourceText = ""
    private var timings: [TTSWordTiming]?
    private var playbackState = TranscriptPlaybackState(activeWordIndex: nil, activePhraseIndex: nil)
    private var hoveredWordIndex: Int?
    private var hoveredAttachmentRange: NSRange?
    private var lastScrolledPhraseIndex: Int?
    private var accent = NSColor.controlAccentColor
    private var duration: TimeInterval = 0
    private var onSeek: ((TimeInterval) -> Void)?
    private var attachments: [TTSAttachment] = []
    private var onOpenAttachment: ((TTSAttachment) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
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
        onSeek: @escaping (TimeInterval) -> Void,
        attachments: [TTSAttachment] = [],
        onOpenAttachment: ((TTSAttachment) -> Void)? = nil
    ) {
        let contentChanged = sourceText != text || self.timings != timings || self.duration != duration
        let attachmentsChanged = self.attachments != attachments
        self.timings = timings
        self.duration = duration
        self.accent = accent
        self.onSeek = onSeek
        self.attachments = attachments
        self.onOpenAttachment = onOpenAttachment

        if contentChanged {
            sourceText = text
            let rendered = TranscriptMarkdown.render(text, accent: accent)
            document = TranscriptDocument.build(attributedText: rendered, timings: timings, duration: duration)
            textStorage?.setAttributedString(rendered)
            invalidateIntrinsicContentSize()
            lastScrolledPhraseIndex = nil
            hoveredWordIndex = nil
            hoveredAttachmentRange = nil
        } else if attachmentsChanged {
            hoveredAttachmentRange = nil
        }

        let nextState = document.playbackState(at: currentTime, duration: duration)
        guard contentChanged || attachmentsChanged || nextState != playbackState else { return }
        playbackState = nextState
        applyPlaybackDecoration()
        followActivePhraseIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let characterIndex = characterIndex(at: point)
        let nextAttachment = characterIndex.flatMap { index in
            self.attachmentTarget(atCharacterIndex: index)
        }
        let nextWord = nextAttachment == nil
            ? characterIndex.flatMap { document.wordIndex(at: $0) }
            : nil
        guard nextAttachment?.range != hoveredAttachmentRange || nextWord != hoveredWordIndex else { return }
        hoveredAttachmentRange = nextAttachment?.range
        hoveredWordIndex = nextWord
        (nextAttachment == nil && nextWord == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        applyPlaybackDecoration()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredWordIndex != nil || hoveredAttachmentRange != nil else { return }
        hoveredWordIndex = nil
        hoveredAttachmentRange = nil
        NSCursor.arrow.set()
        applyPlaybackDecoration()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let characterIndex = characterIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        if let target = attachmentTarget(atCharacterIndex: characterIndex), let onOpenAttachment {
            onOpenAttachment(target.attachment)
            return
        }
        guard let index = document.wordIndex(at: characterIndex) else {
            super.mouseDown(with: event)
            return
        }
        onSeek?(document.seekTime(forWordAt: index, duration: duration))
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        drawAttachmentButtons(in: dirtyRect)
    }

    func attachment(atCharacterIndex characterIndex: Int) -> TTSAttachment? {
        attachmentTarget(atCharacterIndex: characterIndex)?.attachment
    }

    func hoverTarget(atCharacterIndex characterIndex: Int) -> TranscriptHoverTarget? {
        if let target = attachmentTarget(atCharacterIndex: characterIndex) {
            return .attachment(target.range)
        }
        return document.wordIndex(at: characterIndex).map(TranscriptHoverTarget.word)
    }

    private func attachmentTarget(atCharacterIndex characterIndex: Int) -> TranscriptAttachmentTarget? {
        guard let textStorage else { return nil }
        return TranscriptAttachmentLink.target(
            at: characterIndex,
            in: textStorage,
            attachments: attachments
        )
    }

    private func attachmentTargets() -> [TranscriptAttachmentTarget] {
        guard let textStorage else { return [] }
        return TranscriptAttachmentLink.targets(in: textStorage, attachments: attachments)
    }

    private func applyPlaybackDecoration() {
        guard let layoutManager, !document.text.isEmpty else { return }
        let wholeRange = NSRange(location: 0, length: (document.text as NSString).length)
        for attribute in [
            NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor,
        ] {
            layoutManager.removeTemporaryAttribute(attribute, forCharacterRange: wholeRange)
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

        for target in attachmentTargets() {
            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: accent,
                    .underlineStyle: 0,
                    .underlineColor: NSColor.clear,
                ],
                forCharacterRange: target.range
            )
        }
        needsDisplay = true
    }

    private func drawAttachmentButtons(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        for target in attachmentTargets() {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: target.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { [weak self] rect, _ in
                guard let self else { return }
                let buttonRect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                    .insetBy(dx: -4, dy: -1)
                guard buttonRect.intersects(dirtyRect) else { return }
                let hovered = target.range == hoveredAttachmentRange
                let path = NSBezierPath(roundedRect: buttonRect, xRadius: 5, yRadius: 5)
                accent.withAlphaComponent(hovered ? 0.25 : 0.12).setFill()
                path.fill()
                accent.withAlphaComponent(hovered ? 0.8 : 0.42).setStroke()
                path.lineWidth = hovered ? 1.2 : 0.8
                path.stroke()
            }
        }
    }

    private func followActivePhraseIfNeeded() {
        guard let phraseIndex = playbackState.activePhraseIndex,
              phraseIndex != lastScrolledPhraseIndex,
              document.phrases.indices.contains(phraseIndex) else { return }
        lastScrolledPhraseIndex = phraseIndex
        scrollRangeToVisible(document.phrases[phraseIndex].range)
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard containerPoint.x >= 0, containerPoint.y >= 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}

enum TranscriptHoverTarget: Equatable {
    case attachment(NSRange)
    case word(Int)
}
