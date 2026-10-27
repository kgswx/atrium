import Foundation

/// The seven Finder colours. The raw value is the label number macOS stores with the folder's colour tag.
public enum FolderColor: Int, CaseIterable {
    case gray = 1, green, purple, blue, yellow, red, orange

    /// The order Finder lists them in.
    public static let menuOrder: [FolderColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

    public var title: String {
        switch self {
        case .gray: return "Grey"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }
}

/// How a folder is drawn: its colour (the Finder colour tag, so Finder shows the same colour as a tag) and an
/// optional symbol on it (an attribute Atrium keeps on the folder). Both travel with the folder when it is
/// renamed, moved or copied.
public struct FolderStyle: Hashable {
    public var color: FolderColor?
    /// An SF Symbol name, such as "star.fill".
    public var symbol: String?
    /// A picture set with "Choose Picture…" (or in Finder); macOS draws those itself.
    public var hasCustomIcon: Bool

    public init(color: FolderColor? = nil, symbol: String? = nil, hasCustomIcon: Bool = false) {
        self.color = color
        self.symbol = symbol
        self.hasCustomIcon = hasCustomIcon
    }

    public static let plain = FolderStyle()
    public var isPlain: Bool { color == nil && symbol == nil && !hasCustomIcon }
}

public enum FolderStyles {
    static let symbolAttribute = "io.kgswx.atrium.symbol#S"

    /// Symbols offered in the Folder icon menu, as (SF Symbol, name).
    public static let symbols: [(String, String)] = [
        ("star.fill", "Star"), ("heart.fill", "Heart"), ("flag.fill", "Flag"), ("bookmark.fill", "Bookmark"),
        ("exclamationmark.triangle.fill", "Important"), ("checkmark.seal.fill", "Done"), ("clock.fill", "In progress"),
        ("briefcase.fill", "Work"), ("person.2.fill", "People"), ("building.2.fill", "Buildings"),
        ("ruler.fill", "Drawings"), ("cube.fill", "3D models"), ("map.fill", "Maps"), ("paintbrush.pointed.fill", "Design"),
        ("doc.text.fill", "Documents"), ("tablecells.fill", "Spreadsheets"), ("banknote.fill", "Money"),
        ("photo.fill", "Photos"), ("film.fill", "Videos"), ("music.note", "Music"),
        ("chevron.left.forwardslash.chevron.right", "Code"), ("hammer.fill", "Tools"), ("graduationcap.fill", "Study"),
        ("book.fill", "Books"), ("house.fill", "Home"), ("airplane", "Travel"), ("cart.fill", "Shopping"),
        ("gamecontroller.fill", "Games"), ("archivebox.fill", "Archive"), ("lock.fill", "Private"),
    ]

    /// Reads a folder's style. `labelNumber` comes from the listing; the symbol and custom-icon flag are one
    /// small read each, done for folders only, and skipped for guarded folders (see `isGuarded`).
    public static func style(at url: URL, labelNumber: Int?) -> FolderStyle {
        let color = labelNumber.flatMap(FolderColor.init(rawValue:))
        if isGuarded(url) && !allowedGuardedPaths().contains(url.standardizedFileURL.path) { return FolderStyle(color: color) }
        return FolderStyle(color: color, symbol: symbol(at: url), hasCustomIcon: hasCustomIcon(at: url))
    }

    /// Guarded folders whose attributes may still be read: the app passes the ones styled in it, whose permission
    /// prompt was answered at the time.
    public static var allowedGuardedPaths: () -> Set<String> = { [] }

    /// Folders macOS guards with a permission prompt (Desktop, Documents, Downloads, cloud and other apps' data,
    /// drives). Reading even an attribute of one from the folder above asks for permission, so a listing that
    /// merely shows them must not.
    public static func isGuarded(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        let folders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
        if folders.contains(where: { home.appendingPathComponent($0).path == path }) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let parents = ["Library/CloudStorage", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents"]
            .map { home.appendingPathComponent($0).path } + ["/Volumes"]
        return parents.contains(parent)
    }

    public static func symbol(at url: URL) -> String? {
        let length = getxattr(url.path, symbolAttribute, nil, 0, 0, 0)
        guard length > 0, length < 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, symbolAttribute, &buffer, length, 0, 0) == length else { return nil }
        let name = String(decoding: buffer, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// The "has custom icon" bit in the folder's Finder info (kHasCustomIcon, 0x0400).
    public static func hasCustomIcon(at url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, "com.apple.FinderInfo", &info, 32, 0, 0) == 32 else { return false }
        return info[8] & 0x04 != 0
    }

    public static func setSymbol(_ symbol: String?, at url: URL) throws {
        let result: Int32
        if let symbol, let data = symbol.data(using: .utf8) {
            result = data.withUnsafeBytes { setxattr(url.path, symbolAttribute, $0.baseAddress, data.count, 0, 0) }
        } else {
            result = removexattr(url.path, symbolAttribute, 0)
            if result != 0 && errno == ENOATTR { return }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    /// Sets the folder's Finder colour tag; nil removes it. Other tags stay.
    public static func setColor(_ color: FolderColor?, at url: URL) throws {
        try (url as NSURL).setResourceValue(color?.rawValue ?? 0, forKey: .labelNumberKey)
    }
}
