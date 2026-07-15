import AppKit
import Combine
import Foundation
import SwiftUI

enum FloatnessMode: String, Codable, CaseIterable, Equatable {
    case normal
    case bringToFrontWhenPlaying
    case alwaysOnTop
    case alwaysOnTopWhilePlaying

    var label: String {
        switch self {
        case .normal: "Normal"
        case .bringToFrontWhenPlaying: "Bring to front when playing"
        case .alwaysOnTop: "Always on top"
        case .alwaysOnTopWhilePlaying: "Always on top while playing"
        }
    }

    var symbolName: String {
        switch self {
        case .normal: "rectangle"
        case .bringToFrontWhenPlaying: "arrow.up.to.line"
        case .alwaysOnTop: "pin.fill"
        case .alwaysOnTopWhilePlaying: "pin"
        }
    }

    static let defaultMode: FloatnessMode = .bringToFrontWhenPlaying
}

struct PlayerPreferences: Codable, Equatable {
    var pausesMedia: Bool
    var mediaHandoffDelay: Double
    var mediaResumeDelay: Double
    var floatnessMode: FloatnessMode
    var windowOpacity: Double

    enum CodingKeys: String, CodingKey {
        case pausesMedia
        case mediaHandoffDelay
        case mediaResumeDelay
        case floatnessMode
        case windowOpacity
        case keepsWindowOnTopWhilePlaying
    }

    init(
        pausesMedia: Bool = true,
        mediaHandoffDelay: Double = 2,
        mediaResumeDelay: Double = 3,
        floatnessMode: FloatnessMode = .defaultMode,
        windowOpacity: Double = 1.0
    ) {
        self.pausesMedia = pausesMedia
        self.mediaHandoffDelay = mediaHandoffDelay
        self.mediaResumeDelay = mediaResumeDelay
        self.floatnessMode = floatnessMode
        self.windowOpacity = Self.clampOpacity(windowOpacity)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pausesMedia = try container.decodeIfPresent(Bool.self, forKey: .pausesMedia) ?? true
        mediaHandoffDelay = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .mediaHandoffDelay) ?? 2
        )
        mediaResumeDelay = Self.clamp(
            try container.decodeIfPresent(Double.self, forKey: .mediaResumeDelay) ?? 3
        )
        if let mode = try container.decodeIfPresent(FloatnessMode.self, forKey: .floatnessMode) {
            floatnessMode = mode
        } else {
            let legacy = try container.decodeIfPresent(
                Bool.self,
                forKey: .keepsWindowOnTopWhilePlaying
            ) ?? false
            floatnessMode = legacy ? .alwaysOnTopWhilePlaying : .defaultMode
        }
        windowOpacity = Self.clampOpacity(
            try container.decodeIfPresent(Double.self, forKey: .windowOpacity) ?? 1.0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pausesMedia, forKey: .pausesMedia)
        try container.encode(mediaHandoffDelay, forKey: .mediaHandoffDelay)
        try container.encode(mediaResumeDelay, forKey: .mediaResumeDelay)
        try container.encode(floatnessMode, forKey: .floatnessMode)
        try container.encode(windowOpacity, forKey: .windowOpacity)
    }

    static func clamp(_ delay: Double) -> Double {
        min(max(delay, 0), 10)
    }

    static func clampOpacity(_ opacity: Double) -> Double {
        min(max(opacity, 0.2), 1.0)
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

    func setKeepsWindowOnTopWhilePlaying(_ keepsOnTop: Bool) {
        setFloatnessMode(keepsOnTop ? .alwaysOnTopWhilePlaying : .defaultMode)
    }

    func setFloatnessMode(_ mode: FloatnessMode) {
        update { $0.floatnessMode = mode }
    }

    func setWindowOpacity(_ opacity: Double) {
        update { $0.windowOpacity = PlayerPreferences.clampOpacity(opacity) }
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
    private var isShowingModal = false

    init(preferencesStore: PlayerPreferencesStore) {
        let view = PlayerPreferencesView(preferencesStore: preferencesStore)
        let hostingController = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "TTS Preferences"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.center()
        isShowingModal = true
        NSApp.runModal(for: window)
        isShowingModal = false
    }

    func windowWillClose(_ notification: Notification) {
        guard isShowingModal else { return }
        NSApp.stopModal()
    }
}

private struct PlayerPreferencesView: View {
    @ObservedObject var preferencesStore: PlayerPreferencesStore

    private var pausesMedia: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.pausesMedia },
            set: { preferencesStore.setPausesMedia($0) }
        )
    }

    private var mediaHandoffDelay: Binding<Double> {
        Binding(
            get: { preferencesStore.preferences.mediaHandoffDelay },
            set: { preferencesStore.setMediaHandoffDelay($0) }
        )
    }

    private var mediaResumeDelay: Binding<Double> {
        Binding(
            get: { preferencesStore.preferences.mediaResumeDelay },
            set: { preferencesStore.setMediaResumeDelay($0) }
        )
    }

    private var floatnessMode: Binding<FloatnessMode> {
        Binding(
            get: { preferencesStore.preferences.floatnessMode },
            set: { preferencesStore.setFloatnessMode($0) }
        )
    }

    private var windowOpacity: Binding<Double> {
        Binding(
            get: { preferencesStore.preferences.windowOpacity },
            set: { preferencesStore.setWindowOpacity($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Media") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Pause Music and Spotify while TTS plays", isOn: pausesMedia)

                    VStack(alignment: .leading, spacing: 10) {
                        delayStepper(
                            title: "Start speech after media pauses",
                            value: mediaHandoffDelay
                        )
                        delayStepper(
                            title: "Resume media after speech ends",
                            value: mediaResumeDelay
                        )
                    }
                    .disabled(!preferencesStore.preferences.pausesMedia)
                    .opacity(preferencesStore.preferences.pausesMedia ? 1 : 0.45)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Windowed Player") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Floatness", selection: floatnessMode) {
                        ForEach(FloatnessMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Window transparency")
                            Spacer()
                            Text(String(
                                format: "%d%%",
                                Int((1.0 - preferencesStore.preferences.windowOpacity) * 100)
                            ))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        }
                        Slider(value: windowOpacity, in: 0.2...1.0, step: 0.05)
                        Text("Makes the windowed player translucent. Hovering the player returns it to fully opaque.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 420, alignment: .topLeading)
    }

    private func delayStepper(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, in: 0...10, step: 0.5) {
                Text(String(format: "%.1f seconds", value.wrappedValue))
                    .monospacedDigit()
            }
        }
    }
}
