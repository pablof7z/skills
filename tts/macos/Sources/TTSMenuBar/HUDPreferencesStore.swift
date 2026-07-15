import Foundation

struct PlayerWindowPreferences: Codable, Equatable {
    var isPlayerVisible: Bool
    var isMiniPlayer: Bool
    var originX: Double?
    var originY: Double?
    var expandedWidth: Double?
    var expandedHeight: Double?

    init(
        isPlayerVisible: Bool = true,
        isMiniPlayer: Bool = false,
        originX: Double? = nil,
        originY: Double? = nil,
        expandedWidth: Double? = nil,
        expandedHeight: Double? = nil
    ) {
        self.isPlayerVisible = isPlayerVisible
        self.isMiniPlayer = isMiniPlayer
        self.originX = originX
        self.originY = originY
        self.expandedWidth = expandedWidth
        self.expandedHeight = expandedHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isPlayerVisible = try container.decodeIfPresent(Bool.self, forKey: .isPlayerVisible) ?? true
        isMiniPlayer = try container.decodeIfPresent(Bool.self, forKey: .isMiniPlayer) ?? false
        originX = try container.decodeIfPresent(Double.self, forKey: .originX)
        originY = try container.decodeIfPresent(Double.self, forKey: .originY)
        expandedWidth = try container.decodeIfPresent(Double.self, forKey: .expandedWidth)
        expandedHeight = try container.decodeIfPresent(Double.self, forKey: .expandedHeight)
    }

    var origin: CGPoint? {
        guard let originX, let originY else { return nil }
        return CGPoint(x: originX, y: originY)
    }

    var expandedSize: CGSize? {
        guard let expandedWidth, let expandedHeight else { return nil }
        return CGSize(width: expandedWidth, height: expandedHeight)
    }
}

final class PlayerWindowPreferencesStore {
    let fileURL: URL
    private(set) var preferences: PlayerWindowPreferences

    init(stateDirectory: URL) {
        fileURL = stateDirectory.appendingPathComponent("hud-preferences.json")
        preferences = Self.load(from: fileURL)
    }

    func setPlayerVisible(_ visible: Bool) {
        preferences.isPlayerVisible = visible
        save()
    }

    func setMiniPlayer(_ miniPlayer: Bool) {
        preferences.isMiniPlayer = miniPlayer
        save()
    }

    func setOrigin(_ origin: CGPoint) {
        preferences.originX = origin.x
        preferences.originY = origin.y
        save()
    }

    func setExpandedSize(_ size: CGSize) {
        preferences.expandedWidth = size.width
        preferences.expandedHeight = size.height
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Unable to save TTS player preferences: %@", error.localizedDescription)
        }
    }

    private static func load(from fileURL: URL) -> PlayerWindowPreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let preferences = try? JSONDecoder().decode(PlayerWindowPreferences.self, from: data) else {
            return PlayerWindowPreferences()
        }
        return preferences
    }
}

enum HUDPlacement {
    static func preferredExpandedSize(saved: CGSize?, minimum: CGSize) -> CGSize {
        guard let saved else { return minimum }
        return CGSize(
            width: max(saved.width, minimum.width),
            height: max(saved.height, minimum.height)
        )
    }

    static func frame(
        size: CGSize,
        preferredOrigin: CGPoint?,
        visibleFrames: [CGRect],
        inset: CGFloat
    ) -> CGRect {
        guard !visibleFrames.isEmpty else {
            return CGRect(origin: preferredOrigin ?? CGPoint(x: inset, y: inset), size: size)
        }

        let screenFrame = preferredScreen(
            for: preferredOrigin,
            visibleFrames: visibleFrames
        ) ?? visibleFrames[0]
        let usableFrame = screenFrame.insetBy(dx: inset, dy: inset)
        let fittedSize = CGSize(
            width: min(size.width, usableFrame.width),
            height: min(size.height, usableFrame.height)
        )
        let defaultOrigin = CGPoint(x: usableFrame.minX, y: usableFrame.minY)
        let origin = preferredOrigin ?? defaultOrigin
        let maxX = max(usableFrame.minX, usableFrame.maxX - fittedSize.width)
        let maxY = max(usableFrame.minY, usableFrame.maxY - fittedSize.height)

        return CGRect(
            x: min(max(origin.x, usableFrame.minX), maxX),
            y: min(max(origin.y, usableFrame.minY), maxY),
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func preferredScreen(
        for origin: CGPoint?,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard let origin else { return visibleFrames.first }
        if let containing = visibleFrames.first(where: { $0.contains(origin) }) {
            return containing
        }
        return visibleFrames.min {
            distanceSquared(from: origin, to: $0) < distanceSquared(from: origin, to: $1)
        }
    }

    private static func distanceSquared(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, frame.minX), frame.maxX)
        let nearestY = min(max(point.y, frame.minY), frame.maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY
        return deltaX * deltaX + deltaY * deltaY
    }
}

struct HUDResizeEdges: OptionSet {
    let rawValue: Int

    static let left = HUDResizeEdges(rawValue: 1 << 0)
    static let right = HUDResizeEdges(rawValue: 1 << 1)
    static let bottom = HUDResizeEdges(rawValue: 1 << 2)
    static let top = HUDResizeEdges(rawValue: 1 << 3)
}

enum HUDResize {
    static func frame(
        initialFrame: CGRect,
        pointerDelta: CGPoint,
        edges: HUDResizeEdges,
        visibleFrame: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        let minimumWidth = min(minimumSize.width, visibleFrame.width)
        let minimumHeight = min(minimumSize.height, visibleFrame.height)
        var minX = initialFrame.minX
        var maxX = initialFrame.maxX
        var minY = initialFrame.minY
        var maxY = initialFrame.maxY

        if edges.contains(.left) {
            minX = min(
                max(initialFrame.minX + pointerDelta.x, visibleFrame.minX),
                initialFrame.maxX - minimumWidth
            )
        } else if edges.contains(.right) {
            maxX = max(
                min(initialFrame.maxX + pointerDelta.x, visibleFrame.maxX),
                initialFrame.minX + minimumWidth
            )
        }

        if edges.contains(.bottom) {
            minY = min(
                max(initialFrame.minY + pointerDelta.y, visibleFrame.minY),
                initialFrame.maxY - minimumHeight
            )
        } else if edges.contains(.top) {
            maxY = max(
                min(initialFrame.maxY + pointerDelta.y, visibleFrame.maxY),
                initialFrame.minY + minimumHeight
            )
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
