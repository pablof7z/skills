import Foundation

enum PlaybackStatus: String, Codable, CaseIterable {
    case queued
    case playing
    case paused
    case played
    case failed

    var isPending: Bool {
        self == .queued
    }

    var isRecent: Bool {
        self == .played || self == .failed
    }
}

struct TTSItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var subject: String?
    var agentName: String?
    var harness: String?
    var sessionID: String?
    var workspace: String?
    var voice: String
    var outputFile: String
    var status: PlaybackStatus
    var createdAt: Int64
    var startedAt: Int64?
    var completedAt: Int64?
    var duration: Double?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case subject
        case agentName = "agent_name"
        case harness
        case sessionID = "session_id"
        case workspace
        case voice
        case outputFile = "output_file"
        case status
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case duration
        case error
    }

    var displayAgent: String {
        nonempty(agentName) ?? nonempty(harness) ?? "Unknown agent"
    }

    var subjectLabel: String? {
        nonempty(subject)
    }

    var workspaceName: String? {
        guard let workspace = nonempty(workspace) else { return nil }
        return URL(fileURLWithPath: workspace).lastPathComponent
    }

    var sessionLabel: String? {
        nonempty(sessionID)
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    func replayCopy(now: Int64 = Int64(Date().timeIntervalSince1970)) -> TTSItem {
        TTSItem(
            id: "replay-\(UUID().uuidString.lowercased())",
            text: text,
            subject: subject,
            agentName: agentName,
            harness: harness,
            sessionID: sessionID,
            workspace: workspace,
            voice: voice,
            outputFile: outputFile,
            status: .queued,
            createdAt: now,
            startedAt: nil,
            completedAt: nil,
            duration: duration,
            error: nil
        )
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
