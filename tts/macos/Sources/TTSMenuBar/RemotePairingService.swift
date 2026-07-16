import Foundation

protocol RemoteCommandRunning: AnyObject, Sendable {
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

struct RemotePairingConfiguration: Decodable, Equatable {
    var relay: String
    var channel: String

    init(relay: String = "wss://relay.primal.net", channel: String = "wss://nip29.f7z.io/tts") {
        self.relay = relay
        self.channel = channel
    }

    private enum CodingKeys: String, CodingKey { case relay, channel }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relay = try values.decodeIfPresent(String.self, forKey: .relay) ?? "wss://relay.primal.net"
        channel = try values.decodeIfPresent(String.self, forKey: .channel) ?? "wss://nip29.f7z.io/tts"
    }
}

struct RemotePairingService: Sendable {
    let stateDirectory: URL
    let commandRunner: any RemoteCommandRunning

    func configuration() -> RemotePairingConfiguration {
        let url = stateDirectory
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(RemotePairingConfiguration.self, from: data)
        else { return RemotePairingConfiguration() }
        return value
    }

    func createOffer(relay: String, channel: String) throws -> RemotePairingOffer {
        let response = try commandRunner.run(
            arguments: ["pair", "offer", "--relay", relay, "--channel", channel],
            stateDirectory: stateDirectory
        )
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let pairCode = object["pair_code"] as? String,
              !pairCode.isEmpty else {
            throw RemotePairingError.invalidResponse
        }
        try ensureListenerRunning()
        return RemotePairingOffer(code: pairCode)
    }

    func ensureListenerRunning() throws {
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

final class ShellTTSRemoteCommandRunner: RemoteCommandRunning, @unchecked Sendable {
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
            throw RemotePairingError.commandFailed(Self.failureMessage(errorData))
        }
        return data
    }

    static func failureMessage(_ data: Data) -> String {
        if let response = try? JSONDecoder().decode(CommandFailure.self, from: data) {
            return [response.error.message, response.error.guidance]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "TTS command failed."
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

private struct CommandFailure: Decodable {
    struct Detail: Decodable {
        let message: String
        let guidance: String?
    }
    let error: Detail
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
