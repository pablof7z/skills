import Foundation

struct HistoryAgentFilter: Hashable, Identifiable {
    let agentName: String
    let sessionID: String?

    var id: String { "\(agentName)\u{1F}\(sessionID ?? "")" }

    var displayName: String {
        guard let sessionID else { return agentName }
        let value = sessionID.split(separator: "/").last.map(String.init) ?? sessionID
        guard value.count > 10 else { return "\(agentName) · \(value)" }
        return "\(agentName) · \(value.prefix(5))…\(value.suffix(4))"
    }
}

struct HistoryEntityFilters: Equatable {
    var projects: Set<String> = []
    var agents: Set<HistoryAgentFilter> = []

    var activeCount: Int { projects.count + agents.count }
    var isEmpty: Bool { projects.isEmpty && agents.isEmpty }

    func matches(_ item: TTSItem) -> Bool {
        isEmpty
            || item.workspaceName.map(projects.contains) == true
            || agents.contains(item.historyAgentFilter)
    }

    mutating func toggle(project: String) {
        if projects.remove(project) == nil { projects.insert(project) }
    }

    mutating func toggle(agent: HistoryAgentFilter) {
        if agents.remove(agent) == nil { agents.insert(agent) }
    }
}

extension TTSItem {
    var historyAgentFilter: HistoryAgentFilter {
        HistoryAgentFilter(agentName: displayAgent, sessionID: sessionLabel)
    }
}
