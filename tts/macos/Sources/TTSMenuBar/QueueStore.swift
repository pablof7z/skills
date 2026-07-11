import Foundation

struct QueueStore {
    let stateDirectory: URL

    init(stateDirectory: URL = QueueStore.defaultStateDirectory()) {
        self.stateDirectory = stateDirectory
    }

    var itemsDirectory: URL {
        stateDirectory.appendingPathComponent("items", isDirectory: true)
    }

    var processFile: URL {
        stateDirectory.appendingPathComponent("menu.pid")
    }

    var lockDirectory: URL {
        stateDirectory.appendingPathComponent("menu.lock", isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: itemsDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadItems() throws -> [TTSItem] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(TTSItem.self, from: data)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id < $1.id
                }
                return $0.createdAt < $1.createdAt
            }
    }

    func save(_ item: TTSItem) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(item)
        let destination = itemsDirectory.appendingPathComponent("\(item.id).json")
        try data.write(to: destination, options: .atomic)
    }

    func recoverInterruptedItems() throws {
        for var item in try loadItems() where item.status == .playing || item.status == .paused {
            guard FileManager.default.fileExists(atPath: item.outputFile) else {
                item.status = .failed
                item.error = "Audio file is no longer available."
                item.completedAt = Int64(Date().timeIntervalSince1970)
                try save(item)
                continue
            }
            item.status = .queued
            item.startedAt = nil
            item.completedAt = nil
            item.error = nil
            try save(item)
        }
    }

    static func defaultStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--state-dir"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let explicit = environment["TTS_STATE_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("tts", isDirectory: true)
        }
        let home = environment["HOME"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/state/tts", isDirectory: true)
    }
}
