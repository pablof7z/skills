import AppKit
import Foundation
import Testing
@testable import TTSMenuBar

struct RemoteMenuBarTests {
    @Test
    func legacyPreferencesShowMenuBarByDefault() throws {
        let data = Data(#"{"pausesMedia":false,"mediaHandoffDelay":1,"mediaResumeDelay":4}"#.utf8)
        let preferences = try JSONDecoder().decode(PlayerPreferences.self, from: data)

        #expect(preferences.showsMenuBarItem)
    }

    @Test @MainActor
    func menuBarPreferencePersists() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerPreferencesStore(stateDirectory: directory)

        store.setShowsMenuBarItem(false)

        let restored = PlayerPreferencesStore(stateDirectory: directory)
        #expect(!restored.preferences.showsMenuBarItem)
    }

    @Test
    func badgeCountsOnlyUnheardTopLevelItems() {
        var unheard = testItem(id: "unheard")
        unheard.isUnheard = true
        var heard = testItem(id: "heard")
        heard.isUnheard = false
        var archived = testItem(id: "archived")
        archived.isUnheard = true
        archived.isArchived = true
        var attachment = testItem(id: "attachment")
        attachment.isUnheard = true
        attachment.parentItemID = "unheard"
        attachment.attachmentID = "file"

        #expect(MenuBarPresentation.badgeCount(in: [unheard, heard, archived, attachment]) == 1)
    }

    @Test
    func readsListeningStateAndApprovedRemoteBackends() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data(#"{"running":true,"pid":4242}"#.utf8).write(
            to: remote.appendingPathComponent("daemon.json")
        )
        try Data(#"[{"id":"approved","pubkey":"abcdef0123456789","relay":"wss://relay.example","approved":true},{"id":"revoked","pubkey":"bad","approved":false}]"#.utf8).write(
            to: remote.appendingPathComponent("peers.json")
        )

        let reader = RemoteEndpointStateReader(
            stateDirectory: directory,
            processIsAlive: { $0 == 4242 }
        )
        let snapshot = reader.load()

        #expect(snapshot.isListening)
        #expect(snapshot.backends.map(\.id) == ["approved"])
        #expect(snapshot.backends[0].displayName == "abcdef01…")
    }

    @Test
    func pairingOfferStartsListenerWhenNeeded() throws {
        let runner = RecordingRemoteCommandRunner(responses: [
            ["pair", "offer", "--relay", "wss://relay.example", "--channel", "wss://nip29.example/tts"]: Data(
                #"{"status":"offered","pair_code":"ttspair1_opaque"}"#.utf8
            ),
            ["daemon", "status"]: Data(#"{"running":false}"#.utf8),
            ["daemon", "start"]: Data(#"{"status":"started","pid":10}"#.utf8),
        ])
        let service = RemotePairingService(
            stateDirectory: URL(fileURLWithPath: "/tmp/tts-test"),
            commandRunner: runner
        )

        let offer = try service.createOffer(
            relay: "wss://relay.example",
            channel: "wss://nip29.example/tts"
        )

        #expect(offer.code == "ttspair1_opaque")
        #expect(runner.commands == [
            ["pair", "offer", "--relay", "wss://relay.example", "--channel", "wss://nip29.example/tts"],
            ["daemon", "status"],
            ["daemon", "start"],
        ])
    }

    @Test
    func pairingConfigurationLoadsSavedRelayAndChannel() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data(#"{"relay":"wss://relay.example","channel":"wss://nip29.example/spoken"}"#.utf8).write(
            to: remote.appendingPathComponent("config.json")
        )
        let runner = RecordingRemoteCommandRunner(responses: [:])
        let service = RemotePairingService(stateDirectory: directory, commandRunner: runner)

        #expect(service.configuration() == RemotePairingConfiguration(
            relay: "wss://relay.example",
            channel: "wss://nip29.example/spoken"
        ))
    }

    @Test
    func pairingConfigurationDefaultsMissingChannelWithoutDiscardingRelay() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data(#"{"relay":"wss://relay.example"}"#.utf8).write(
            to: remote.appendingPathComponent("config.json")
        )

        let service = RemotePairingService(
            stateDirectory: directory,
            commandRunner: RecordingRemoteCommandRunner(responses: [:])
        )

        #expect(service.configuration().relay == "wss://relay.example")
        #expect(service.configuration().channel == "wss://nip29.f7z.io/tts")
    }

    @Test
    func commandFailureShowsMessageAndGuidanceWithoutRawJSON() {
        let data = Data(
            #"{"status":"error","error":{"message":"Relay URL is invalid.","guidance":"Use wss://."}}"#.utf8
        )

        #expect(
            ShellTTSRemoteCommandRunner.failureMessage(data)
                == "Relay URL is invalid. Use wss://."
        )
    }

    @Test @MainActor
    func pairingViewModelRemainsResponsiveWhileOfferCommandWaits() async throws {
        let runner = BlockingRemoteCommandRunner()
        let service = RemotePairingService(
            stateDirectory: URL(fileURLWithPath: "/tmp/tts-test"),
            commandRunner: runner
        )
        let model = RemotePairingViewModel(service: service, didCreateOffer: {})
        model.relay = "wss://relay.example"
        model.channel = "wss://nip29.example/tts"

        model.createOffer()
        await Task.yield()

        #expect(model.isWorking)
        #expect(model.pairingCode == nil)
        runner.release.signal()
        for _ in 0..<100 where model.pairingCode == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.pairingCode == "ttspair1_opaque")
        #expect(!model.isWorking)
    }

    @Test @MainActor
    func closingLastWindowDoesNotTerminateBackgroundApp() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test
    func pairingOfferKeepsExistingListener() throws {
        let offer = Data(#"{"pair_code":"ttspair1_opaque"}"#.utf8)
        let runner = RecordingRemoteCommandRunner(responses: [
            ["pair", "offer", "--relay", "wss://relay.example", "--channel", "wss://nip29.example/tts"]: offer,
            ["daemon", "status"]: Data(#"{"running":true}"#.utf8),
        ])
        let service = RemotePairingService(
            stateDirectory: URL(fileURLWithPath: "/tmp/tts-test"),
            commandRunner: runner
        )

        _ = try service.createOffer(
            relay: "wss://relay.example",
            channel: "wss://nip29.example/tts"
        )

        #expect(runner.commands.count == 2)
    }

    private func testItem(id: String) -> TTSItem {
        TTSItem(
            id: id,
            text: id,
            subject: nil,
            agentName: nil,
            harness: nil,
            sessionID: nil,
            workspace: nil,
            voice: "af_heart",
            outputFile: "/tmp/\(id).wav",
            status: .played,
            createdAt: 1,
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-remote-menu-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RecordingRemoteCommandRunner: RemoteCommandRunning, @unchecked Sendable {
    let responses: [[String]: Data]
    private(set) var commands: [[String]] = []

    init(responses: [[String]: Data]) {
        self.responses = responses
    }

    func run(arguments: [String], stateDirectory _: URL) throws -> Data {
        commands.append(arguments)
        guard let response = responses[arguments] else {
            throw RemotePairingError.commandFailed("unexpected command")
        }
        return response
    }
}

private final class BlockingRemoteCommandRunner: RemoteCommandRunning, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)

    func run(arguments: [String], stateDirectory _: URL) throws -> Data {
        if arguments.first == "pair" {
            release.wait()
            return Data(#"{"pair_code":"ttspair1_opaque"}"#.utf8)
        }
        if arguments == ["daemon", "status"] {
            return Data(#"{"running":true}"#.utf8)
        }
        throw RemotePairingError.commandFailed("unexpected command")
    }
}
