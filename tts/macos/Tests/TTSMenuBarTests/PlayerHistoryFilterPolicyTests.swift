import Foundation
import Testing
@testable import TTSMenuBar

@Suite
struct PlayerHistoryFilterPolicyTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_784_219_600)

    @Test
    func defaultFilterHidesYesterdayAndAgesOutSeenItemsAfterInteraction() {
        let recent = item(id: "recent", createdAt: now.addingTimeInterval(-3_600))
        let stale = item(id: "stale", createdAt: now.addingTimeInterval(-18_000))
        let yesterday = item(id: "yesterday", createdAt: now.addingTimeInterval(-86_400))

        let beforeInteraction = PlayerHistoryFilterPolicy.filteredItems(
            in: [recent, stale, yesterday],
            project: nil,
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "",
            now: now,
            calendar: calendar
        )
        #expect(beforeInteraction.map(\.id) == ["recent", "stale"])

        let afterInteraction = PlayerHistoryFilterPolicy.filteredItems(
            in: [recent, stale, yesterday],
            project: nil,
            ageFilter: .today,
            hasInteractedWithHistory: true,
            searchQuery: "",
            now: now,
            calendar: calendar
        )
        #expect(afterInteraction.map(\.id) == ["recent"])
    }

    @Test
    func keepsUnreadItemsAndLimitsProjectsToTheCurrentFilters() {
        var unread = item(id: "unread", createdAt: now.addingTimeInterval(-86_400), workspace: "/tmp/unread")
        unread.isUnheard = true
        let matching = item(id: "matching", createdAt: now.addingTimeInterval(-3_600), workspace: "/tmp/matching")
        let hidden = item(id: "hidden", createdAt: now.addingTimeInterval(-18_000), workspace: "/tmp/hidden")

        let projects = PlayerHistoryFilterPolicy.availableProjects(
            in: [unread, matching, hidden],
            ageFilter: .fourHours,
            hasInteractedWithHistory: true,
            searchQuery: "",
            now: now,
            calendar: calendar
        )
        #expect(projects == ["matching", "unread"])
    }

    @Test
    func searchFieldIsOnlyAllowedAfterTheSearchButtonIsOpened() {
        #expect(PlayerHistoryToolbarPolicy.rootItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.searchButtonItemIdentifier
        ))
        #expect(!PlayerHistoryToolbarPolicy.rootItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.searchFieldItemIdentifier
        ))
        #expect(PlayerHistoryToolbarPolicy.allowedItemIdentifiers.contains(
            PlayerHistoryToolbarPolicy.searchFieldItemIdentifier
        ))
    }

    private func item(id: String, createdAt: Date, workspace: String = "/tmp/current") -> TTSItem {
        TTSItem(
            id: id,
            text: id,
            subject: nil,
            agentName: "Codex",
            harness: "codex",
            sessionID: nil,
            workspace: workspace,
            voice: "af_bella",
            outputFile: "/tmp/\(id).mp3",
            status: .played,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil
        )
    }
}
