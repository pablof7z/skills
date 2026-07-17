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
            entityFilters: HistoryEntityFilters(),
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "",
            now: now,
            calendar: calendar
        )
        #expect(beforeInteraction.map(\.id) == ["recent", "stale"])

        let afterInteraction = PlayerHistoryFilterPolicy.filteredItems(
            in: [recent, stale, yesterday],
            entityFilters: HistoryEntityFilters(),
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

    @Test
    func searchMatchesPreviewSummary() {
        var matching = item(id: "matching", createdAt: now)
        matching.summary = "Hosted audio generation succeeds through MCP."
        let hidden = item(id: "hidden", createdAt: now)

        let results = PlayerHistoryFilterPolicy.filteredItems(
            in: [matching, hidden],
            entityFilters: HistoryEntityFilters(),
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "hosted audio",
            now: now,
            calendar: calendar
        )

        #expect(results.map(\.id) == ["matching"])
    }

    @Test
    func combinesSelectedProjectsAndAgentsAsOneInclusiveUnion() {
        let alpha = item(id: "alpha", createdAt: now, workspace: "/tmp/alpha")
        let beta = item(id: "beta", createdAt: now, workspace: "/tmp/beta")
        let river = item(
            id: "river",
            createdAt: now,
            workspace: "/tmp/other",
            agentName: "ChatGPT",
            sessionID: "v1/river-session"
        )
        let hidden = item(id: "hidden", createdAt: now, workspace: "/tmp/hidden")
        let filters = HistoryEntityFilters(
            projects: ["alpha", "beta"],
            agents: [river.historyAgentFilter]
        )

        let results = PlayerHistoryFilterPolicy.filteredItems(
            in: [alpha, beta, river, hidden],
            entityFilters: filters,
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "",
            now: now,
            calendar: calendar
        )

        #expect(results.map(\.id) == ["alpha", "beta", "river"])
        #expect(filters.activeCount == 3)
    }

    @Test
    func exposesChatGPTSessionsAsDistinctAgentChoices() {
        let first = item(
            id: "first",
            createdAt: now,
            agentName: "ChatGPT",
            sessionID: "v1/3ZsbJ-first-o2UX"
        )
        let second = item(
            id: "second",
            createdAt: now,
            agentName: "ChatGPT",
            sessionID: "v1/9Kabc-second-r7PQ"
        )

        let agents = PlayerHistoryFilterPolicy.availableAgents(
            in: [first, second],
            ageFilter: .today,
            hasInteractedWithHistory: false,
            searchQuery: "",
            now: now,
            calendar: calendar
        )

        #expect(Set(agents) == [first.historyAgentFilter, second.historyAgentFilter])
        #expect(Set(agents.map(\.displayName)).count == 2)
        #expect(first.historyAgentFilter.displayName == "ChatGPT · 3ZsbJ…o2UX")
    }

    @Test
    func togglesEntityFiltersWithoutReplacingOtherSelections() {
        let agent = HistoryAgentFilter(agentName: "ChatGPT", sessionID: "v1/session-one")
        var filters = HistoryEntityFilters()

        filters.toggle(project: "alpha")
        filters.toggle(project: "beta")
        filters.toggle(agent: agent)
        #expect(filters.projects == ["alpha", "beta"])
        #expect(filters.agents == [agent])

        filters.toggle(project: "alpha")
        #expect(filters.projects == ["beta"])
        #expect(filters.agents == [agent])
    }

    private func item(
        id: String,
        createdAt: Date,
        workspace: String = "/tmp/current",
        agentName: String = "Codex",
        sessionID: String? = nil
    ) -> TTSItem {
        TTSItem(
            id: id,
            text: id,
            subject: nil,
            agentName: agentName,
            harness: "codex",
            sessionID: sessionID,
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
