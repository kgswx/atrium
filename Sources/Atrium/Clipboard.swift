import AppKit

/// Cut, copy and paste of files through the system pasteboard, so Finder and other apps can paste what Atrium copied.
/// Cut is remembered here: if anything else writes to the pasteboard, the cut is forgotten, as in Explorer.
enum Clipboard {
    static let changed = Notification.Name("AtriumClipboardChanged")

    private static var cutItems: Set<String> = []
    private static var cutChangeCount = -1
    private static var pasteboard: NSPasteboard { .general }

    static func put(_ urls: [URL], cut: Bool) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutItems = cut ? Set(urls.map(\.key)) : []
        cutChangeCount = cut ? pasteboard.changeCount : -1
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Items waiting to be moved; they are shown faded until pasted.
    static var cutPaths: Set<String> { pasteboard.changeCount == cutChangeCount ? cutItems : [] }

    static var fileURLs: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    static func clearCut() {
        cutItems = []
        cutChangeCount = -1
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
