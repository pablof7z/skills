import Foundation
import SwiftUI

struct WorkspaceIdentity: Equatable {
    let project: String
    let worktree: String?
    let display: String
}

enum WorkspaceAccent {
    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.67, blue: 1.00),
        Color(red: 0.28, green: 0.84, blue: 0.77),
        Color(red: 0.68, green: 0.56, blue: 1.00),
        Color(red: 1.00, green: 0.75, blue: 0.34),
        Color(red: 1.00, green: 0.51, blue: 0.44),
        Color(red: 0.43, green: 0.84, blue: 0.55),
        Color(red: 0.96, green: 0.55, blue: 0.78),
        Color(red: 0.45, green: 0.72, blue: 0.94),
    ]

    static var count: Int { palette.count }

    static func color(forWorkspacePath path: String?) -> Color {
        palette[paletteIndex(forWorkspacePath: path)]
    }

    static func paletteIndex(forWorkspacePath path: String?) -> Int {
        let label = projectLabel(forWorkspacePath: path)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in label.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(palette.count))
    }

    static func projectLabel(forWorkspacePath path: String?) -> String {
        identity(forWorkspacePath: path)?.project ?? "unknown"
    }

    static func displayLabel(forWorkspacePath path: String?) -> String? {
        identity(forWorkspacePath: path)?.display
    }

    static func worktreeLabel(forWorkspacePath path: String?) -> String? {
        identity(forWorkspacePath: path)?.worktree
    }

    static func identity(
        forWorkspacePath path: String?,
        fileManager: FileManager = .default
    ) -> WorkspaceIdentity? {
        guard let workspaceURL = workspaceURL(for: path) else { return nil }
        if let projectRoot = nearestGitRoot(from: workspaceURL, fileManager: fileManager) {
            let checkout = projectRoot.lastPathComponent
            let project = commonProjectName(forGitRoot: projectRoot, fileManager: fileManager) ?? checkout
            return WorkspaceIdentity(
                project: project,
                worktree: project == checkout ? nil : checkout,
                display: project
            )
        }
        return WorkspaceIdentity(
            project: workspaceURL.lastPathComponent,
            worktree: nil,
            display: path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? workspaceURL.path
        )
    }

    static func nearestGitRoot(
        from workspaceURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidate = workspaceURL.standardizedFileURL
        while true {
            let marker = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: marker.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    private static func workspaceURL(for path: String?) -> URL? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    private static func commonProjectName(
        forGitRoot root: URL,
        fileManager: FileManager
    ) -> String? {
        let marker = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return root.lastPathComponent }

        guard let markerText = try? String(contentsOf: marker, encoding: .utf8),
              let gitdirLine = markerText.split(whereSeparator: \.isNewline).first,
              gitdirLine.lowercased().hasPrefix("gitdir:") else { return nil }
        let rawGitDirectory = gitdirLine.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawGitDirectory.isEmpty else { return nil }
        let gitDirectory = resolvedURL(rawGitDirectory, relativeTo: root)

        let commonDirectory: URL
        let commonMarker = gitDirectory.appendingPathComponent("commondir")
        if let commonText = try? String(contentsOf: commonMarker, encoding: .utf8) {
            let rawCommon = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
            commonDirectory = resolvedURL(rawCommon, relativeTo: gitDirectory)
        } else if gitDirectory.deletingLastPathComponent().lastPathComponent == "worktrees" {
            commonDirectory = gitDirectory.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            commonDirectory = gitDirectory
        }

        if commonDirectory.lastPathComponent == ".git" {
            return commonDirectory.deletingLastPathComponent().lastPathComponent
        }
        let name = commonDirectory.lastPathComponent
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    private static func resolvedURL(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return base.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

struct LingerCountdown: Equatable {
    let duration: TimeInterval
    private(set) var remaining: TimeInterval
    private(set) var deadline: TimeInterval?

    init(duration: TimeInterval) {
        self.duration = duration
        remaining = duration
    }

    mutating func start(at time: TimeInterval) {
        remaining = duration
        deadline = time + duration
    }

    mutating func pause(at time: TimeInterval) {
        guard let deadline else { return }
        remaining = max(0, deadline - time)
        self.deadline = nil
    }

    mutating func resume(at time: TimeInterval) {
        guard deadline == nil else { return }
        deadline = time + remaining
    }

    mutating func cancel() {
        remaining = duration
        deadline = nil
    }

    func timeRemaining(at time: TimeInterval) -> TimeInterval {
        guard let deadline else { return remaining }
        return max(0, deadline - time)
    }
}

enum HUDLayoutUpdate {
    static func isNeeded(
        currentFrame: CGRect,
        targetFrame: CGRect,
        currentAlpha: CGFloat,
        targetAlpha: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        !currentFrame.equalTo(targetFrame) || abs(currentAlpha - targetAlpha) > tolerance
    }
}
