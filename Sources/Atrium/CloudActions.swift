import Foundation

/// Download and free-up-space for iCloud Drive and File Provider folders (Google Drive, OneDrive, Dropbox),
/// through the same calls Finder's "Download Now" and "Remove Download" use. Run off the main thread.
enum CloudActions {
    /// Starts downloading the files, and the files inside folders (up to 10,000 at a time). Returns what failed.
    static func download(_ urls: [URL]) -> [String] {
        var started = 0
        var errors: [String] = []
        for url in urls where started < 10_000 {
            guard isFolder(url) else {
                do { try FileManager.default.startDownloadingUbiquitousItem(at: url) } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                started += 1
                continue
            }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = walker?.nextObject() as? URL, started < 10_000 {
                guard !isFolder(file) else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                started += 1
            }
        }
        return errors
    }

    /// Removes local copies. A folder that won't go as a whole is freed file by file; a file still in use
    /// (just closed by a preview, still syncing) gets a second try. Returns what failed.
    static func freeUpSpace(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls {
            do {
                do {
                    try FileManager.default.evictUbiquitousItem(at: url)
                } catch where !isFolder(url) {
                    Thread.sleep(forTimeInterval: 1.5)
                    try FileManager.default.evictUbiquitousItem(at: url)
                }
            } catch where isFolder(url) {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = walker?.nextObject() as? URL {
                    if !isFolder(file) { try? FileManager.default.evictUbiquitousItem(at: file) }
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return errors
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
