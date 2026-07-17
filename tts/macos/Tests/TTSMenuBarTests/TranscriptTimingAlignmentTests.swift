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
    func technicalNumberExpansionKeepsClosingPhraseAtFortySeconds() throws {
        let text = "The current all-kind-1, 128-byte corpus therefore does not represent the write semantics NMP actually sees. I am implementing issue 620 as an exact raw-frame collector plus a privacy-safe shape corpus: it will preserve kind, size, tag, and JSON-escaping costs without committing public users’ content. The next meaningful number will be production throughput on that representative mix."
        let timings = [
            timing("NMP", 0.036, 0.736), timing("Epic", 0.736, 1.123),
            timing("six", 1.123, 1.436), timing("hundred", 1.436, 1.861),
            timing("and", 1.861, 1.998), timing("twelve", 1.998, 2.736),
            timing("The", 18.548, 18.685), timing("current", 18.685, 19.085),
            timing("all-kindminus", 19.085, 20.060), timing("one", 20.060, 20.423),
            timing("one", 20.535, 20.773), timing("hundred", 20.773, 21.223),
            timing("and", 21.223, 21.348), timing("twenty-eight-byte", 21.348, 22.123),
            timing("corpus", 22.123, 22.598), timing("therefore", 22.598, 23.148),
            timing("does", 23.148, 23.348), timing("not", 23.348, 23.598),
            timing("represent", 23.598, 24.060), timing("the", 24.060, 24.185),
            timing("write", 24.185, 24.498), timing("semantics", 24.498, 25.110),
            timing("NMP", 25.110, 25.748), timing("actually", 25.748, 26.210),
            timing("sees", 26.210, 27.298), timing("I", 27.095, 27.245),
            timing("am", 27.245, 27.395), timing("implementing", 27.395, 27.970),
            timing("issue", 27.970, 28.332), timing("six", 28.332, 28.620),
            timing("hundred", 28.620, 29.020), timing("and", 29.020, 29.145),
            timing("twenty", 29.145, 29.657), timing("as", 29.657, 29.782),
            timing("an", 29.782, 29.870), timing("exact", 29.870, 30.382),
            timing("raw-frame", 30.382, 30.945), timing("collector", 30.945, 31.470),
            timing("plus", 31.470, 31.707), timing("a", 31.707, 31.795),
            timing("privacy-safe", 31.795, 32.632), timing("shape", 32.632, 32.945),
            timing("corpus", 32.945, 33.720), timing("it", 33.845, 33.932),
            timing("will", 33.932, 34.045), timing("preserve", 34.045, 34.470),
            timing("kind", 34.470, 35.070), timing("size", 35.182, 35.645),
            timing("tag", 35.732, 36.195), timing("and", 36.245, 36.382),
            timing("JSON-escaping", 36.382, 37.507), timing("costs", 37.507, 37.970),
            timing("without", 37.970, 38.320), timing("committing", 38.320, 38.745),
            timing("public", 38.745, 39.145), timing("users'", 39.145, 39.520),
            timing("content", 39.520, 40.770), timing("The", 40.401, 40.501),
            timing("next", 40.501, 40.826), timing("meaningful", 40.826, 41.301),
            timing("number", 41.301, 41.676), timing("will", 41.676, 41.801),
            timing("be", 41.801, 41.951), timing("production", 41.951, 42.488),
            timing("throughput", 42.488, 43.026), timing("on", 43.026, 43.201),
            timing("that", 43.201, 43.451), timing("representative", 43.451, 44.201),
            timing("mix", 44.201, 45.076),
        ]

        let document = TranscriptDocument.build(text: text, timings: timings, duration: 45.072)
        let source = text as NSString
        let kinds = document.words.indices.filter { source.substring(with: document.words[$0].range) == "kind" }
        let therefore = try #require(document.words.firstIndex {
            source.substring(with: $0.range) == "therefore"
        })
        let content = try #require(document.words.firstIndex {
            source.substring(with: $0.range) == "content"
        })
        let state = document.playbackState(at: 40, duration: 45.072)
        let phrase = try #require(state.activePhraseIndex.map { document.phrases[$0] })

        #expect(kinds.count == 2)
        #expect(document.words.allSatisfy { $0.startTime != nil })
        #expect(document.words[kinds[0]].startTime == 19.085)
        #expect(document.words[kinds[1]].startTime == 34.470)
        #expect(document.words[therefore].startTime == 22.598)
        #expect(state.activeWordIndex == content)
        #expect(source.substring(with: phrase.range).contains("content"))
        #expect(!source.substring(with: phrase.range).contains("kind-1"))
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
    func stalePhraseFocusExpiresAcrossUntrustedTimingGap() {
        let document = TranscriptDocument.build(
            text: "Early phrase. Much later phrase.",
            timings: [
                timing("Early", 0, 0.3),
                timing("phrase", 0.3, 0.7),
                timing("Much", 10, 10.3),
                timing("later", 10.3, 10.6),
                timing("phrase", 10.6, 10.9),
            ],
            duration: 11
        )

        #expect(document.playbackState(at: 4, duration: 11).activePhraseIndex == nil)
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
