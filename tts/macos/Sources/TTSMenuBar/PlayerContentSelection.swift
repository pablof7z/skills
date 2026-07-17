enum PlayerContentSelection {
    static func displayedItem(
        currentItem: TTSItem?,
        pendingPreviewItem: TTSItem?,
        lingeringItem: TTSItem?
    ) -> TTSItem? {
        pendingPreviewItem ?? currentItem ?? lingeringItem
    }
}
