import Foundation

struct MediaSessionSnapshot: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: Int32?
    let contentIdentifier: String?
    let title: String?
    let artist: String?
    let album: String?
    let isPlaying: Bool

    func belongsToSameSession(as other: MediaSessionSnapshot) -> Bool {
        if let bundleIdentifier, let otherBundle = other.bundleIdentifier,
           bundleIdentifier != otherBundle {
            return false
        }
        if let processIdentifier, let otherPID = other.processIdentifier,
           processIdentifier != otherPID {
            return false
        }
        if let contentIdentifier, let otherContent = other.contentIdentifier {
            return contentIdentifier == otherContent
        }
        if bundleIdentifier != nil || processIdentifier != nil {
            return true
        }
        return title == other.title && artist == other.artist && album == other.album
            && title != nil
    }
}

@MainActor
protocol MediaControlBackend: AnyObject {
    var name: String { get }
    func sessions() async throws -> [MediaSessionSnapshot]
    func pause(_ session: MediaSessionSnapshot) async throws -> Bool
    func play(_ session: MediaSessionSnapshot) async throws -> Bool
    func restoreOnShutdown(_ session: MediaSessionSnapshot) -> Bool
}

enum MediaControlBackendError: LocalizedError {
    case unavailable(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case let .commandFailed(reason): reason
        }
    }
}
