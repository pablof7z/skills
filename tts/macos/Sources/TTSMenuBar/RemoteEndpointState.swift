import Darwin
import Foundation

struct PairedRemoteBackend: Decodable, Equatable, Identifiable {
    let id: String
    let pubkey: String
    let relay: String?
    let name: String?
    let approved: Bool
    let revokedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case relay
        case name
        case approved
        case revokedAt = "revoked_at"
    }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        guard pubkey.count > 8 else { return pubkey }
        return "\(pubkey.prefix(8))…"
    }
}

struct RemoteEndpointSnapshot: Equatable {
    var isListening = false
    var backends: [PairedRemoteBackend] = []
}

struct RemoteEndpointStateReader {
    let stateDirectory: URL
    var processIsAlive: (Int32) -> Bool = Self.defaultProcessIsAlive

    func load() -> RemoteEndpointSnapshot {
        let remote = stateDirectory.appendingPathComponent("remote", isDirectory: true)
        let daemon = decode(DaemonState.self, at: remote.appendingPathComponent("daemon.json"))
        let peers = decode([PairedRemoteBackend].self, at: remote.appendingPathComponent("peers.json")) ?? []
        let listening = daemon.map { state in
            state.running && state.pid.map(processIsAlive) == true
        } ?? false
        return RemoteEndpointSnapshot(
            isListening: listening,
            backends: peers
                .filter { $0.approved && $0.revokedAt == nil }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }

    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func defaultProcessIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }
}

private struct DaemonState: Decodable {
    let running: Bool
    let pid: Int32?
}

enum MenuBarPresentation {
    static func badgeCount(in items: [TTSItem]) -> Int {
        items.filter { $0.unheard && !$0.archived && !$0.isAttachmentPlayback }.count
    }
}
