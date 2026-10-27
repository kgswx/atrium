import Foundation
import AtriumCore

/// Preferences shared by every window. Changing one posts `Settings.changed` so open windows follow.
enum Settings {
    static let changed = Notification.Name("AtriumSettingsChanged")
    private static let store = UserDefaults.standard

    static func register() {
        store.register(defaults: [
            "ShowHidden": false,
            "PreviewPane": false,
            "SortKey": SortKey.name.rawValue,
            "SortAscending": true,
            "GroupKey": GroupKey.none.rawValue,
            "HotKey": "opt+cmd+e",
            "Pinned": [String](),
            "IdleRestartSeconds": 60.0,
        ])
    }

    static var showHidden: Bool {
        get { store.bool(forKey: "ShowHidden") }
        set { store.set(newValue, forKey: "ShowHidden"); post() }
    }

    static var previewPane: Bool {
        get { store.bool(forKey: "PreviewPane") }
        set { store.set(newValue, forKey: "PreviewPane") }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: store.string(forKey: "SortKey") ?? "") ?? .name }
        set { store.set(newValue.rawValue, forKey: "SortKey"); post() }
    }

    static var sortAscending: Bool {
        get { store.bool(forKey: "SortAscending") }
        set { store.set(newValue, forKey: "SortAscending"); post() }
    }

    static var groupKey: GroupKey {
        get { GroupKey(rawValue: store.string(forKey: "GroupKey") ?? "") ?? .none }
        set { store.set(newValue.rawValue, forKey: "GroupKey"); post() }
    }

    /// For example "opt+cmd+e"; an empty string turns the global hotkey off.
    static var hotKey: String { store.string(forKey: "HotKey") ?? "" }

    /// How long after the last window closes Atrium restarts itself to give memory back; 0 turns it off.
    static var idleRestartSeconds: Double { store.double(forKey: "IdleRestartSeconds") }

    /// Guarded folders (Desktop, Documents...) given a colour or symbol here, so their attributes may be read.
    static var styledGuardedFolders: [String] {
        get { store.stringArray(forKey: "StyledGuardedFolders") ?? [] }
        set { store.set(Array(Set(newValue)).sorted(), forKey: "StyledGuardedFolders") }
    }

    static var pinned: [URL] {
        get { (store.stringArray(forKey: "Pinned") ?? []).map { URL(fileURLWithPath: $0) } }
        set { store.set(newValue.map(\.path), forKey: "Pinned"); post() }
    }

    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }
}
