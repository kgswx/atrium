import Foundation
import UniformTypeIdentifiers

/// One row of a folder listing, read once from the file system.
public struct FileEntry: Hashable {
    public let url: URL
    public let name: String
    /// A folder you open in place. Apps and other packages are files here, as in Finder.
    public let isFolder: Bool
    public let isHidden: Bool
    public let modified: Date?
    public let created: Date?
    /// Bytes; nil for folders and packages, which Explorer and Finder leave blank too.
    public let size: Int64?
    public let typeIdentifier: String
    public let kind: String

    public init(url: URL, name: String, isFolder: Bool, isHidden: Bool = false, modified: Date? = nil,
                created: Date? = nil, size: Int64? = nil, typeIdentifier: String = UTType.data.identifier,
                kind: String = "Document") {
        self.url = url
        self.name = name
        self.isFolder = isFolder
        self.isHidden = isHidden
        self.modified = modified
        self.created = created
        self.size = size
        self.typeIdentifier = typeIdentifier
        self.kind = kind
    }
}

public enum DirectoryLoader {
    static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey, .fileSizeKey, .contentTypeKey,
    ]

    /// Reads a folder with every attribute the list shows fetched in the same pass (getattrlistbulk underneath).
    public static func entries(in folder: URL, includeHidden: Bool) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: includeHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap(entry(for:))
    }

    public static func entry(for url: URL) -> FileEntry? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isDirectory = v.isDirectory ?? false
        var isFolder = isDirectory && !(v.isPackage ?? false)
        if v.isSymbolicLink == true,
           let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            isFolder = target.isDirectory == true && target.isPackage != true
        }
        let type = isFolder ? UTType.folder : (v.contentType ?? .data)
        return FileEntry(
            url: url,
            name: v.name ?? url.lastPathComponent,
            isFolder: isFolder,
            isHidden: v.isHidden ?? url.lastPathComponent.hasPrefix("."),
            modified: v.contentModificationDate,
            created: v.creationDate,
            size: isDirectory || isFolder ? nil : Int64(v.fileSize ?? 0),
            typeIdentifier: type.identifier,
            kind: kindDescription(for: type))
    }

    private static let kinds = NSCache<NSString, NSString>()

    /// "Folder", "PDF document", "PNG image"... cached per type, because the lookup is slower than the listing.
    public static func kindDescription(for type: UTType) -> String {
        if let hit = kinds.object(forKey: type.identifier as NSString) { return hit as String }
        var text = type.localizedDescription
            ?? type.preferredFilenameExtension.map { "\($0.uppercased()) file" }
            ?? "Document"
        // Some descriptions start lower case ("folder"); the column reads better capitalised, as in Explorer.
        text = text.prefix(1).uppercased() + text.dropFirst()
        kinds.setObject(text as NSString, forKey: type.identifier as NSString)
        return text
    }
}

extension URL {
    /// The same item whatever the trailing slash or "..": compare files by this, never by URL equality.
    public var key: String { standardizedFileURL.path }
}
