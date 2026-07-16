import Foundation

protocol RemoteCommandRunning: AnyObject {
    func run(arguments: [String], stateDirectory: URL) throws -> Data
}

enum RemotePairingError: Error, LocalizedError {
    case commandUnavailable
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .commandUnavailable:
            "The TTS command could not be found. Reinstall or run TTS once from the skill."
        case let .commandFailed(message):
            message
        case .invalidResponse:
            "TTS returned an invalid pairing response."
        }
    }
}

struct RemotePairingOffer: Equatable {
    let code: String
}

struct RemotePairingService {
    let stateDirectory: URL
    let commandRunner: any RemoteCommandRunning

    func createOffer(relay: String) throws -> RemotePairingOffer {
        let response = try commandRunner.run(
            arguments: ["pair", "offer", "--relay", relay],
            stateDirectory: stateDirectory
        )
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let pairCode = object["pair_code"],
              JSONSerialization.isValidJSONObject(pairCode) else {
            throw RemotePairingError.invalidResponse
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: pairCode,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let code = String(data: encoded, encoding: .utf8) else {
            throw RemotePairingError.invalidResponse
        }
        try ensureListenerRunning()
        return RemotePairingOffer(code: code)
    }

    private func ensureListenerRunning() throws {
        let response = try commandRunner.run(
            arguments: ["daemon", "status"],
            stateDirectory: stateDirectory
        )
        let status = try JSONDecoder().decode(DaemonStatus.self, from: response)
        if !status.running {
            _ = try commandRunner.run(
                arguments: ["daemon", "start"],
                stateDirectory: stateDirectory
            )
        }
    }
}

private struct DaemonStatus: Decodable {
    let running: Bool
}

final class ShellTTSRemoteCommandRunner: RemoteCommandRunning {
    private let executableURL: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: URL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    ) {
        executableURL = Self.locateCommand(environment: environment, executable: executable)
    }

    func run(arguments: [String], stateDirectory: URL) throws -> Data {
        guard let executableURL else { throw RemotePairingError.commandUnavailable }
        let process = Process()
        let output = Pipe()
        let failure = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = failure
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["TTS_STATE_DIR": stateDirectory.path],
            uniquingKeysWith: { _, latest in latest }
        )
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = failure.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemotePairingError.commandFailed(message ?? "TTS command failed.")
        }
        return data
    }

    private static func locateCommand(
        environment: [String: String],
        executable: URL
    ) -> URL? {
        var candidates: [URL] = []
        if let explicit = environment["TTS_CLI"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        var ancestor = executable.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.lastPathComponent == "macos" {
                candidates.append(
                    ancestor.deletingLastPathComponent()
                        .appendingPathComponent("scripts/tts")
                )
                break
            }
            ancestor.deleteLastPathComponent()
        }
        if let home = environment["HOME"] {
            let root = URL(fileURLWithPath: home, isDirectory: true)
            candidates.append(root.appendingPathComponent(".agents/skills/tts/scripts/tts"))
            candidates.append(root.appendingPathComponent(".codex/skills/tts/scripts/tts"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
