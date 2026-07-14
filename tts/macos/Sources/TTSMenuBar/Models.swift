import Foundation

enum PlaybackStatus: String, Codable, CaseIterable {
    case generating
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

enum TTSAttachmentKind: String, Codable, Equatable {
    case narratedText = "narrated_text"
    case image
    case diagram
    case audio
    case file
}

enum TTSAttachmentStatus: String, Codable, Equatable {
    case preparing
    case ready
    case failed
}

struct TTSAttachment: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var kind: TTSAttachmentKind
    var status: TTSAttachmentStatus
    var sourceFile: String
    var text: String? = nil
    var audioFile: String? = nil
    var wordTimings: [TTSWordTiming]? = nil
    var error: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case kind
        case status
        case sourceFile = "source_file"
        case text
        case audioFile = "audio_file"
        case wordTimings = "word_timings"
        case error
    }

    var isPlayable: Bool {
        status == .ready && audioFile != nil
    }

    var displayText: String? {
        if let text, !text.isEmpty { return text }
        guard kind == .narratedText else { return nil }
        return try? String(contentsOfFile: sourceFile, encoding: .utf8)
    }
}

struct TTSItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var subject: String?
    var agentName: String?
    var harness: String?
    var sessionID: String?
    var iTermSessionID: String? = nil
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
    var attachments: [TTSAttachment]? = nil
    var assetDirectory: String? = nil
    var parentItemID: String? = nil
    var attachmentID: String? = nil
    var returnToPlaybackOffset: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case subject
        case agentName = "agent_name"
        case harness
        case sessionID = "session_id"
        case iTermSessionID = "iterm_session_id"
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
        case attachments
        case assetDirectory = "asset_directory"
        case parentItemID = "parent_item_id"
        case attachmentID = "attachment_id"
        case returnToPlaybackOffset = "return_to_playback_offset"
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

    var briefAttachments: [TTSAttachment] {
        attachments ?? []
    }

    var isAttachmentPlayback: Bool {
        parentItemID != nil && attachmentID != nil
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
            iTermSessionID: iTermSessionID,
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
            mediaHandoffDelay: mediaHandoffDelay,
            attachments: attachments,
            assetDirectory: assetDirectory
        )
    }

    func attachmentPlaybackItem(
        _ attachment: TTSAttachment,
        now: Int64 = Int64(Date().timeIntervalSince1970),
        returnTo playbackOffset: TimeInterval?
    ) -> TTSItem? {
        guard attachment.isPlayable, let audioFile = attachment.audioFile else { return nil }
        return TTSItem(
            id: "attachment-\(UUID().uuidString.lowercased())",
            text: attachment.displayText ?? attachment.label,
            subject: attachment.label,
            agentName: agentName,
            harness: harness,
            sessionID: sessionID,
            iTermSessionID: iTermSessionID,
            workspace: workspace,
            voice: voice,
            outputFile: audioFile,
            status: .queued,
            createdAt: now,
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil,
            playbackOffset: nil,
            wordTimings: attachment.wordTimings,
            mediaHandoffDelay: mediaHandoffDelay,
            attachments: attachments,
            assetDirectory: assetDirectory,
            parentItemID: id,
            attachmentID: attachment.id,
            returnToPlaybackOffset: playbackOffset
        )
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
