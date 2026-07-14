import AppKit
import Combine
import Foundation

struct AgentSessionTarget: Equatable {
    let uniqueID: String

    init?(rawIdentifier: String?) {
        guard let rawIdentifier else { return nil }
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let candidate = trimmed.split(separator: ":").last,
              let uuid = UUID(uuidString: String(candidate)) else { return nil }
        uniqueID = uuid.uuidString
    }
}

protocol ITermSessionScripting {
    func sessionExists(uniqueID: String) -> Bool
    func selectSession(uniqueID: String) -> Bool
}

struct AppleScriptITermSessionScripting: ITermSessionScripting {
    private static let bundleIdentifier = "com.googlecode.iterm2"

    func sessionExists(uniqueID: String) -> Bool {
        runScript(uniqueID: uniqueID, select: false)
    }

    func selectSession(uniqueID: String) -> Bool {
        runScript(uniqueID: uniqueID, select: true)
    }

    private func runScript(uniqueID: String, select: Bool) -> Bool {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).isEmpty else { return false }

        let selectionCommands = select
            ? """
                        select targetSession
                        select targetTab
                        select targetWindow
                        activate
              """
            : ""
        let source = """
            tell application id "\(Self.bundleIdentifier)"
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetSession in sessions of targetTab
                            if unique ID of targetSession is "\(uniqueID)" then
            \(selectionCommands)
                                return "true"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "false"
            end tell
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.stringValue == "true"
    }
}

@MainActor
final class AgentSessionOpener: ObservableObject {
    @Published private(set) var availableTarget: AgentSessionTarget?

    private let scripting: ITermSessionScripting
    private let probeInterval: TimeInterval
    private var monitoredTarget: AgentSessionTarget?
    private var lastProbeUptime = -TimeInterval.infinity

    init(
        scripting: ITermSessionScripting = AppleScriptITermSessionScripting(),
        probeInterval: TimeInterval = 1
    ) {
        self.scripting = scripting
        self.probeInterval = probeInterval
    }

    func refresh(
        rawIdentifier: String?,
        force: Bool = false,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let target = AgentSessionTarget(rawIdentifier: rawIdentifier) else {
            clear()
            return
        }

        let targetChanged = target != monitoredTarget
        guard targetChanged || force || uptime - lastProbeUptime >= probeInterval else { return }

        monitoredTarget = target
        lastProbeUptime = uptime
        availableTarget = scripting.sessionExists(uniqueID: target.uniqueID) ? target : nil
    }

    func canOpen(rawIdentifier: String?) -> Bool {
        guard let target = AgentSessionTarget(rawIdentifier: rawIdentifier) else { return false }
        return target == availableTarget
    }

    func open(rawIdentifier: String?) {
        guard let target = AgentSessionTarget(rawIdentifier: rawIdentifier),
              target == monitoredTarget else { return }
        let opened = scripting.selectSession(uniqueID: target.uniqueID)
        availableTarget = opened ? target : nil
        lastProbeUptime = ProcessInfo.processInfo.systemUptime
    }

    func clear() {
        monitoredTarget = nil
        availableTarget = nil
        lastProbeUptime = -TimeInterval.infinity
    }
}
