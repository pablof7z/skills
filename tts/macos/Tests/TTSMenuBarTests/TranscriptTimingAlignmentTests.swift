import AppKit
import CoreFoundation
import Foundation
import Testing
@testable import TTSMenuBar

extension QueueStoreTests {
    @Test
    @MainActor
    func playbackRefreshContinuesInCommonRunLoopModes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PlaybackController(
            store: QueueStore(stateDirectory: directory),
            outputIsMuted: { false }
        )
        defer { controller.shutdown() }

        controller.start()
        let timer = try #require(controller.refreshTimer)

        #expect(CFRunLoopContainsTimer(
            CFRunLoopGetMain(),
            timer as CFRunLoopTimer,
            CFRunLoopMode.commonModes
        ))
    }

    @Test
    func compoundTimingsDoNotSkipAheadToRepeatedWords() throws {
        let text = "roughly forty-two thousand versus two hundred twenty-eight thousand events"
        let timings = [
            timing("roughly", 0, 0.3),
            timing("forty-two", 0.3, 0.7),
            timing("thousand", 0.7, 1.0),
            timing("versus", 1.0, 1.3),
            timing("two", 1.3, 1.5),
            timing("hundred", 1.5, 1.8),
            timing("twenty-eight", 1.8, 2.2),
            timing("thousand", 2.2, 2.5),
            timing("events", 2.5, 2.8),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 2.8)
        let versus = try #require(document.words.firstIndex {
            (text as NSString).substring(with: $0.range) == "versus"
        })

        #expect(document.words.allSatisfy { $0.startTime != nil })
        #expect(document.words[versus].startTime == 1.0)
        #expect(document.words.last?.startTime == 2.5)
    }

    @Test
    func phraseFocusPersistsBetweenTimingAnchors() {
        let document = TranscriptDocument.build(
            text: "First phrase. Second phrase.",
            timings: [
                timing("First", 0, 0.3),
                timing("phrase", 0.3, 0.7),
                timing("Second", 3.0, 3.3),
                timing("phrase", 3.3, 3.7),
            ],
            duration: 4
        )

        let gapState = document.playbackState(at: 2, duration: 4)
        #expect(gapState.activeWordIndex == nil)
        #expect(gapState.activePhraseIndex == 0)
        #expect(document.playbackState(at: 3.1, duration: 4).activePhraseIndex == 1)
    }

    @Test
    @MainActor
    func playbackDecorationUsesOneUniformPhraseFocus() throws {
        let textView = InteractiveTranscriptTextView()
        textView.update(
            text: "One two three",
            timings: [
                timing("One", 0, 0.3),
                timing("two", 0.3, 0.6),
                timing("three", 0.6, 0.9),
            ],
            currentTime: 0.4,
            duration: 0.9,
            accent: .systemPink,
            onSeek: { _ in }
        )
        let layoutManager = try #require(textView.layoutManager)
        let firstColor = try #require(layoutManager.temporaryAttribute(
            .backgroundColor,
            atCharacterIndex: 0,
            effectiveRange: nil
        ) as? NSColor)
        let activeColor = try #require(layoutManager.temporaryAttribute(
            .backgroundColor,
            atCharacterIndex: 4,
            effectiveRange: nil
        ) as? NSColor)

        #expect(firstColor == activeColor)
    }
}
