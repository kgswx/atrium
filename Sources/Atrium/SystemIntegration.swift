import AppKit
import UniformTypeIdentifiers

/// Atrium as the Mac's file viewer: "Show in Finder" in other apps (the NSFileViewer default) and folders
/// opened from anywhere but Finder itself (the default app for public.folder). Off puts Finder back for both.
enum DefaultViewer {
    private static let key = "NSFileViewer" as CFString
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.kgswx.atrium" }

    static var isOn: Bool {
        (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String) == bundleID
    }

    static func set(_ on: Bool, completion: ((Error?) -> Void)? = nil) {
        CFPreferencesSetValue(key, on ? bundleID as CFString : nil, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let app = on ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { error in
            DispatchQueue.main.async { completion?(error) }
        }
    }
}

/// Starts Atrium quietly at login with a LaunchAgent (no Dock icon, no window, ready for the hotkey).
enum LoginItem {
    static let label = "io.kgswx.atrium"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isOn: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) throws {
        guard on else {
            // Only the file goes; unloading the job now would quit this running copy.
            try? FileManager.default.removeItem(at: plist)
            return
        }
        let executable = Bundle.main.executableURL?.path ?? "/Applications/Atrium.app/Contents/MacOS/Atrium"
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist)
    }
}
