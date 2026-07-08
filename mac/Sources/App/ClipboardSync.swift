import AppKit

final class ClipboardSync {
    private var lastChangeCount = NSPasteboard.general.changeCount

    func poll() -> Bool {
        let current = NSPasteboard.general.changeCount
        defer { lastChangeCount = current }
        return current != lastChangeCount
    }
}
