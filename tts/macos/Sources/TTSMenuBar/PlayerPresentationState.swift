import AppKit
import Combine
import SwiftUI

@MainActor
final class NowSpeakingPresentation: ObservableObject {
    @Published private(set) var isHovered = false
    @Published var lingeringItem: TTSItem?
    @Published var lingeringTime: TimeInterval = 0
    @Published var lingeringDuration: TimeInterval = 0
    @Published var selectedAttachmentID: String?
    @Published private(set) var selectedAttachmentText: String?
    @Published private(set) var selectedAttachmentImage: NSImage?
    @Published var historyEntityFilters = HistoryEntityFilters()
    @Published var historySearchQuery = ""
    @Published var historyAgeFilter: HistoryAgeFilter = .default
    @Published private(set) var hasInteractedWithHistory = false
    @Published var isHistorySearchVisible = false
    @Published var isViewingArchive = false
    @Published private(set) var pendingPreviewItem: TTSItem?
    @Published private(set) var hiddenItemID: String?
    private var hoverExitTask: Task<Void, Never>?

    func updateHover(_ hovering: Bool) {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        if hovering {
            isHovered = true
            return
        }

        hoverExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            hoverExitTask = nil
            isHovered = false
        }
    }

    func clearHover() {
        hoverExitTask?.cancel()
        hoverExitTask = nil
        isHovered = false
    }

    func selectAttachment(
        _ attachmentID: String?,
        text: String? = nil,
        image: NSImage? = nil
    ) {
        selectedAttachmentID = attachmentID
        selectedAttachmentText = attachmentID == nil ? nil : text
        selectedAttachmentImage = attachmentID == nil ? nil : image
    }

    func previewPendingItem(_ item: TTSItem) {
        hiddenItemID = nil
        pendingPreviewItem = item
        selectAttachment(nil)
    }

    func revealForDirectSelection(itemID _: String) {
        hiddenItemID = nil
        pendingPreviewItem = nil
        selectAttachment(nil)
    }

    func revealAutomatically(itemID: String) {
        hiddenItemID = PlayerNavigationPolicy.hiddenItemID(
            afterAutomaticallySelecting: itemID,
            currentlyHidden: hiddenItemID
        )
    }

    func showHistory(hiding itemID: String?) {
        hiddenItemID = itemID
        selectAttachment(nil)
    }

    func registerHistoryInteraction() {
        hasInteractedWithHistory = true
    }

    func toggleHistoryProject(_ project: String) {
        registerHistoryInteraction()
        historyEntityFilters.toggle(project: project)
    }

    func toggleHistoryAgent(_ agent: HistoryAgentFilter) {
        registerHistoryInteraction()
        historyEntityFilters.toggle(agent: agent)
    }

    func retainAvailableHistoryFilters(
        projects: Set<String>,
        agents: Set<HistoryAgentFilter>
    ) {
        var retained = historyEntityFilters
        retained.projects.formIntersection(projects)
        retained.agents.formIntersection(agents)
        if retained != historyEntityFilters { historyEntityFilters = retained }
    }

    func showHistorySearch() {
        isHistorySearchVisible = true
        registerHistoryInteraction()
    }

    func hideHistorySearch() {
        historySearchQuery = ""
        isHistorySearchVisible = false
    }

    func updatePendingPreview(with item: TTSItem?) {
        guard let preview = pendingPreviewItem else { return }
        guard let item, item.id == preview.id else {
            pendingPreviewItem = nil
            return
        }
        pendingPreviewItem = item
    }

    func clearPendingPreview() {
        pendingPreviewItem = nil
    }
}

enum PendingQuestionRetention {
    static func retainedItem(
        currentItem: TTSItem?,
        lingeringItem: TTSItem?,
        lastCurrentItem: TTSItem?
    ) -> TTSItem? {
        [currentItem, lingeringItem, lastCurrentItem]
            .compactMap { $0 }
            .first(where: \.isPendingQuestion)
    }

    static func shouldRetain(lastCurrentItem: TTSItem?, lingeringItem: TTSItem?) -> Bool {
        retainedItem(
            currentItem: nil,
            lingeringItem: lingeringItem,
            lastCurrentItem: lastCurrentItem
        ) != nil
    }
}

enum PlayerNavigationPolicy {
    static func shouldDisplay(itemID: String?, hiddenItemID: String?) -> Bool {
        itemID != nil && itemID != hiddenItemID
    }

    static func shouldShowMiniPlayer(currentItemID: String?, hiddenItemID: String?) -> Bool {
        guard let currentItemID else { return false }
        return currentItemID == hiddenItemID
    }

    static func hiddenItemID(
        afterAutomaticallySelecting itemID: String,
        currentlyHidden hiddenItemID: String?
    ) -> String? {
        hiddenItemID == itemID ? hiddenItemID : nil
    }
}

enum PlayerHistoryToolbarPolicy {
    static let toolbarIdentifier = NSToolbar.Identifier("TTSHistoryToolbar")
    static let backItemIdentifier = NSToolbarItem.Identifier("TTSHistoryBack")
    static let filterItemIdentifier = NSToolbarItem.Identifier("TTSHistoryProjectFilter")
    static let bulkArchiveItemIdentifier = NSToolbarItem.Identifier("TTSHistoryBulkArchive")
    static let searchButtonItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearchButton")
    static let searchFieldItemIdentifier = NSToolbarItem.Identifier("TTSHistorySearchField")

    static let rootItemIdentifiers: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        searchButtonItemIdentifier,
        filterItemIdentifier,
        bulkArchiveItemIdentifier,
    ]

    static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = [
        backItemIdentifier,
        .flexibleSpace,
        searchButtonItemIdentifier,
        searchFieldItemIdentifier,
        filterItemIdentifier,
        bulkArchiveItemIdentifier,
    ]
}

enum PlayerHoverContinuation {
    static func shouldRetainCurrentContent(
        isHovered: Bool,
        isGracePeriodActive: Bool,
        hasCurrentContent: Bool
    ) -> Bool {
        hasCurrentContent && (isHovered || isGracePeriodActive)
    }
}

enum QuestionAudioReview {
    static func canReplay(
        _ item: TTSItem,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> Bool {
        item.isQuestion
            && item.status != .generating
            && fileExists(item.outputFile)
    }
}
