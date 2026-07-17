import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct MediaInterventionLoggerTests {
    @Test
    func writesReadableJSONLinesWithoutTrackMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = MediaInterventionLogger(stateDirectory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_784_276_577)

        logger.record(MediaInterventionRecord(
            timestamp: timestamp,
            event: "state_verified",
            generation: 7,
            itemID: "speech-123",
            leaseID: UUID(uuidString: "8EACD8AA-E81B-42CC-8E47-5A941BFB2F4A"),
            backend: "AppleScript",
            session: MediaInterventionSession(MediaSessionSnapshot(
                bundleIdentifier: "com.apple.Music",
                processIdentifier: 42,
                contentIdentifier: "track-123",
                title: "Private title",
                artist: "Private artist",
                album: "Private album",
                isPlaying: false
            )),
            desiredPlaying: false,
            attempt: 2
        ))

        let data = try Data(contentsOf: logger.fileURL)
        let line = try #require(String(data: data, encoding: .utf8))
        #expect(line.hasSuffix("\n"))
        #expect(!line.contains("Private title"))
        #expect(!line.contains("Private artist"))
        #expect(!line.contains("Private album"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MediaInterventionRecord.self, from: data.dropLast())
        #expect(record.timestamp == timestamp)
        #expect(record.itemID == "speech-123")
        #expect(record.session?.bundleIdentifier == "com.apple.Music")
        #expect(record.session?.contentIdentifier == "track-123")
        #expect(record.attempt == 2)
    }

    @Test
    func rotatesTheCurrentLogBeforeItGrowsPastTheBound() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = MediaInterventionLogger(stateDirectory: directory, maximumBytes: 1)

        logger.record(MediaInterventionRecord(event: "first", generation: 1))
        logger.record(MediaInterventionRecord(event: "second", generation: 2))

        #expect(FileManager.default.fileExists(atPath: logger.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: logger.rotatedFileURL.path))
        let current = try? String(contentsOf: logger.fileURL, encoding: .utf8)
        let rotated = try? String(contentsOf: logger.rotatedFileURL, encoding: .utf8)
        #expect(current?.contains("\"event\":\"second\"") == true)
        #expect(rotated?.contains("\"event\":\"first\"") == true)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("media-intervention-logger-tests-\(UUID().uuidString)")
    }
}
