import AppKit
import Combine
import Foundation
import SwiftUI

struct PlayerPreferences: Codable, Equatable {
    var pausesMedia: Bool
    var mediaHandoffDelay: Double
    var mediaResumeDelay: Double

    init(
        pausesMedia: Bool = true,
        mediaHandoffDelay: Double = 2,
        mediaResumeDelay: Double = 3
    ) {
        self.pausesMedia = pausesMedia
        self.mediaHandoffDelay = mediaHandoffDelay
        self.mediaResumeDelay = mediaResumeDelay
    }

    static func clamp(_ delay: Double) -> Double {
        min(max(delay, 0), 10)
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
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

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 220, alignment: .topLeading)
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
