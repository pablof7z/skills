import AppKit

enum PlayerHistoryFilterIcon {
    static func image(activeCount: Int) -> NSImage? {
        guard activeCount > 0 else {
            return NSImage(
                systemSymbolName: "line.3.horizontal.decrease",
                accessibilityDescription: "Filter history"
            )
        }

        let count = activeCount > 99 ? "99+" : String(activeCount)
        let image = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { _ in
            let symbol = NSImage(
                systemSymbolName: "line.3.horizontal.decrease",
                accessibilityDescription: nil
            )
            symbol?.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))

            let badgeRect = NSRect(x: 15, y: 3, width: 15, height: 13)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 6.5, yRadius: 6.5).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: count.count > 2 ? 6.5 : 8, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = count.size(withAttributes: attributes)
            count.draw(
                at: NSPoint(
                    x: badgeRect.midX - size.width / 2,
                    y: badgeRect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Filter history, \(activeCount) active"
        return image
    }
}
