import Combine
import Foundation

@MainActor
final class RemoteEndpointMonitor: ObservableObject {
    @Published private(set) var snapshot: RemoteEndpointSnapshot
    private let reader: RemoteEndpointStateReader
    private var timer: Timer?

    init(reader: RemoteEndpointStateReader) {
        self.reader = reader
        snapshot = reader.load()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        snapshot = reader.load()
    }
}
