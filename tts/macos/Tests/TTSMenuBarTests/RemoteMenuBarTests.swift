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
            ["pair", "offer", "--relay", "wss://relay.example"]: Data(
                #"{"status":"offered","pair_code":{"version":1,"product":"tts","secret":"once"}}"#.utf8
            ),
            ["daemon", "status"]: Data(#"{"running":false}"#.utf8),
            ["daemon", "start"]: Data(#"{"status":"started","pid":10}"#.utf8),
        ])
        let service = RemotePairingService(
            stateDirectory: URL(fileURLWithPath: "/tmp/tts-test"),
            commandRunner: runner
        )

        let offer = try service.createOffer(relay: "wss://relay.example")

        #expect(offer.code.contains(#""secret" : "once""#))
        #expect(runner.commands == [
            ["pair", "offer", "--relay", "wss://relay.example"],
            ["daemon", "status"],
            ["daemon", "start"],
        ])
    }

    @Test @MainActor
    func closingLastWindowDoesNotTerminateBackgroundApp() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test
    func pairingOfferKeepsExistingListener() throws {
        let offer = Data(#"{"pair_code":{"version":1,"product":"tts","secret":"once"}}"#.utf8)
        let runner = RecordingRemoteCommandRunner(responses: [
            ["pair", "offer", "--relay", "wss://relay.example"]: offer,
            ["daemon", "status"]: Data(#"{"running":true}"#.utf8),
        ])
        let service = RemotePairingService(
            stateDirectory: URL(fileURLWithPath: "/tmp/tts-test"),
            commandRunner: runner
        )

        _ = try service.createOffer(relay: "wss://relay.example")

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
