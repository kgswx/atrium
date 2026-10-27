import AppKit
import UniformTypeIdentifiers
import AtriumCore

/// Icons are shared per file type, so a folder of 5,000 photos costs one icon, not 5,000.
/// Apps and the home folders have their own icons and are cached by path instead.
final class IconCache {
    static let shared = IconCache()
    /// Posted after a folder's colour or symbol changes, so lists and navigation panes redraw.
    static let stylesChanged = Notification.Name("AtriumFolderStylesChanged")

    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private var styled: [String: NSImage] = [:]
    private lazy var ownIconFolders: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library",
                     "Applications", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0).path }
        paths += [home.path, "/Applications", "/System", "/Library", "/Users", "/"]
        return Set(paths)
    }()

    /// `size` matters only for coloured folders, which are drawn at the size they are shown; system icons
    /// carry every size and scale cleanly.
    func icon(for entry: FileEntry, size: CGFloat = 16) -> NSImage {
        if entry.isFolder && !entry.style.isPlain { return folderIcon(entry.url, style: entry.style, size: size) }
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

    /// A folder in its colour with its symbol, shared by every folder with the same look.
    func folderIcon(_ url: URL, style: FolderStyle, size: CGFloat = 16) -> NSImage {
        if style.hasCustomIcon { return icon(forPath: url.path) }   // a picture: macOS draws it
        let special = ownIconFolders.contains(url.path)
        let key = "\(special ? url.path : "folder")|\(style.color?.rawValue ?? 0)|\(style.symbol ?? "")|\(size)"
        if let hit = styled[key] { return hit }
        let base = special ? NSWorkspace.shared.icon(forFile: url.path) : NSWorkspace.shared.icon(for: .folder)
        let image = FolderArt.image(base: base, color: style.color, symbol: style.symbol, size: size)
        styled[key] = image
        return image
    }

    /// Any folder's icon, in its colour and with its symbol if it has them.
    func folderIcon(for url: URL) -> NSImage {
        let label = try? url.resourceValues(forKeys: [.labelNumberKey]).labelNumber
        let style = FolderStyles.style(at: url, labelNumber: label)
        return style.isPlain ? icon(forPath: url.path) : folderIcon(url, style: style)
    }

    /// Called when the last window closes, so an idle Atrium holds no images.
    func purge() {
        byType.removeAll()
        byPath.removeAll()
        styled.removeAll()
    }
}
