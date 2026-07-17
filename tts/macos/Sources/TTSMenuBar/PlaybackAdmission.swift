import Foundation

struct PlaybackAdmission: Codable, Equatable, Identifiable {
    let id: String
    let itemID: String
    let requestedAtNanoseconds: Int64

    init(
        itemID: String,
        requestedAtNanoseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    ) {
        id = itemID
        self.itemID = itemID
        self.requestedAtNanoseconds = requestedAtNanoseconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case requestedAtNanoseconds = "requested_at_ns"
    }
}

extension QueueStore {
    @discardableResult
    func admitPlayback(
        of itemID: String,
        requestedAtNanoseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    ) throws -> PlaybackAdmission {
        try withOperationsLock {
            let admission = PlaybackAdmission(
                itemID: itemID,
                requestedAtNanoseconds: requestedAtNanoseconds
            )
            let destination = playbackAdmissionURL(for: itemID)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                return try JSONDecoder().decode(
                    PlaybackAdmission.self,
                    from: Data(contentsOf: destination)
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(admission).write(to: destination, options: .atomic)
            return admission
        }
    }

    func pendingPlaybackAdmissions() throws -> [PlaybackAdmission] {
        try withOperationsReadLock {
            try loadPlaybackAdmissionsUnlocked()
        }
    }

    func pendingPlaybackItem(heldItemID: String?) throws -> TTSItem? {
        try withOperationsLock {
            try eligiblePlaybackAdmissionsUnlocked(heldItemID: heldItemID).first?.item
        }
    }

    func claimPlaybackItem(id itemID: String) throws -> TTSItem? {
        try withOperationsLock {
            let admissionURL = playbackAdmissionURL(for: itemID)
            guard FileManager.default.fileExists(atPath: admissionURL.path) else { return nil }
            let items = try loadItemsUnlocked()
            guard let item = items.first(where: { $0.id == itemID }),
                  QueuePlaybackPolicy.isAutomaticallyPlayable(item, in: items) else {
                try FileManager.default.removeItem(at: admissionURL)
                return nil
            }
            try FileManager.default.removeItem(at: admissionURL)
            return item
        }
    }

    func discardPlaybackAdmission(for itemID: String) throws {
        try withOperationsLock {
            let destination = playbackAdmissionURL(for: itemID)
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
            try FileManager.default.removeItem(at: destination)
        }
    }

    func discardAllPlaybackAdmissions() throws {
        try withOperationsLock {
            for url in try playbackAdmissionURLsUnlocked() {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func eligiblePlaybackAdmissionsUnlocked(
        heldItemID: String?
    ) throws -> [(admission: PlaybackAdmission, item: TTSItem)] {
        let items = try loadItemsUnlocked()
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var eligible: [(PlaybackAdmission, TTSItem)] = []
        for admission in try loadPlaybackAdmissionsUnlocked() {
            guard let item = itemsByID[admission.itemID],
                  QueuePlaybackPolicy.isAutomaticallyPlayable(item, in: items) else {
                try? FileManager.default.removeItem(at: playbackAdmissionURL(for: admission.itemID))
                continue
            }
            eligible.append((admission, item))
        }
        if let heldItemID {
            return eligible.filter { $0.1.id == heldItemID }
        }
        return eligible
    }

    private func loadPlaybackAdmissionsUnlocked() throws -> [PlaybackAdmission] {
        let decoder = JSONDecoder()
        return try playbackAdmissionURLsUnlocked().compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PlaybackAdmission.self, from: data)
        }.sorted {
            if $0.requestedAtNanoseconds == $1.requestedAtNanoseconds {
                return $0.id < $1.id
            }
            return $0.requestedAtNanoseconds < $1.requestedAtNanoseconds
        }
    }

    private func playbackAdmissionURLsUnlocked() throws -> [URL] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(
            at: playbackAdmissionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func playbackAdmissionURL(for itemID: String) -> URL {
        playbackAdmissionsDirectory.appendingPathComponent("\(itemID).json")
    }
}
