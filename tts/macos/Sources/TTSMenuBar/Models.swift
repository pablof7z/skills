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
    var retryCommand: String? = nil
    var generationDuration: Double? = nil
    var isUnheard: Bool? = nil
    var parentItemID: String? = nil
    var attachmentID: String? = nil
    var returnToPlaybackOffset: Double? = nil
    var isArchived: Bool? = nil

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
        case retryCommand = "retry_command"
        case generationDuration = "generation_duration"
        case isUnheard = "is_unheard"
        case parentItemID = "parent_item_id"
        case attachmentID = "attachment_id"
        case returnToPlaybackOffset = "return_to_playback_offset"
        case isArchived = "is_archived"
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

    var archived: Bool {
        isArchived == true
    }

    var unheard: Bool {
        isUnheard == true
    }

    /// Replaying a durable brief is playback of the same update, not a new
    /// generation. Keep its identity and creation time so history remains a
    /// reliable record of when the agent actually produced it.
    func requeuedForReplay(
        startingAt playbackOffset: TimeInterval? = nil
    ) -> TTSItem {
        TTSItem(
            id: id,
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
            createdAt: createdAt,
            startedAt: nil,
            completedAt: nil,
            duration: duration,
            error: nil,
            playbackOffset: playbackOffset,
            wordTimings: wordTimings,
            mediaHandoffDelay: mediaHandoffDelay,
            attachments: attachments,
            assetDirectory: assetDirectory,
            retryCommand: retryCommand,
            generationDuration: generationDuration,
            isUnheard: isUnheard,
            parentItemID: parentItemID,
            attachmentID: attachmentID,
            returnToPlaybackOffset: returnToPlaybackOffset,
            isArchived: isArchived
        )
    }

    func timestampLabel(now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(createdDate))
        if elapsed < 60 { return "just now" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        return createdDate.formatted(date: .abbreviated, time: .shortened)
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
            retryCommand: retryCommand,
            generationDuration: generationDuration,
            isUnheard: isUnheard,
            parentItemID: id,
            attachmentID: attachment.id,
            returnToPlaybackOffset: playbackOffset,
            isArchived: isArchived
        )
    }
}

enum GenerationProgress {
    private static let fallbackDuration: TimeInterval = 24

    static func value(for item: TTSItem, samples: [TTSItem], now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(item.createdDate))
        let expected = estimatedDuration(for: item, samples: samples)
        let eased = 0.04 + 0.90 * (1 - exp(-1.9 * elapsed / expected))
        return min(max(eased, 0.04), 0.94)
    }

    static func estimatedDuration(for item: TTSItem, samples: [TTSItem]) -> TimeInterval {
        let targetScale = sqrt(Double(max(item.text.split(whereSeparator: \.isWhitespace).count, 1)))
        let normalized = samples.compactMap { sample -> Double? in
            guard sample.status != .failed,
                  let duration = sample.generationDuration,
                  duration.isFinite,
                  duration > 0,
                  duration < 600 else { return nil }
            let words = max(sample.text.split(whereSeparator: \.isWhitespace).count, 1)
            return duration / sqrt(Double(words))
        }
        guard !normalized.isEmpty else { return fallbackDuration }
        let sorted = normalized.sorted()
        let midpoint = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[midpoint - 1] + sorted[midpoint]) / 2
            : sorted[midpoint]
        return min(max(median * targetScale, 8), 180)
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
