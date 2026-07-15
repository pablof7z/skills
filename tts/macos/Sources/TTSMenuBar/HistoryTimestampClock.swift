import Combine
import Foundation

@MainActor
final class HistoryTimestampClock: ObservableObject {
    @Published private(set) var now: Date
    private var nextUpdateAt: Date

    init(now: Date = Date()) {
        self.now = now
        nextUpdateAt = .distantPast
    }

    func update(items: [TTSItem], at candidate: Date, reschedule: Bool = false) {
        guard reschedule || candidate >= nextUpdateAt else { return }
        now = candidate
        nextUpdateAt = HistoryTimestampPolicy.nextUpdate(after: candidate, items: items)
    }
}

enum HistoryTimestampPolicy {
    static func nextUpdate(after now: Date, items: [TTSItem]) -> Date {
        items.reduce(Date.distantFuture) { earliest, item in
            let elapsed = max(0, now.timeIntervalSince(item.createdDate))
            let nextElapsed: TimeInterval
            if elapsed < 60 {
                nextElapsed = 60
            } else if elapsed < 3_600 {
                nextElapsed = (floor(elapsed / 60) + 1) * 60
            } else if elapsed < 86_400 {
                nextElapsed = (floor(elapsed / 3_600) + 1) * 3_600
            } else {
                return earliest
            }
            return min(earliest, item.createdDate.addingTimeInterval(nextElapsed))
        }
    }
}
