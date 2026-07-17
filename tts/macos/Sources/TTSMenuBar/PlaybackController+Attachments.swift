import AppKit
import Foundation

@MainActor
extension PlaybackController {
    func playAttachment(_ attachment: TTSAttachment, from displayedItem: TTSItem) {
        let brief = displayedItem.parentItemID
            .flatMap { parentID in items.first(where: { $0.id == parentID }) }
            ?? displayedItem
        guard let audioFile = attachment.audioFile,
              FileManager.default.fileExists(atPath: audioFile) else { return }

        let pendingChild = items.first {
            $0.parentItemID == brief.id
                && $0.attachmentID == attachment.id
                && ($0.status == .queued || $0.status == .playing || $0.status == .paused)
        }
        if let pendingChild, currentItem?.id == pendingChild.id {
            return
        }

        var returnOffset: TimeInterval?
        if let current = currentItem, let player {
            if current.isAttachmentPlayback {
                returnOffset = current.returnToPlaybackOffset
            } else if current.id == brief.id {
                returnOffset = player.currentTime
            }
            finishCurrentForReplacement()
        }

        if var pendingChild {
            if let returnOffset {
                pendingChild.returnToPlaybackOffset = returnOffset
                try? store.save(pendingChild)
                replaceItem(pendingChild)
            }
            play(pendingChild, initiator: .direct)
            return
        }

        guard let child = brief.attachmentPlaybackItem(
            attachment,
            returnTo: returnOffset
        ) else { return }
        do {
            try store.save(child)
            replaceItem(child)
            play(child, initiator: .direct)
        } catch {
            NSLog("Unable to play TTS attachment: %@", error.localizedDescription)
        }
    }

    func openAttachment(_ attachment: TTSAttachment) {
        let url = URL(fileURLWithPath: attachment.sourceFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func returnToParent(from displayedItem: TTSItem) {
        guard let parentID = displayedItem.parentItemID,
              let parent = items.first(where: { $0.id == parentID }) else { return }
        let offset = displayedItem.returnToPlaybackOffset ?? 0
        if currentItem?.id == displayedItem.id {
            finishCurrentForReplacement()
        }
        let resumed = parent.requeuedForReplay(startingAt: offset)
        do {
            try store.save(resumed)
            replaceItem(resumed)
            if isPlaybackBlocked {
                refresh()
            } else {
                play(resumed, initiator: .direct)
            }
        } catch {
            NSLog("Unable to return to parent TTS item: %@", error.localizedDescription)
        }
    }
}
