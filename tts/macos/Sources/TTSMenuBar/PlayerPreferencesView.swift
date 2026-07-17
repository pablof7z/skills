import Foundation
import SwiftUI

struct PlayerPreferencesView: View {
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

    private var showsMenuBarItem: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.showsMenuBarItem },
            set: { preferencesStore.setShowsMenuBarItem($0) }
        )
    }

    private var askDockAttentionMode: Binding<AskDockAttentionMode> {
        Binding(
            get: { preferencesStore.preferences.askDockAttentionMode },
            set: { preferencesStore.setAskDockAttentionMode($0) }
        )
    }

    private var askDockAttentionIntervalMinutes: Binding<Int> {
        Binding(
            get: { preferencesStore.preferences.askDockAttentionIntervalMinutes },
            set: { preferencesStore.setAskDockAttentionIntervalMinutes($0) }
        )
    }

    private var sendsAskNotifications: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.sendsAskNotifications },
            set: { preferencesStore.setSendsAskNotifications($0) }
        )
    }

    private var maxParallelGenerations: Binding<Int> {
        Binding(
            get: { preferencesStore.preferences.maxParallelGenerations },
            set: { preferencesStore.setMaxParallelGenerations($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Media") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Pause Music and Spotify while TTS plays", isOn: pausesMedia)
                    VStack(alignment: .leading, spacing: 10) {
                        delayStepper(title: "Start speech after media pauses", value: mediaHandoffDelay)
                        delayStepper(title: "Resume media after speech ends", value: mediaResumeDelay)
                    }
                    .disabled(!preferencesStore.preferences.pausesMedia)
                    .opacity(preferencesStore.preferences.pausesMedia ? 1 : 0.45)
                }
                .padding(.vertical, 4)
            }

            GroupBox("New asks") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Bounce the Dock icon")
                        Spacer()
                        Picker("Bounce the Dock icon", selection: askDockAttentionMode) {
                            ForEach(AskDockAttentionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)

                        if preferencesStore.preferences.askDockAttentionMode == .repeated {
                            Stepper(value: askDockAttentionIntervalMinutes, in: 1...120, step: 1) {
                                Text("\(askDockAttentionIntervalMinutes.wrappedValue) min")
                                    .monospacedDigit()
                            }
                            .frame(width: 115)
                        }
                    }
                    Toggle("Send a macOS notification", isOn: sendsAskNotifications)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Generation") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Maximum simultaneous Kokoro requests")
                        Spacer()
                        Stepper(value: maxParallelGenerations, in: 1...8) {
                            Text("\(maxParallelGenerations.wrappedValue)")
                                .monospacedDigit()
                        }
                        .frame(width: 90)
                    }
                    Text("Shared by every local TTS agent. New requests wait when all slots are busy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Toggle("Show TTS in the menu bar", isOn: showsMenuBarItem)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 450, alignment: .topLeading)
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
