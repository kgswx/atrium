import Foundation

/// Turns what someone typed in the address bar into folders to try, best guess first.
public enum PathInput {
    static let shortcuts = ["home", "desktop", "documents", "downloads", "pictures", "music", "movies", "videos",
                            "applications", "public"]

    public static func candidates(for raw: String, current: URL, home: URL) -> [URL] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty else { return [] }

        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { return [url.standardizedFileURL] }
        if text == "~" { return [home] }
        if text.hasPrefix("~/") { return [home.appendingPathComponent(String(text.dropFirst(2))).standardizedFileURL] }
        if text.hasPrefix("/") { return [URL(fileURLWithPath: text).standardizedFileURL] }

        // A Windows habit: "Documents\Work" means Documents/Work.
        if text.contains("\\") && !text.contains("/") { text = text.replacingOccurrences(of: "\\", with: "/") }

        var out = [current.appendingPathComponent(text).standardizedFileURL]
        let first = text.split(separator: "/").first.map { String($0).lowercased() } ?? ""
        if shortcuts.contains(first) {
            let rest = text.split(separator: "/").dropFirst().joined(separator: "/")
            let base: URL
            switch first {
            case "home": base = home
            case "applications": base = URL(fileURLWithPath: "/Applications")
            case "videos": base = home.appendingPathComponent("Movies")
            default: base = home.appendingPathComponent(first.prefix(1).uppercased() + first.dropFirst())
            }
            out.append((rest.isEmpty ? base : base.appendingPathComponent(rest)).standardizedFileURL)
        }
        return out
    }
}
