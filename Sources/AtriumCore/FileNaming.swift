import Foundation

public enum FileNaming {
    /// Name for a copy made in its own folder: "Report.pdf" -> "Report - Copy.pdf" -> "Report - Copy (2).pdf", as Explorer does.
    public static func copyName(for name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        let (stem, ext) = split(name, isFolder: isFolder)
        var candidate = join("\(stem) - Copy", ext)
        var n = 2
        while taken(candidate) {
            candidate = join("\(stem) - Copy (\(n))", ext)
            n += 1
        }
        return candidate
    }

    /// The name itself if free, else "Name (2)", "Name (3)"... Used for "New folder" and for "Keep both".
    public static func numberedName(for name: String, isFolder: Bool, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let (stem, ext) = split(name, isFolder: isFolder)
        var n = 2
        while taken(join("\(stem) (\(n))", ext)) { n += 1 }
        return join("\(stem) (\(n))", ext)
    }

    /// "photo.jpg" -> ("photo", "jpg"); ".zshrc" and folders keep the whole name as the stem.
    public static func split(_ name: String, isFolder: Bool) -> (stem: String, ext: String) {
        guard !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    static func join(_ stem: String, _ ext: String) -> String { ext.isEmpty ? stem : "\(stem).\(ext)" }

    /// What to select when renaming starts: the name without its extension.
    public static func stemRange(of name: String, isFolder: Bool) -> NSRange {
        NSRange(location: 0, length: (split(name, isFolder: isFolder).stem as NSString).length)
    }

    /// Why a typed name can't be used, or nil if it can.
    public static func problem(with name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A name can't be empty." }
        if name == "." || name == ".." { return "“\(name)” is reserved by the system." }
        if name.contains("/") || name.contains(":") { return "A name can't contain “/” or “:”." }
        if (name as NSString).length > 255 { return "That name is too long." }
        return nil
    }

    /// True when only the extension part changed, which Explorer and Finder both ask about.
    public static func changesExtension(from old: String, to new: String) -> Bool {
        split(old, isFolder: false).ext.lowercased() != split(new, isFolder: false).ext.lowercased()
    }
}
