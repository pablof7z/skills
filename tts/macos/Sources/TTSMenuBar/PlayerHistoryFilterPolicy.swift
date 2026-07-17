import Foundation

enum HistoryAgeFilter: CaseIterable, Equatable {
    case oneHour
    case fourHours
    case today

    static let `default` = Self.today

    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .today: "Today"
        }
    }

    func cutoff(at now: Date, calendar: Calendar) -> Date {
        switch self {
        case .oneHour:
            now.addingTimeInterval(-3_600)
        case .fourHours:
            now.addingTimeInterval(-14_400)
        case .today:
            calendar.startOfDay(for: now)
        }
    }
}

enum PlayerHistoryFilterPolicy {
    static func filteredItems(
        in items: [TTSItem],
        entityFilters: HistoryEntityFilters,
        ageFilter: HistoryAgeFilter,
        hasInteractedWithHistory: Bool,
        searchQuery: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [TTSItem] {
        items.filter {
            includes(
                $0,
                ageFilter: ageFilter,
                hasInteractedWithHistory: hasInteractedWithHistory,
                now: now,
                calendar: calendar
            )
                && entityFilters.matches($0)
                && matchesSearch($0, query: searchQuery)
        }
    }

    static func availableProjects(
        in items: [TTSItem],
        ageFilter: HistoryAgeFilter,
        hasInteractedWithHistory: Bool,
        searchQuery: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [String] {
        Array(Set(filteredItems(
            in: items,
            entityFilters: HistoryEntityFilters(),
            ageFilter: ageFilter,
            hasInteractedWithHistory: hasInteractedWithHistory,
            searchQuery: searchQuery,
            now: now,
            calendar: calendar
        ).compactMap(\.workspaceName))).sorted()
    }

    static func availableAgents(
        in items: [TTSItem],
        ageFilter: HistoryAgeFilter,
        hasInteractedWithHistory: Bool,
        searchQuery: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [HistoryAgentFilter] {
        Array(Set(filteredItems(
            in: items,
            entityFilters: HistoryEntityFilters(),
            ageFilter: ageFilter,
            hasInteractedWithHistory: hasInteractedWithHistory,
            searchQuery: searchQuery,
            now: now,
            calendar: calendar
        ).map(\.historyAgentFilter))).sorted { $0.displayName < $1.displayName }
    }

    private static func includes(
        _ item: TTSItem,
        ageFilter: HistoryAgeFilter,
        hasInteractedWithHistory: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard !item.unheard, !item.isPendingQuestion, !item.status.isPending,
              item.status != .generating, item.status != .playing, item.status != .paused
        else {
            return true
        }

        guard item.createdDate >= ageFilter.cutoff(at: now, calendar: calendar) else {
            return false
        }

        return ageFilter != .today
            || !hasInteractedWithHistory
            || item.createdDate >= now.addingTimeInterval(-14_400)
    }

    private static func matchesSearch(_ item: TTSItem, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [
            item.nowSpeakingTitle,
            item.previewSummary,
            item.text,
            item.displayAgent,
            item.historyAgentFilter.displayName,
            item.workspaceName,
        ]
            .compactMap(\.self)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
