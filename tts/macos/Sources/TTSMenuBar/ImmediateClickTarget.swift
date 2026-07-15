import AppKit
import SwiftUI

struct ImmediateClickTarget: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context _: Context) -> ImmediateClickNSView {
        ImmediateClickNSView(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: ImmediateClickNSView, context _: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

final class ImmediateClickNSView: NSView {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void

    init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onSingleClick()
        } else if event.clickCount == 2 {
            onDoubleClick()
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
