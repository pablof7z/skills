import AVFAudio
import Foundation
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    func item(
        id: String,
        createdAt: Int64,
        outputFile: String = "/tmp/speech.mp3"
    ) -> TTSItem {
        TTSItem(
            id: id,
            text: "A useful spoken update",
            subject: "A useful spoken update subject",
            agentName: "clay-river-860",
            harness: "codex",
            sessionID: "thread-123",
            workspace: "/tmp/skills",
            voice: "af_bella",
            outputFile: outputFile,
            status: .queued,
            createdAt: createdAt,
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil
        )
    }

    func bundleItem(id: String) -> TTSItem {
        var value = item(id: id, createdAt: 10)
        value.kind = .question
        value.questionStatus = .pending
        value.questionsPreamble = "There are two details to settle before implementation."
        value.questions = [
            TTSQuestion(
                id: "q-01",
                title: "Which model?",
                shortTitle: "Model",
                suggestions: [
                    TTSSuggestion(
                        title: "Use the shared model",
                        description: "Keep one source of truth.",
                        id: "q-01-s-01"
                    ),
                ]
            ),
            TTSQuestion(
                id: "q-02",
                title: "Any caveats?",
                shortTitle: "Caveats",
                suggestions: [
                    TTSSuggestion(
                        title: "No change",
                        description: "Keep the current behavior.",
                        id: "q-02-s-01"
                    ),
                ]
            ),
        ]
        return value
    }

    @MainActor
    func disabledMediaController(stateDirectory: URL) -> MediaController {
        let preferencesStore = PlayerPreferencesStore(stateDirectory: stateDirectory)
        preferencesStore.setPausesMedia(false)
        return MediaController(preferencesStore: preferencesStore)
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-menu-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func writeSilentAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func timing(_ word: String, _ start: Double, _ end: Double) -> TTSWordTiming {
        TTSWordTiming(word: word, startTime: start, endTime: end)
    }

    func attachment() -> TTSAttachment {
        TTSAttachment(
            id: "why",
            label: "Why this matters",
            kind: .narratedText,
            status: .ready,
            sourceFile: "/tmp/why.md",
            text: "# Why this matters\n\nUseful detail.",
            audioFile: "/tmp/why.mp3",
            wordTimings: [timing("Useful", 0, 0.4)],
            error: nil
        )
    }
}

final class TestITermSessionScripting: ITermSessionScripting {
    var existingSessionIDs = Set<String>()
    var selectedSessionIDs = [String]()

    func sessionExists(uniqueID: String) -> Bool {
        existingSessionIDs.contains(uniqueID)
    }

    func selectSession(uniqueID: String) -> Bool {
        selectedSessionIDs.append(uniqueID)
        return existingSessionIDs.contains(uniqueID)
    }
}
