// Native WorktreeGuard notification/approval toast.
//
// Two call patterns from worktreeguard/notifications.py:
//  - Auto-grant awareness: launched detached (fire-and-forget), self-dismisses
//    after `duration` seconds. Body click focuses the originating terminal tab;
//    the revoke control shells out to `wtg revoke --grant-id <id>` directly,
//    since nothing is waiting on this process's output.
//  - Pending manual approval: launched blocking (parent waits on this process).
//    Stays open until Approve/Reject is clicked or `duration` elapses (0 = wait
//    forever). Prints exactly one outcome word to stdout before exiting:
//    "approve", "reject", or "timeout" — the parent owns what happens next.
//    Body click only focuses the tab; it does not dismiss the toast, since
//    looking at the context shouldn't count as a decision.
//
// argv: title actionLabel mode reason duration focusCommand revokeCommand
//   mode: "0" = auto-approved (revoke control), "1" = pending (approve/reject)

import AppKit
import Darwin
import SwiftUI

let args = CommandLine.arguments
func arg(_ i: Int, _ def: String) -> String { i < args.count ? args[i] : def }

func displayActionLabel(_ rawLabel: String) -> String {
    switch rawLabel {
    case "writes":
        return "File writes"
    case "change-branch":
        return "Changing branch"
    case "discard":
        return "Discarding changes"
    case "stash":
        return "Stashing changes"
    default:
        return rawLabel
    }
}

let title = arg(1, "WorktreeGuard")
let actionLabel = displayActionLabel(arg(2, ""))
let isPending = arg(3, "0") == "1"
let reason = arg(4, "")
let duration = Double(arg(5, "6")) ?? 6
let focusCommand = args.count > 6 && !args[6].isEmpty ? args[6] : nil
let revokeCommand = args.count > 7 && !args[7].isEmpty ? args[7] : nil

// MARK: - Toast stacking

let PANEL_WIDTH: CGFloat = 600
let PANEL_MARGIN: CGFloat = 16
let PANEL_GAP: CGFloat = 8

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/worktreeguard")
let stackFile = stateDir.appendingPathComponent("toast-stack.json")
let lockPath = stateDir.path + "/.toast-stack.lock"

struct StackEntry: Codable {
    let pid: Int32
    let frameY: Double
    let height: Double
}

func acquireStackLock(timeout: Double = 2.0) -> Bool {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let myPid = ProcessInfo.processInfo.processIdentifier
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let fd = Darwin.open(lockPath, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        if fd >= 0 {
            let s = "\(myPid)"
            s.withCString { Darwin.write(fd, $0, strlen($0)) }
            Darwin.close(fd)
            return true
        }
        if let content = try? String(contentsOfFile: lockPath, encoding: .utf8),
           let holder = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           Darwin.kill(holder, 0) != 0 {
            Darwin.unlink(lockPath)
            continue
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

func releaseStackLock() { Darwin.unlink(lockPath) }

func readStack() -> [StackEntry] {
    guard let data = try? Data(contentsOf: stackFile),
          let entries = try? JSONDecoder().decode([StackEntry].self, from: data) else { return [] }
    return entries
}

func writeStack(_ entries: [StackEntry]) {
    if let data = try? JSONEncoder().encode(entries) {
        try? data.write(to: stackFile, options: .atomic)
    }
}

func removeFromStack() {
    let myPid = ProcessInfo.processInfo.processIdentifier
    if acquireStackLock(timeout: 0.5) {
        defer { releaseStackLock() }
        var stack = readStack().filter { Darwin.kill($0.pid, 0) == 0 && $0.pid != myPid }
        writeStack(stack)
    }
}

// MARK: - Shell and exit

func runShell(_ command: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    try? task.run()
}

func finish(_ outcome: String) -> Never {
    removeFromStack()
    print(outcome)
    exit(0)
}

// MARK: - View

struct ToastView: View {
    let onFocus: () -> Void
    let onRevoke: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(isPending ? Color.orange : Color.green)
                            .frame(width: 9, height: 9)
                            .shadow(color: (isPending ? Color.orange : Color.green).opacity(0.8), radius: 4)
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(title)
                                .font(.system(size: 24, weight: .bold))
                            Text(actionLabel)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                            if !reason.isEmpty {
                                Text(reason)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }

                if !isPending && revokeCommand != nil {
                    Button(action: onRevoke) {
                        Image(systemName: "lock.slash")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isPending {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button(action: onReject) {
                            Label("Reject", systemImage: "xmark")
                        }
                        .tint(.red)

                        Button(action: onApprove) {
                            Label("Approve", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .frame(width: PANEL_WIDTH, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        .preferredColorScheme(.dark)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let hosting = NSHostingView(rootView: ToastView(
            onFocus: {
                if let cmd = focusCommand { runShell(cmd) }
                if !isPending { finish("focus") }
            },
            onRevoke: {
                if let cmd = revokeCommand { runShell(cmd) }
                finish("revoke")
            },
            onApprove: { finish("approve") },
            onReject: { finish("reject") }
        ))

        // Fix width to PANEL_WIDTH; measure wrapping height.
        hosting.frame = NSRect(x: 0, y: 0, width: PANEL_WIDTH, height: 10000)
        let panelHeight = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: PANEL_WIDTH, height: panelHeight)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelX = screenFrame.maxX - PANEL_WIDTH - PANEL_MARGIN
        var panelY = screenFrame.maxY - PANEL_MARGIN - panelHeight

        // Stack: position this toast below any already-visible toasts.
        if acquireStackLock() {
            defer { releaseStackLock() }
            let live = readStack().filter { Darwin.kill($0.pid, 0) == 0 }
            if let lowest = live.min(by: { $0.frameY < $1.frameY }) {
                panelY = lowest.frameY - PANEL_GAP - panelHeight
            }
            var stack = live
            stack.append(StackEntry(
                pid: ProcessInfo.processInfo.processIdentifier,
                frameY: Double(panelY),
                height: Double(panelHeight)
            ))
            writeStack(stack)
        }

        panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: PANEL_WIDTH, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.orderFrontRegardless()

        if duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                finish("timeout")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeFromStack()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
