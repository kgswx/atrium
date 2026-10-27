import Foundation

/// Where a file in a cloud folder stands, as Explorer's Status column shows it for OneDrive.
public enum SyncState: Hashable {
    /// Not in a cloud folder.
    case none
    /// In the cloud only; opening it downloads it.
    case cloudOnly
    /// Downloaded and up to date.
    case local
    /// Downloading or uploading now.
    case syncing
    /// Changed on this Mac and not uploaded yet.
    case waiting

    public var title: String {
        switch self {
        case .none: return ""
        case .cloudOnly: return "Online only"
        case .local: return "On this Mac"
        case .syncing: return "Syncing"
        case .waiting: return "Waiting to upload"
        }
    }

    /// From the standard ubiquitous-item keys, which iCloud Drive and every File Provider app
    /// (Google Drive, OneDrive, Dropbox) report.
    public static func from(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?, isDownloading: Bool?,
                            isUploading: Bool?, isUploaded: Bool?) -> SyncState {
        guard isUbiquitous == true else { return .none }
        if isDownloading == true || isUploading == true { return .syncing }
        if isUploaded == false { return .waiting }
        switch status {
        case .notDownloaded?: return .cloudOnly
        case .current?, .downloaded?: return .local
        default: return .none
        }
    }
}

/// Cloud folders: iCloud Drive and the File Provider folders in ~/Library/CloudStorage (Google Drive, OneDrive...).
public enum CloudPlaces {
    static let providers = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box",
                            "pCloudDrive": "pCloud", "MEGA": "MEGA"]

    public static func storage(home: URL) -> URL { home.appendingPathComponent("Library/CloudStorage") }
    public static func iCloudDrive(home: URL) -> URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }

    /// True for anything inside a cloud folder, reached directly or through a link such as ~/Google Drive.
    public static func contains(_ url: URL, home: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(storage(home: home).path + "/") || path.hasPrefix(home.path + "/Library/Mobile Documents/")
    }

    public static func isGoogleDrive(_ url: URL, home: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(storage(home: home).path + "/GoogleDrive-")
    }

    /// "GoogleDrive-name@example.com" -> ("Google Drive", "name@example.com"); "Dropbox" -> ("Dropbox", nil).
    public static func describe(folderName name: String) -> (provider: String, account: String?) {
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = providers[parts[0]] ?? parts[0]
        return (provider, parts.count > 1 ? parts[1] : nil)
    }

    /// A link that opens the item in Google Drive on the web, whatever it is (file, folder, Google Doc).
    public static func driveLink(forItemID id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://drive.google.com/open?id=\(id)")
    }

    /// Google Drive for desktop keeps each item's Drive ID in this extended attribute.
    public static func driveItemID(at url: URL) -> String? {
        let name = "com.google.drivefs.item-id#S"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length else { return nil }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
    }
}
