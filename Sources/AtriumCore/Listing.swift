import Foundation

public enum SortKey: String, CaseIterable {
    case name, modified, kind, size

    public var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .kind: return "Type"
        case .size: return "Size"
        }
    }
}

public enum GroupKey: String, CaseIterable {
    case none, kind, modified

    public var title: String {
        switch self {
        case .none: return "None"
        case .kind: return "Type"
        case .modified: return "Date modified"
        }
    }
}

public struct FileGroup: Equatable {
    public let title: String
    public let entries: [FileEntry]
}

/// Explorer's "Group by Date modified" buckets, newest first.
public enum DateBucket: Int, CaseIterable, Comparable {
    case today, yesterday, earlierThisWeek, lastWeek, earlierThisMonth, lastMonth, earlierThisYear, longAgo, unknown

    public static func < (a: DateBucket, b: DateBucket) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier this week"
        case .lastWeek: return "Last week"
        case .earlierThisMonth: return "Earlier this month"
        case .lastMonth: return "Last month"
        case .earlierThisYear: return "Earlier this year"
        case .longAgo: return "A long time ago"
        case .unknown: return "Unknown date"
        }
    }

    public static func bucket(for date: Date?, now: Date, calendar: Calendar = .current) -> DateBucket {
        guard let date else { return .unknown }
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        if date >= calendar.date(byAdding: .day, value: -1, to: today)! { return .yesterday }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        if date >= week { return .earlierThisWeek }
        if date >= calendar.date(byAdding: .weekOfYear, value: -1, to: week)! { return .lastWeek }
        let month = calendar.dateInterval(of: .month, for: now)!.start
        if date >= month { return .earlierThisMonth }
        if date >= calendar.date(byAdding: .month, value: -1, to: month)! { return .lastMonth }
        if date >= calendar.dateInterval(of: .year, for: now)!.start { return .earlierThisYear }
        return .longAgo
    }
}

public enum Listing {
    /// Folders first in either direction, then the chosen key, then name, using Finder's natural order ("file2" before "file10").
    public static func sorted(_ entries: [FileEntry], by key: SortKey, ascending: Bool) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let order = compare(a, b, by: key)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func compare(_ a: FileEntry, _ b: FileEntry, by key: SortKey) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .kind:
            return a.kind.localizedStandardCompare(b.kind)
        case .modified:
            let x = a.modified ?? .distantPast, y = b.modified ?? .distantPast
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case .size:
            let x = a.size ?? -1, y = b.size ?? -1
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
    }

    /// Splits an already sorted list into groups; entries keep their order inside each group.
    public static func grouped(_ sorted: [FileEntry], by key: GroupKey, now: Date = Date(),
                               calendar: Calendar = .current) -> [FileGroup] {
        switch key {
        case .none:
            return [FileGroup(title: "", entries: sorted)]
        case .kind:
            var order: [String] = []
            var buckets: [String: [FileEntry]] = [:]
            for entry in sorted {
                let title = entry.isFolder ? "Folder" : entry.kind
                if buckets[title] == nil { order.append(title) }
                buckets[title, default: []].append(entry)
            }
            order.sort { a, b in
                if (a == "Folder") != (b == "Folder") { return a == "Folder" }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            return order.map { FileGroup(title: $0, entries: buckets[$0]!) }
        case .modified:
            var buckets: [DateBucket: [FileEntry]] = [:]
            for entry in sorted { buckets[DateBucket.bucket(for: entry.modified, now: now, calendar: calendar), default: []].append(entry) }
            return buckets.keys.sorted().map { FileGroup(title: $0.title, entries: buckets[$0]!) }
        }
    }

    /// Case- and diacritic-insensitive match on the name, as Explorer's search box does for the current folder.
    public static func filter(_ entries: [FileEntry], matching text: String) -> [FileEntry] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
