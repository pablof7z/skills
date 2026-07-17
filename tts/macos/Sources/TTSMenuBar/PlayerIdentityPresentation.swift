import SwiftUI

struct PlayerIdentitySegment: Equatable, Identifiable {
    enum Role: Equatable {
        case project
        case agent

        var title: String {
            switch self {
            case .project: "Project"
            case .agent: "Agent"
            }
        }
    }

    let role: Role
    let text: String
    let paletteIndex: Int

    var id: String { "\(role)-\(text)" }

    var color: Color {
        WorkspaceAccent.color(forPaletteIndex: paletteIndex)
    }
}

enum PlayerIdentityPresentation {
    static func segments(for item: TTSItem) -> [PlayerIdentitySegment] {
        let project = item.workspaceName.map {
            PlayerIdentitySegment(
                role: .project,
                text: $0,
                paletteIndex: WorkspaceAccent.paletteIndex(forWorkspacePath: item.workspacePath)
            )
        }
        let agent = PlayerIdentitySegment(
            role: .agent,
            text: item.historyAgentFilter.displayName,
            paletteIndex: WorkspaceAccent.paletteIndex(forAgentName: item.displayAgent)
        )
        return [project, agent].compactMap { $0 }
    }
}
