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
    var attachments: [TTSAttachment] = []
    var onOpenAttachment: ((TTSAttachment) -> Void)? = nil

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
            onSeek: onSeek,
            attachments: attachments,
            onOpenAttachment: onOpenAttachment
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
