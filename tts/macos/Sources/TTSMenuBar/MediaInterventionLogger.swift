import Foundation

struct MediaInterventionSession: Codable, Equatable {
    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let contentIdentifier: String?
    let isPlaying: Bool

    init(_ session: MediaSessionSnapshot) {
        bundleIdentifier = session.bundleIdentifier
        processIdentifier = session.processIdentifier
        contentIdentifier = session.contentIdentifier
        isPlaying = session.isPlaying
    }
}

struct MediaInterventionRecord: Codable, Equatable {
    let timestamp: Date
    let event: String
    let generation: UInt64
    let itemID: String?
    let leaseID: UUID?
    let backend: String?
    let session: MediaInterventionSession?
    let desiredPlaying: Bool?
    let attempt: Int?
    let delaySeconds: TimeInterval?
    let reason: String?
    let error: String?

    init(
        timestamp: Date = Date(),
        event: String,
        generation: UInt64,
        itemID: String? = nil,
        leaseID: UUID? = nil,
        backend: String? = nil,
        session: MediaInterventionSession? = nil,
        desiredPlaying: Bool? = nil,
        attempt: Int? = nil,
        delaySeconds: TimeInterval? = nil,
        reason: String? = nil,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.event = event
        self.generation = generation
        self.itemID = itemID
        self.leaseID = leaseID
        self.backend = backend
        self.session = session
        self.desiredPlaying = desiredPlaying
        self.attempt = attempt
        self.delaySeconds = delaySeconds
        self.reason = reason
        self.error = error
    }
}

@MainActor
protocol MediaInterventionLogging: AnyObject {
    func record(_ record: MediaInterventionRecord)
}

@MainActor
final class MediaInterventionLogger: MediaInterventionLogging {
    let fileURL: URL
    let rotatedFileURL: URL
    private let maximumBytes: UInt64
    private let fileManager: FileManager

    init(
        stateDirectory: URL,
        maximumBytes: UInt64 = 5 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        fileURL = stateDirectory.appendingPathComponent("media-interventions.jsonl")
        rotatedFileURL = fileURL.appendingPathExtension("1")
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
    }

    func record(_ record: MediaInterventionRecord) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(0x0A)

            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rotateIfNeeded(adding: UInt64(data.count))
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Unable to write TTS media intervention log: %@", error.localizedDescription)
        }
    }

    private func rotateIfNeeded(adding incomingBytes: UInt64) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value + incomingBytes > maximumBytes else {
            return
        }
        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try fileManager.removeItem(at: rotatedFileURL)
        }
        try fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }
}
