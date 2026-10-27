import AppKit
import UniformTypeIdentifiers
import AtriumCore

/// Icons are shared per file type, so a folder of 5,000 photos costs one icon, not 5,000.
/// Apps and the home folders have their own icons and are cached by path instead.
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private lazy var ownIconFolders: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library",
                     "Applications", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0).path }
        paths += [home.path, "/Applications", "/System", "/Library", "/Users", "/"]
        return Set(paths)
    }()

    func icon(for entry: FileEntry) -> NSImage {
        if entry.typeIdentifier == UTType.applicationBundle.identifier || ownIconFolders.contains(entry.url.path) {
            return icon(forPath: entry.url.path)
        }
        return icon(forType: entry.typeIdentifier)
    }

    func icon(forPath path: String) -> NSImage {
        if let hit = byPath[path] { return hit }
        if byPath.count > 400 { byPath.removeAll() }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 16, height: 16)
        byPath[path] = image
        return image
    }

    func icon(forType identifier: String) -> NSImage {
        if let hit = byType[identifier] { return hit }
        let image = NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
        image.size = NSSize(width: 16, height: 16)
        byType[identifier] = image
        return image
    }

    /// Called when the last window closes, so an idle Atrium holds no images.
    func purge() {
        byType.removeAll()
        byPath.removeAll()
    }
}
