import XCTest
import UniformTypeIdentifiers
@testable import AtriumCore

final class FileNamingTests: XCTestCase {
    func testCopyNamesFollowExplorer() {
        var taken: Set<String> = ["Report.pdf"]
        let first = FileNaming.copyName(for: "Report.pdf", isFolder: false) { taken.contains($0) }
        XCTAssertEqual(first, "Report - Copy.pdf")
        taken.insert(first)
        XCTAssertEqual(FileNaming.copyName(for: "Report.pdf", isFolder: false) { taken.contains($0) }, "Report - Copy (2).pdf")
        XCTAssertEqual(FileNaming.copyName(for: "Photos.2026", isFolder: true) { _ in false }, "Photos.2026 - Copy")
    }

    func testNumberedNames() {
        let taken: Set<String> = ["New folder", "New folder (2)"]
        XCTAssertEqual(FileNaming.numberedName(for: "New folder", isFolder: true) { taken.contains($0) }, "New folder (3)")
        XCTAssertEqual(FileNaming.numberedName(for: "a.txt", isFolder: false) { $0 == "a.txt" }, "a (2).txt")
        XCTAssertEqual(FileNaming.numberedName(for: "free.txt", isFolder: false) { _ in false }, "free.txt")
    }

    func testSplitAndStemRange() {
        XCTAssertEqual(FileNaming.split("archive.tar.gz", isFolder: false).ext, "gz")
        XCTAssertEqual(FileNaming.split(".zshrc", isFolder: false).ext, "")
        XCTAssertEqual(FileNaming.split("Notes. draft", isFolder: false).ext, "")
        XCTAssertEqual(FileNaming.stemRange(of: "photo.jpeg", isFolder: false), NSRange(location: 0, length: 5))
        XCTAssertEqual(FileNaming.stemRange(of: "v1.2 plans", isFolder: true), NSRange(location: 0, length: 10))
    }

    func testProblemsAndExtensionChange() {
        XCTAssertNotNil(FileNaming.problem(with: "  "))
        XCTAssertNotNil(FileNaming.problem(with: "a/b"))
        XCTAssertNil(FileNaming.problem(with: "Budget 2027.xlsx"))
        XCTAssertTrue(FileNaming.changesExtension(from: "a.txt", to: "a.md"))
        XCTAssertFalse(FileNaming.changesExtension(from: "a.txt", to: "b.TXT"))
    }
}

final class PathInputTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")
    let here = URL(fileURLWithPath: "/Users/someone/Projects")

    func testAbsoluteHomeAndRelative() {
        XCTAssertEqual(PathInput.candidates(for: "/usr/bin", current: here, home: home), [URL(fileURLWithPath: "/usr/bin")])
        XCTAssertEqual(PathInput.candidates(for: "~/Desktop", current: here, home: home), [URL(fileURLWithPath: "/Users/someone/Desktop")])
        XCTAssertEqual(PathInput.candidates(for: "..", current: here, home: home).first?.key, "/Users/someone")
        XCTAssertEqual(PathInput.candidates(for: "\"/tmp\"", current: here, home: home), [URL(fileURLWithPath: "/tmp")])
    }

    func testWindowsHabits() {
        let shortcut = PathInput.candidates(for: "downloads", current: here, home: home)
        XCTAssertEqual(shortcut.last, URL(fileURLWithPath: "/Users/someone/Downloads"))
        let backslashes = PathInput.candidates(for: "Documents\\Work", current: here, home: home)
        XCTAssertEqual(backslashes.last, URL(fileURLWithPath: "/Users/someone/Documents/Work"))
    }
}

final class ListingTests: XCTestCase {
    func entry(_ name: String, folder: Bool = false, size: Int64? = nil, kind: String = "Document", modified: Date? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isFolder: folder, modified: modified,
                  size: folder ? nil : size, kind: folder ? "Folder" : kind)
    }

    func testFoldersFirstAndNaturalOrder() {
        let items = [entry("file10"), entry("file2"), entry("Zeta", folder: true), entry("alpha", folder: true)]
        XCTAssertEqual(Listing.sorted(items, by: .name, ascending: true).map(\.name), ["alpha", "Zeta", "file2", "file10"])
        XCTAssertEqual(Listing.sorted(items, by: .name, ascending: false).map(\.name), ["Zeta", "alpha", "file10", "file2"])
    }

    func testSizeSort() {
        let items = [entry("big", size: 900), entry("small", size: 3), entry("dir", folder: true)]
        XCTAssertEqual(Listing.sorted(items, by: .size, ascending: false).map(\.name), ["dir", "big", "small"])
    }

    func testGroupByKind() {
        let items = Listing.sorted([entry("b.png", kind: "PNG image"), entry("a", folder: true), entry("c.pdf", kind: "PDF document")],
                                   by: .name, ascending: true)
        XCTAssertEqual(Listing.grouped(items, by: .kind).map(\.title), ["Folder", "PDF document", "PNG image"])
    }

    func testDateBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")! // a Wednesday
        func bucket(_ s: String) -> DateBucket { DateBucket.bucket(for: ISO8601DateFormatter().date(from: s), now: now, calendar: calendar) }
        XCTAssertEqual(bucket("2026-10-28T01:00:00Z"), .today)
        XCTAssertEqual(bucket("2026-10-27T23:00:00Z"), .yesterday)
        XCTAssertEqual(bucket("2026-10-26T09:00:00Z"), .earlierThisWeek)
        XCTAssertEqual(bucket("2026-10-20T09:00:00Z"), .lastWeek)
        XCTAssertEqual(bucket("2026-10-03T09:00:00Z"), .earlierThisMonth)
        XCTAssertEqual(bucket("2026-09-15T09:00:00Z"), .lastMonth)
        XCTAssertEqual(bucket("2026-02-01T09:00:00Z"), .earlierThisYear)
        XCTAssertEqual(bucket("2024-02-01T09:00:00Z"), .longAgo)
        XCTAssertEqual(DateBucket.bucket(for: nil, now: now), .unknown)
    }

    func testFilter() {
        let items = [entry("Résumé.pdf"), entry("notes.txt")]
        XCTAssertEqual(Listing.filter(items, matching: "resume").map(\.name), ["Résumé.pdf"])
        XCTAssertEqual(Listing.filter(items, matching: " ").count, 2)
    }
}

final class DirectoryLoaderTests: XCTestCase {
    func testReadsAFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1234).write(to: dir.appendingPathComponent("data.bin"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let visible = try DirectoryLoader.entries(in: dir, includeHidden: false)
        XCTAssertEqual(Set(visible.map(\.name)), ["Sub", "data.bin"])
        XCTAssertEqual(visible.first { $0.name == "data.bin" }?.size, 1234)
        XCTAssertEqual(visible.first { $0.name == "Sub" }?.isFolder, true)
        XCTAssertNil(visible.first { $0.name == "Sub" }?.size)
        XCTAssertEqual(try DirectoryLoader.entries(in: dir, includeHidden: true).count, 3)
    }
}

final class CloudTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testSyncStates() {
        XCTAssertEqual(SyncState.from(isUbiquitous: false, status: .current, isDownloading: false, isUploading: false, isUploaded: true), .none)
        XCTAssertEqual(SyncState.from(isUbiquitous: true, status: .notDownloaded, isDownloading: false, isUploading: false, isUploaded: true), .cloudOnly)
        XCTAssertEqual(SyncState.from(isUbiquitous: true, status: .current, isDownloading: false, isUploading: false, isUploaded: true), .local)
        XCTAssertEqual(SyncState.from(isUbiquitous: true, status: .notDownloaded, isDownloading: true, isUploading: false, isUploaded: true), .syncing)
        XCTAssertEqual(SyncState.from(isUbiquitous: true, status: .current, isDownloading: false, isUploading: false, isUploaded: false), .waiting)
    }

    func testPlaces() {
        XCTAssertTrue(CloudPlaces.contains(home.appendingPathComponent("Library/CloudStorage/GoogleDrive-a@b.com/My Drive"), home: home))
        XCTAssertTrue(CloudPlaces.contains(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x"), home: home))
        XCTAssertFalse(CloudPlaces.contains(home.appendingPathComponent("Documents"), home: home))
        XCTAssertFalse(CloudPlaces.contains(home.appendingPathComponent("Library/CloudStorageOld"), home: home))
        XCTAssertTrue(CloudPlaces.isGoogleDrive(home.appendingPathComponent("Library/CloudStorage/GoogleDrive-a@b.com"), home: home))
        XCTAssertFalse(CloudPlaces.isGoogleDrive(home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal"), home: home))
    }

    func testNamesAndLinks() {
        XCTAssertEqual(CloudPlaces.describe(folderName: "GoogleDrive-a@b.com").provider, "Google Drive")
        XCTAssertEqual(CloudPlaces.describe(folderName: "GoogleDrive-a@b.com").account, "a@b.com")
        XCTAssertEqual(CloudPlaces.describe(folderName: "OneDrive-Personal").provider, "OneDrive")
        XCTAssertNil(CloudPlaces.describe(folderName: "Dropbox").account)
        XCTAssertEqual(CloudPlaces.driveLink(forItemID: "1AbC_d-9")?.absoluteString, "https://drive.google.com/open?id=1AbC_d-9")
        XCTAssertNil(CloudPlaces.driveLink(forItemID: "a&b=c"))
        XCTAssertNil(CloudPlaces.driveLink(forItemID: ""))
    }

    func testGoogleKinds() {
        XCTAssertEqual(DirectoryLoader.kindDescription(for: UTType(filenameExtension: "gsheet")!), "Google Sheets")
        XCTAssertEqual(DirectoryLoader.kindDescription(for: UTType(filenameExtension: "gdoc")!), "Google Docs")
    }
}
