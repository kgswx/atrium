import AppKit

/// Small actions shared by the list, the sidebar and the menus.
enum Shell {
    static func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// One path per line, as plain text.
    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        NotificationCenter.default.post(name: Clipboard.changed, object: nil)
    }

    /// Opens folders in Finder by its bundle id: the plain NSWorkspace route would come straight back to Atrium
    /// once Atrium is the default viewer.
    static func openInFinder(_ folders: [URL]) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(folders.uniqued(), withApplicationAt: finder, configuration: config)
    }
}

/// Explorer's drag rules: same drive moves, another drive copies; hold Option to copy, Command to move.
enum DragRules {
    static func mode(for info: NSDraggingInfo, sources: [URL], target: URL) -> TransferMode? {
        let target = target.standardizedFileURL
        let sources = sources.map(\.standardizedFileURL)
        if sources.contains(where: { (target.path + "/").hasPrefix($0.path + "/") }) { return nil }
        if sources.allSatisfy({ $0.deletingLastPathComponent().key == target.key }) { return nil }

        let mask = info.draggingSourceOperationMask
        if mask == .copy { return .copy }
        if mask == .generic || mask == .move { return .move }
        if !mask.contains(.move) && !mask.contains(.generic) { return mask.contains(.copy) ? .copy : nil }
        return sameVolume(sources[0], target) ? .move : .copy
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let x = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }
}

extension NSDraggingInfo {
    var fileURLs: [URL]? {
        let urls = draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
