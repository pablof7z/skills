import Foundation
import Testing
@testable import TTSMenuBar

@Suite @MainActor
struct AskAttentionTests {
    @Test
    func newAskUsesConfiguredDockAndNotificationAttention() {
        let context = makeContext()
        defer { context.cleanup() }
        var dockRequests = 0
        var notificationRequests = 0
        var authorizationRequests = 0
        let attention = AskAttentionController(
            playbackController: context.controller,
            preferencesStore: context.preferences,
            requestAttention: {
                dockRequests += 1
                return dockRequests
            },
            cancelAttention: { _ in },
            authorizeNotifications: { authorizationRequests += 1 },
            deliverNotification: { _ in notificationRequests += 1 }
        )
        attention.start()
        defer { attention.stop() }

        context.controller.items = [pendingQuestion(id: "first")]
        #expect(dockRequests == 1)
        #expect(notificationRequests == 0)

        context.preferences.setSendsAskNotifications(true)
        #expect(authorizationRequests == 1)
        context.controller.items.append(pendingQuestion(id: "second"))
        #expect(dockRequests == 2)
        #expect(notificationRequests == 1)

        context.preferences.setAskDockAttentionMode(.off)
        context.controller.items.append(pendingQuestion(id: "third"))
        #expect(dockRequests == 2)
        #expect(notificationRequests == 2)
    }

    @Test
    func repeatingAttentionStopsWhenNoAskIsPending() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        context.preferences.setAskDockAttentionMode(.repeated)
        var dockRequests = 0
        let attention = AskAttentionController(
            playbackController: context.controller,
            preferencesStore: context.preferences,
            requestAttention: {
                dockRequests += 1
                return dockRequests
            },
            cancelAttention: { _ in },
            authorizeNotifications: {},
            deliverNotification: { _ in },
            intervalSeconds: { _ in 0.01 }
        )
        attention.start()
        defer { attention.stop() }

        context.controller.items = [pendingQuestion(id: "repeating")]
        try await waitUntil { dockRequests >= 2 }

        context.controller.items[0].questionStatus = .answered
        let stoppedAt = dockRequests
        try await Task.sleep(for: .milliseconds(30))
        #expect(dockRequests == stoppedAt)
    }

    @Test
    func existingAskDoesNotAlertAgainWhenTheAppStarts() {
        let context = makeContext()
        defer { context.cleanup() }
        context.controller.items = [pendingQuestion(id: "existing")]
        var dockRequests = 0
        let attention = AskAttentionController(
            playbackController: context.controller,
            preferencesStore: context.preferences,
            requestAttention: {
                dockRequests += 1
                return dockRequests
            },
            cancelAttention: { _ in },
            authorizeNotifications: {},
            deliverNotification: { _ in }
        )

        attention.start()
        defer { attention.stop() }

        #expect(dockRequests == 0)
    }

    @Test
    func completedVisibleAskHoldsSpeechQueueUntilItCloses() throws {
        let context = makeContext(outputIsMuted: false)
        defer { context.cleanup() }
        let (question, next) = try prepareQuestionQueue(in: context)
        context.controller.setVisibleAskQueueHold(question.id)

        context.controller.finishCurrent(success: true, error: nil)
        context.controller.refresh()

        #expect(context.controller.currentItem == nil)
        #expect(context.controller.visibleAskQueueHoldID == question.id)

        context.controller.setVisibleAskQueueHold(nil)

        #expect(context.controller.visibleAskQueueHoldID == nil)
        #expect(context.controller.currentItem?.id == next.id)
    }

    @Test
    func completedAskInHistoryDoesNotHoldSpeechQueue() throws {
        let context = makeContext(outputIsMuted: false)
        defer { context.cleanup() }
        let (_, next) = try prepareQuestionQueue(in: context)

        context.controller.finishCurrent(success: true, error: nil)

        #expect(context.controller.visibleAskQueueHoldID == nil)
        #expect(context.controller.currentItem?.id == next.id)
    }

    @Test
    func legacyPreferencesReceiveNonRepeatingAttentionDefaults() throws {
        let data = Data(#"{"pausesMedia":false,"mediaHandoffDelay":2,"mediaResumeDelay":3}"#.utf8)
        let preferences = try JSONDecoder().decode(PlayerPreferences.self, from: data)

        #expect(preferences.askDockAttentionMode == .once)
        #expect(preferences.askDockAttentionIntervalMinutes == 5)
        #expect(!preferences.sendsAskNotifications)
    }

    private func pendingQuestion(id: String) -> TTSItem {
        var item = QueueStoreTests().item(id: id, createdAt: 10)
        item.kind = .question
        item.questionStatus = .pending
        return item
    }

    private func prepareQuestionQueue(in context: TestContext) throws -> (TTSItem, TTSItem) {
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        let questionAudio = context.directory.appendingPathComponent("question.caf")
        let nextAudio = context.directory.appendingPathComponent("next.caf")
        try writeSilentAudio(to: questionAudio)
        try writeSilentAudio(to: nextAudio)
        var question = pendingQuestion(id: "question")
        question.outputFile = questionAudio.path
        question.status = .playing
        let next = QueueStoreTests().item(id: "next", createdAt: 20, outputFile: nextAudio.path)
        try context.controller.store.save(question)
        try context.controller.store.save(next)
        try context.controller.store.admitPlayback(of: next.id, requestedAtNanoseconds: 20)
        context.controller.items = [question, next]
        context.controller.currentItemID = question.id
        return (question, next)
    }

    private func makeContext(outputIsMuted: Bool = true) -> TestContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-attention-tests-\(UUID().uuidString)")
        let preferences = PlayerPreferencesStore(stateDirectory: directory)
        let controller = PlaybackController(
            store: QueueStore(stateDirectory: directory),
            mediaController: MediaController(preferencesStore: preferences),
            outputIsMuted: { outputIsMuted }
        )
        return TestContext(directory: directory, preferences: preferences, controller: controller)
    }

    private func writeSilentAudio(to url: URL) throws {
        try QueueStoreTests().writeSilentAudio(to: url)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition did not become true before timeout.")
    }
}

@MainActor
private struct TestContext {
    let directory: URL
    let preferences: PlayerPreferencesStore
    let controller: PlaybackController

    func cleanup() {
        controller.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
