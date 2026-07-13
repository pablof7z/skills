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

struct TTSWordTiming: Codable, Equatable {
    var word: String
    var startTime: Double
    var endTime: Double

    enum CodingKeys: String, CodingKey {
        case word
        case startTime = "start_time"
        case endTime = "end_time"
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
    var playbackOffset: Double? = nil
    var wordTimings: [TTSWordTiming]? = nil
    var mediaHandoffDelay: Double? = nil

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
        case playbackOffset = "playback_offset"
        case wordTimings = "word_timings"
        case mediaHandoffDelay = "media_handoff_delay"
    }

    var displayAgent: String {
        nonempty(agentName) ?? nonempty(harness) ?? "Unknown agent"
    }

    var subjectLabel: String? {
        nonempty(subject)
    }

    var workspaceName: String? {
        guard workspacePath != nil else { return nil }
        return WorkspaceAccent.projectLabel(forWorkspacePath: workspacePath)
    }

    var workspacePath: String? {
        nonempty(workspace)
    }

    var workspaceDisplayLabel: String? {
        WorkspaceAccent.displayLabel(forWorkspacePath: workspacePath)
    }

    var workspaceWorktreeLabel: String? {
        WorkspaceAccent.worktreeLabel(forWorkspacePath: workspacePath)
    }

    var nowSpeakingTitle: String {
        subjectLabel ?? text
    }

    var nowSpeakingContext: String {
        [displayAgent, workspaceDisplayLabel, workspaceWorktreeLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var sessionLabel: String? {
        nonempty(sessionID)
    }

    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt))
    }

    func replayCopy(
        now: Int64 = Int64(Date().timeIntervalSince1970),
        startingAt playbackOffset: TimeInterval? = nil
    ) -> TTSItem {
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
            error: nil,
            playbackOffset: playbackOffset,
            wordTimings: wordTimings,
            mediaHandoffDelay: mediaHandoffDelay
        )
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
