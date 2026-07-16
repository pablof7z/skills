import AppKit
import Combine
import SwiftUI

@MainActor
final class RemotePairingViewModel: ObservableObject {
    @Published var relay: String
    @Published var channel: String
    @Published private(set) var pairingCode: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false
    private let service: RemotePairingService
    private let didCreateOffer: () -> Void
    private var offerTask: Task<Void, Never>?

    init(service: RemotePairingService, didCreateOffer: @escaping () -> Void) {
        self.service = service
        self.didCreateOffer = didCreateOffer
        let configuration = service.configuration()
        relay = configuration.relay
        channel = configuration.channel
    }

    func createOffer() {
        let trimmedRelay = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRelay.isEmpty else {
            errorMessage = "Enter a relay URL."
            return
        }
        let trimmedChannel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannel.isEmpty else {
            errorMessage = "Enter a channel."
            return
        }
        isWorking = true
        errorMessage = nil
        offerTask?.cancel()
        offerTask = Task {
            do {
                let offer = try await Task.detached(priority: .userInitiated) { [service] in
                    try service.createOffer(relay: trimmedRelay, channel: trimmedChannel)
                }.value
                guard !Task.isCancelled else { return }
                pairingCode = offer.code
                didCreateOffer()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func copyCode() {
        guard let pairingCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
    }
}

@MainActor
final class RemotePairingWindowController: NSWindowController {
    init(service: RemotePairingService, didCreateOffer: @escaping () -> Void) {
        let model = RemotePairingViewModel(service: service, didCreateOffer: didCreateOffer)
        let hostingController = NSHostingController(rootView: RemotePairingView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair New Computer"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct RemotePairingView: View {
    @ObservedObject var model: RemotePairingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a remote computer")
                .font(.title2.weight(.semibold))
            Text("Create a one-time code, then give it to the agent on the other computer. Keep TTS running here while it connects.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Pairing Relay").foregroundStyle(.secondary)
                    TextField("wss://relay.example", text: $model.relay)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Channel").foregroundStyle(.secondary)
                    TextField("wss://nip29.example/tts", text: $model.channel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button(model.pairingCode == nil ? "Create Code" : "Create New Code") {
                    model.createOffer()
                }
                .disabled(model.isWorking)
            }

            if model.isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Creating pairing code…").foregroundStyle(.secondary)
                }
            } else if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            } else if let code = model.pairingCode {
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("This code can be used only once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Code") { model.copyCode() }
                }
            } else {
                Spacer(minLength: 36)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 500, height: 340, alignment: .topLeading)
    }
}
