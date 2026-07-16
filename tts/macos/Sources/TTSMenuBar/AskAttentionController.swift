import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications

enum AskDockAttentionMode: String, Codable, CaseIterable, Identifiable {
    case off
    case once
    case repeated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .once: "Once"
        case .repeated: "Every"
        }
    }
}

final class AskNotificationCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("Unable to request TTS notification permission: %@", error.localizedDescription)
            }
        }
    }

    func deliver(for item: TTSItem) {
        let identifier = "tts-ask-\(item.id)"
        let title = "Question from \(item.displayAgent)"
        let body = item.subjectLabel ?? item.text
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) {
                error in
                if let error {
                    NSLog("Unable to deliver TTS ask notification: %@", error.localizedDescription)
                }
            }
        }
    }
}

@MainActor
final class AskAttentionController {
    typealias AttentionRequester = () -> Int
    typealias AttentionCanceller = (Int) -> Void
    typealias NotificationAuthorizer = () -> Void
    typealias NotificationDeliverer = (TTSItem) -> Void

    private let playbackController: PlaybackController
    private let preferencesStore: PlayerPreferencesStore
    private let requestAttention: AttentionRequester
    private let cancelAttention: AttentionCanceller
    private let authorizeNotifications: NotificationAuthorizer
    private let deliverNotification: NotificationDeliverer
    private let intervalSeconds: (Int) -> TimeInterval
    private var itemsObservation: AnyCancellable?
    private var preferencesObservation: AnyCancellable?
    private var seenItemIDs = Set<String>()
    private var pendingQuestionIDs = Set<String>()
    private var activeAttentionRequestID: Int?
    private var repeatingTask: Task<Void, Never>?
    private var notificationsWereEnabled = false

    init(
        playbackController: PlaybackController,
        preferencesStore: PlayerPreferencesStore,
        requestAttention: @escaping AttentionRequester = {
            NSApp.isActive ? 0 : NSApp.requestUserAttention(.informationalRequest)
        },
        cancelAttention: @escaping AttentionCanceller = { requestID in
            guard requestID != 0 else { return }
            NSApp.cancelUserAttentionRequest(requestID)
        },
        authorizeNotifications: @escaping NotificationAuthorizer,
        deliverNotification: @escaping NotificationDeliverer,
        intervalSeconds: @escaping (Int) -> TimeInterval = { TimeInterval($0 * 60) }
    ) {
        self.playbackController = playbackController
        self.preferencesStore = preferencesStore
        self.requestAttention = requestAttention
        self.cancelAttention = cancelAttention
        self.authorizeNotifications = authorizeNotifications
        self.deliverNotification = deliverNotification
        self.intervalSeconds = intervalSeconds
    }

    func start() {
        guard itemsObservation == nil else { return }
        seenItemIDs = Set(playbackController.items.map(\.id))
        pendingQuestionIDs = Set(playbackController.items.filter(\.isPendingQuestion).map(\.id))
        notificationsWereEnabled = preferencesStore.preferences.sendsAskNotifications
        itemsObservation = playbackController.$items.dropFirst().sink { [weak self] items in
            self?.itemsDidChange(items)
        }
        preferencesObservation = preferencesStore.$preferences.dropFirst().sink { [weak self] preferences in
            self?.preferencesDidChange(preferences)
        }
        updateRepeatingAttention(restart: true)
    }

    func stop() {
        itemsObservation?.cancel()
        itemsObservation = nil
        preferencesObservation?.cancel()
        preferencesObservation = nil
        stopRepeatingAttention()
        cancelActiveAttentionRequest()
    }

    private func itemsDidChange(_ items: [TTSItem]) {
        let newQuestions = items.filter { $0.isPendingQuestion && !seenItemIDs.contains($0.id) }
        seenItemIDs.formUnion(items.map(\.id))
        pendingQuestionIDs = Set(items.filter(\.isPendingQuestion).map(\.id))

        for question in newQuestions {
            if preferencesStore.preferences.sendsAskNotifications {
                deliverNotification(question)
            }
            if preferencesStore.preferences.askDockAttentionMode != .off {
                requestDockAttention()
            }
        }
        updateRepeatingAttention(restart: !newQuestions.isEmpty)
        if pendingQuestionIDs.isEmpty {
            cancelActiveAttentionRequest()
        }
    }

    private func preferencesDidChange(_ preferences: PlayerPreferences) {
        if preferences.sendsAskNotifications, !notificationsWereEnabled {
            authorizeNotifications()
        }
        notificationsWereEnabled = preferences.sendsAskNotifications
        if preferences.askDockAttentionMode == .off {
            cancelActiveAttentionRequest()
        }
        updateRepeatingAttention(restart: true)
    }

    private func requestDockAttention() {
        cancelActiveAttentionRequest()
        let requestID = requestAttention()
        activeAttentionRequestID = requestID == 0 ? nil : requestID
    }

    private func updateRepeatingAttention(restart: Bool) {
        let preferences = preferencesStore.preferences
        guard preferences.askDockAttentionMode == .repeated, !pendingQuestionIDs.isEmpty else {
            stopRepeatingAttention()
            return
        }
        guard restart || repeatingTask == nil else { return }
        stopRepeatingAttention()
        let delay = intervalSeconds(preferences.askDockAttentionIntervalMinutes)
        repeatingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(0.01, delay)))
                guard !Task.isCancelled, let self, !self.pendingQuestionIDs.isEmpty else { return }
                self.requestDockAttention()
            }
        }
    }

    private func stopRepeatingAttention() {
        repeatingTask?.cancel()
        repeatingTask = nil
    }

    private func cancelActiveAttentionRequest() {
        guard let requestID = activeAttentionRequestID else { return }
        cancelAttention(requestID)
        activeAttentionRequestID = nil
    }
}
