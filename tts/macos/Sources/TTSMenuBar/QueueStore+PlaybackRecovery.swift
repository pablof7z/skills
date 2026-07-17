import Foundation

extension QueueStore {
    func recoverInterruptedItems(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        for var item in try loadItems() where item.status == .playing || item.status == .paused {
            guard FileManager.default.fileExists(atPath: item.outputFile) else {
                item.status = .failed
                item.error = "Audio file is no longer available."
                item.completedAt = now
                try save(item)
                continue
            }
            if item.status == .paused {
                item.status = .interrupted
                item.completedAt = now
                if !item.isAttachmentPlayback {
                    item.isUnheard = true
                }
            } else {
                item.status = .queued
                item.startedAt = nil
                item.completedAt = nil
            }
            item.error = nil
            try save(item)
        }
    }
}
