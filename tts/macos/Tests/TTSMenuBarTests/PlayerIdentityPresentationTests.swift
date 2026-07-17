import Testing
@testable import TTSMenuBar

struct PlayerIdentityPresentationTests {
    @Test
    func givesProjectAndAgentIndependentStableColors() throws {
        var item = item(id: "identity")
        item.workspace = "/not-a-repository/example-project"
        item.agentName = "river-codex"

        let first = PlayerIdentityPresentation.segments(for: item)
        let second = PlayerIdentityPresentation.segments(for: item)

        #expect(first == second)
        #expect(first.map(\.role) == [.project, .agent])
        #expect(first.map(\.text) == ["example-project", "river-codex"])
        #expect(
            first[0].paletteIndex
                == WorkspaceAccent.paletteIndex(forWorkspacePath: item.workspacePath)
        )
        #expect(
            first[1].paletteIndex
                == WorkspaceAccent.paletteIndex(forAgentName: "river-codex")
        )
        #expect(first[0].paletteIndex != first[1].paletteIndex)
    }

    @Test
    func distinctAgentNamesDoNotCollapseToOneColor() {
        let river = WorkspaceAccent.paletteIndex(forAgentName: "river-codex")
        let amber = WorkspaceAccent.paletteIndex(forAgentName: "amber-codex")

        #expect(river != amber)
        #expect(river == WorkspaceAccent.paletteIndex(forAgentName: "river-codex"))
    }

    @Test
    func keepsAgentColorWhenProjectIsUnavailable() throws {
        var item = item(id: "agent-only")
        item.workspace = nil
        item.agentName = "river-codex"

        let segment = try #require(PlayerIdentityPresentation.segments(for: item).only)

        #expect(segment.role == .agent)
        #expect(segment.text == "river-codex")
        #expect(
            segment.paletteIndex
                == WorkspaceAccent.paletteIndex(forAgentName: "river-codex")
        )
    }

    @Test
    func qualifiesOnlyMCPAgentIdentityWithCallerSession() throws {
        var item = item(id: "mcp-session")
        item.agentName = "ChatGPT"
        item.harness = "mcp"
        item.sessionID = "v1/3ZsbJ-first-o2UX"

        let segment = try #require(PlayerIdentityPresentation.segments(for: item).only)

        #expect(segment.text == "ChatGPT · 3ZsbJ…o2UX")
    }

    private func item(id: String) -> TTSItem {
        TTSItem(
            id: id,
            text: "A useful spoken update",
            subject: "A useful spoken update subject",
            agentName: "river-codex",
            harness: "codex",
            sessionID: "thread-123",
            workspace: nil,
            voice: "af_bella",
            outputFile: "/tmp/speech.mp3",
            status: .queued,
            createdAt: 10,
            startedAt: nil,
            completedAt: nil,
            duration: nil,
            error: nil
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
