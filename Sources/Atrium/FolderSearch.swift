import Foundation
import AtriumCore

/// Searches a folder and everything under it through the Spotlight index, once, then stops listening.
/// Folders Spotlight doesn't index (system folders, some drives) only get the current-folder matches.
final class FolderSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func start(_ text: String, in folder: URL, includeHidden: Bool, limit: Int = 3000,
               completion: @escaping ([FileEntry]) -> Void) {
        stop()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        query.searchScopes = [folder]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                          queue: .main) { [weak self] _ in
            query.disableUpdates()
            query.stop()
            let paths = (0..<min(query.resultCount, limit)).compactMap {
                (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
            }
            self?.stop()
            DispatchQueue.global(qos: .userInitiated).async {
                let entries = paths.compactMap { DirectoryLoader.entry(for: URL(fileURLWithPath: $0)) }
                    .filter { includeHidden || !$0.isHidden }
                DispatchQueue.main.async { completion(entries) }
            }
        }
        self.query = query
        query.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query?.stop()
        query = nil
    }

    deinit { stop() }
}
