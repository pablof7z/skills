import Foundation

struct VoicePlaybackRateStore {
    static let availableRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    let fileURL: URL

    init(stateDirectory: URL) {
        fileURL = stateDirectory.appendingPathComponent("voice-playback-rates.json")
    }

    func rate(for voice: String) -> Float {
        guard !voice.isEmpty,
              let stored = load()[voice],
              Self.availableRates.contains(where: { abs($0 - stored) < 0.001 }) else {
            return 1.0
        }
        return stored
    }

    func save(_ rate: Float, for voice: String) throws {
        guard !voice.isEmpty,
              let normalized = Self.availableRates.first(where: { abs($0 - rate) < 0.001 }) else {
            return
        }
        var rates = load()
        rates[voice] = normalized
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rates).write(to: fileURL, options: .atomic)
    }

    static func nextRate(after rate: Float) -> Float {
        guard let index = availableRates.firstIndex(where: { abs($0 - rate) < 0.001 }) else {
            return 1.0
        }
        return availableRates[(index + 1) % availableRates.count]
    }

    static func label(for rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }

    private func load() -> [String: Float] {
        guard let data = try? Data(contentsOf: fileURL),
              let rates = try? JSONDecoder().decode([String: Float].self, from: data) else {
            return [:]
        }
        return rates
    }
}
