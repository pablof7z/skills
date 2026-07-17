import AppKit
import Combine
import Foundation
import SwiftUI

struct PlayerPreferences: Codable, Equatable {
    private static let mediaControlSafetyVersion = 1

    var pausesMedia: Bool
    var mediaHandoffDelay: Double
    var mediaResumeDelay: Double
    var showsMenuBarItem: Bool
    var askDockAttentionMode: AskDockAttentionMode
    var askDockAttentionIntervalMinutes: Int
    var sendsAskNotifications: Bool
    var maxParallelGenerations: Int
    private var mediaControlVersion: Int

    enum CodingKeys: String, CodingKey {
        case pausesMedia
        case mediaHandoffDelay
        case mediaResumeDelay
        case showsMenuBarItem
        case askDockAttentionMode
        case askDockAttentionIntervalMinutes
        case sendsAskNotifications
        case maxParallelGenerations
        case mediaControlVersion
    }

    init(
        pausesMedia: Bool = false,
        mediaHandoffDelay: Double = 2,
        mediaResumeDelay: Double = 3,
        showsMenuBarItem: Bool = true,
        askDockAttentionMode: AskDockAttentionMode = .once,
        askDockAttentionIntervalMinutes: Int = 5,
        sendsAskNotifications: Bool = false,
        maxParallelGenerations: Int = 2
    ) {
        self.pausesMedia = pausesMedia
        self.mediaHandoffDelay = mediaHandoffDelay
        self.mediaResumeDelay = mediaResumeDelay
        self.showsMenuBarItem = showsMenuBarItem
        self.askDockAttentionMode = askDockAttentionMode
        self.askDockAttentionIntervalMinutes = Self.clampAttentionInterval(
            askDockAttentionIntervalMinutes
        )
        self.sendsAskNotifications = sendsAskNotifications
        self.maxParallelGenerations = Self.clampGenerationLimit(maxParallelGenerations)
        mediaControlVersion = Self.mediaControlSafetyVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .mediaControlVersion)
        pausesMedia = version == Self.mediaControlSafetyVersion
            ? try values.decodeIfPresent(Bool.self, forKey: .pausesMedia) ?? false
            : false
        mediaHandoffDelay = Self.clamp(
            try values.decodeIfPresent(Double.self, forKey: .mediaHandoffDelay) ?? 2
        )
        mediaResumeDelay = Self.clamp(
            try values.decodeIfPresent(Double.self, forKey: .mediaResumeDelay) ?? 3
        )
        showsMenuBarItem = try values.decodeIfPresent(Bool.self, forKey: .showsMenuBarItem) ?? true
        askDockAttentionMode = try values.decodeIfPresent(
            AskDockAttentionMode.self,
            forKey: .askDockAttentionMode
        ) ?? .once
        askDockAttentionIntervalMinutes = Self.clampAttentionInterval(
            try values.decodeIfPresent(Int.self, forKey: .askDockAttentionIntervalMinutes) ?? 5
        )
        sendsAskNotifications = try values.decodeIfPresent(
            Bool.self,
            forKey: .sendsAskNotifications
        ) ?? false
        maxParallelGenerations = Self.clampGenerationLimit(
            try values.decodeIfPresent(Int.self, forKey: .maxParallelGenerations) ?? 2
        )
        mediaControlVersion = Self.mediaControlSafetyVersion
    }

    static func clamp(_ delay: Double) -> Double {
        min(max(delay, 0), 10)
    }

    static func clampAttentionInterval(_ minutes: Int) -> Int {
        min(max(minutes, 1), 120)
    }

    static func clampGenerationLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 8)
    }

}

@MainActor
final class PlayerPreferencesStore: ObservableObject {
    let fileURL: URL
    @Published private(set) var preferences: PlayerPreferences

    init(stateDirectory: URL) {
        fileURL = stateDirectory.appendingPathComponent("player-preferences.json")
        preferences = Self.load(from: fileURL)
    }

    func setPausesMedia(_ pausesMedia: Bool) {
        update { $0.pausesMedia = pausesMedia }
    }

    func setMediaHandoffDelay(_ delay: Double) {
        update { $0.mediaHandoffDelay = PlayerPreferences.clamp(delay) }
    }

    func setMediaResumeDelay(_ delay: Double) {
        update { $0.mediaResumeDelay = PlayerPreferences.clamp(delay) }
    }

    func setShowsMenuBarItem(_ visible: Bool) {
        update { $0.showsMenuBarItem = visible }
    }

    func setAskDockAttentionMode(_ mode: AskDockAttentionMode) {
        update { $0.askDockAttentionMode = mode }
    }

    func setAskDockAttentionIntervalMinutes(_ minutes: Int) {
        update { $0.askDockAttentionIntervalMinutes = PlayerPreferences.clampAttentionInterval(minutes) }
    }

    func setSendsAskNotifications(_ enabled: Bool) {
        update { $0.sendsAskNotifications = enabled }
    }

    func setMaxParallelGenerations(_ limit: Int) {
        update { $0.maxParallelGenerations = PlayerPreferences.clampGenerationLimit(limit) }
    }

    private func update(_ mutation: (inout PlayerPreferences) -> Void) {
        var updated = preferences
        mutation(&updated)
        guard updated != preferences else { return }
        preferences = updated
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

    private static func load(from fileURL: URL) -> PlayerPreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let preferences = try? JSONDecoder().decode(PlayerPreferences.self, from: data) else {
            return PlayerPreferences()
        }
        return preferences
    }
}

@MainActor
final class PlayerPreferencesWindowController: NSWindowController, NSWindowDelegate {
    init(preferencesStore: PlayerPreferencesStore) {
        let view = PlayerPreferencesView(preferencesStore: preferencesStore)
        let hostingController = NSHostingController(rootView: view)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "TTS Preferences"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.center()
        showWindow(nil)
    }
}
