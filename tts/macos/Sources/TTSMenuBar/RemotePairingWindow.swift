import AppKit
import Combine
import SwiftUI

@MainActor
final class RemotePairingViewModel: ObservableObject {
    @Published var relay = "wss://relay.primal.net"
    @Published private(set) var pairingCode: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false
    private let service: RemotePairingService
    private let didCreateOffer: () -> Void

    init(service: RemotePairingService, didCreateOffer: @escaping () -> Void) {
        self.service = service
        self.didCreateOffer = didCreateOffer
    }

    func createOffer() {
        let trimmedRelay = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRelay.isEmpty else {
            errorMessage = "Enter a relay URL."
            return
        }
        isWorking = true
        errorMessage = nil
        do {
            pairingCode = try service.createOffer(relay: trimmedRelay).code
            didCreateOffer()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
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

            HStack {
                TextField("Relay", text: $model.relay)
                    .textFieldStyle(.roundedBorder)
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
                TextEditor(text: .constant(code))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("This code expires and can be used only once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Code") { model.copyCode() }
                }
            } else {
                Spacer(minLength: 150)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 500, height: 430, alignment: .topLeading)
    }
}
