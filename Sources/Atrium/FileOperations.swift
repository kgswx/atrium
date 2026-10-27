import AppKit
import AtriumCore

enum TransferMode { case copy, move }

/// Every change Atrium makes to the file system goes through here, with one undo history for the whole app.
/// Copies and moves run off the main thread; renames, trash and undo are quick and run in place so undo and redo pair up.
final class FileOperations {
    static let shared = FileOperations()
    /// Posted with a status text while something runs, and with nil when it is done.
    static let activity = Notification.Name("AtriumFileActivity")

    let undoManager = UndoManager()
    private let queue = DispatchQueue(label: "io.kgswx.atrium.fileops", qos: .userInitiated)
    private let fm = FileManager.default

    // MARK: Copy and move

    func transfer(_ sources: [URL], to folder: URL, mode: TransferMode, completion: (([URL]) -> Void)? = nil) {
        let folder = folder.standardizedFileURL
        let sources = sources.map(\.standardizedFileURL).filter { source in
            // Never into itself or one of its own subfolders.
            !(folder.path + "/").hasPrefix(source.path + "/")
        }
        guard !sources.isEmpty else { completion?([]); return }
        announce("\(mode == .copy ? "Copying" : "Moving") \(Self.count(sources.count))…")

        queue.async { [self] in
            var done: [(from: URL, to: URL)] = []
            var errors: [String] = []
            var standing: ConflictChoice?

            for (index, source) in sources.enumerated() {
                let samePlace = source.deletingLastPathComponent().key == folder.key
                if samePlace && mode == .move { continue }
                let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                var destination = folder.appendingPathComponent(source.lastPathComponent)

                if samePlace {
                    let name = FileNaming.copyName(for: source.lastPathComponent, isFolder: isFolder) {
                        self.exists(folder.appendingPathComponent($0))
                    }
                    destination = folder.appendingPathComponent(name)
                } else if exists(destination) {
                    let choice = standing ?? DispatchQueue.main.sync {
                        Self.askConflict(name: source.lastPathComponent, folder: folder, more: index < sources.count - 1)
                    }
                    if choice.forAll { standing = choice }
                    switch choice.action {
                    case .skip:
                        continue
                    case .stop:
                        break
                    case .keepBoth:
                        let name = FileNaming.numberedName(for: source.lastPathComponent, isFolder: isFolder) {
                            self.exists(folder.appendingPathComponent($0))
                        }
                        destination = folder.appendingPathComponent(name)
                    case .replace:
                        // The item being replaced goes to the Trash rather than being destroyed.
                        do { try fm.trashItem(at: destination, resultingItemURL: nil) } catch {
                            errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                            continue
                        }
                    }
                    if choice.action == .stop { break }
                }

                do {
                    if mode == .copy { try fm.copyItem(at: source, to: destination) } else { try fm.moveItem(at: source, to: destination) }
                    done.append((source, destination))
                } catch {
                    errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [self] in
                announce(nil)
                if !done.isEmpty {
                    if mode == .copy {
                        let copies = done.map(\.to)
                        registerUndo("Copy") { $0.trash(copies, actionName: "Copy") }
                    } else {
                        let back = done.map { (from: $0.to, to: $0.from) }
                        registerUndo("Move") { $0.relocate(back, actionName: "Move") }
                    }
                }
                if !errors.isEmpty { Self.showErrors(errors, title: mode == .copy ? "Some items couldn't be copied." : "Some items couldn't be moved.") }
                completion?(done.map(\.to))
            }
        }
    }

    // MARK: Quick operations, each registering its own opposite

    /// Moves or renames items in place. Undo moves them back, and that registers the redo.
    @discardableResult
    func relocate(_ pairs: [(from: URL, to: URL)], actionName: String) -> [URL] {
        var done: [(from: URL, to: URL)] = []
        var errors: [String] = []
        for pair in pairs {
            do {
                try fm.moveItem(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                errors.append("\(pair.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !done.isEmpty {
            let back = done.map { (from: $0.to, to: $0.from) }
            registerUndo(actionName) { $0.relocate(back, actionName: actionName) }
        }
        if !errors.isEmpty { Self.showErrors(errors, title: "Some items couldn't be moved.") }
        return done.map(\.to)
    }

    /// Moves items to the Trash. Undo puts them back where they were.
    @discardableResult
    func trash(_ urls: [URL], actionName: String = "Move to Trash") -> [URL] {
        var restored: [(from: URL, to: URL)] = []
        var errors: [String] = []
        for url in urls {
            var inTrash: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &inTrash)
                if let inTrash { restored.append((from: inTrash as URL, to: url)) }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !restored.isEmpty {
            registerUndo(actionName) { $0.relocate(restored, actionName: actionName) }
        }
        if !errors.isEmpty { Self.showErrors(errors, title: "Some items couldn't be moved to the Trash.") }
        return restored.map(\.to)
    }

    /// Deletes for good, after asking. There is no undo, as the question says.
    func deleteImmediately(_ urls: [URL], window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Delete “\(urls[0].lastPathComponent)” permanently?"
            : "Delete these \(urls.count) items permanently?"
        alert.informativeText = "They won't go to the Trash, and this can't be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        var errors: [String] = []
        for url in urls {
            do { try fm.removeItem(at: url) } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { Self.showErrors(errors, title: "Some items couldn't be deleted.") }
        return true
    }

    /// Records something Atrium just created (a new folder, a zip) so Undo moves it to the Trash.
    func registerCreated(_ url: URL, actionName: String) {
        registerUndo(actionName) { $0.trash([url], actionName: actionName) }
    }

    /// Zips the items into the folder: "Name.zip" for one item, "Archive.zip" for several.
    func compress(_ urls: [URL], in folder: URL, completion: @escaping (URL?) -> Void) {
        guard !urls.isEmpty else { return }
        let base = urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip"
        let name = FileNaming.numberedName(for: base, isFolder: false) { self.exists(folder.appendingPathComponent($0)) }
        let zip = folder.appendingPathComponent(name)
        let process = Process()
        if urls.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, zip.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-r", "-y", "-q", name] + urls.map(\.lastPathComponent)
        }
        announce("Compressing \(Self.count(urls.count))…")
        process.terminationHandler = { [self] p in
            DispatchQueue.main.async { [self] in
                announce(nil)
                if p.terminationStatus == 0 {
                    registerCreated(zip, actionName: "Compress")
                    completion(zip)
                } else {
                    Self.showErrors(["zip exited with status \(p.terminationStatus)"], title: "The items couldn't be compressed.")
                    completion(nil)
                }
            }
        }
        do { try process.run() } catch {
            announce(nil)
            Self.showErrors([error.localizedDescription], title: "The items couldn't be compressed.")
        }
    }

    // MARK: Helpers

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// Each operation is one step in the history, whenever it finishes (copies finish later, off any key press).
    /// Inside an undo or redo a group is already open, and this records the opposite step instead.
    private func registerUndo(_ name: String, _ handler: @escaping (FileOperations) -> Void) {
        let standalone = undoManager.groupingLevel == 0
        if standalone { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(name)
        if standalone { undoManager.endUndoGrouping() }
    }

    /// Copies, moves and zips still running; Atrium never restarts itself while one is.
    private(set) var running = 0

    private func announce(_ text: String?) {
        running = max(0, running + (text == nil ? -1 : 1))
        NotificationCenter.default.post(name: Self.activity, object: text)
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    static func showErrors(_ errors: [String], title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = errors.prefix(8).joined(separator: "\n") + (errors.count > 8 ? "\n…and \(errors.count - 8) more" : "")
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Name clashes

    struct ConflictChoice {
        enum Action { case replace, keepBoth, skip, stop }
        let action: Action
        let forAll: Bool
    }

    private static func askConflict(name: String, folder: URL, more: Bool) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(folder.lastPathComponent)” already has an item named “\(name)”."
        alert.informativeText = "Replace moves the existing item to the Trash. Keep Both adds a number to the new one."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Stop")
        if more {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do this for the other clashes too"
        }
        let response = alert.runModal()
        let forAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return ConflictChoice(action: .keepBoth, forAll: forAll)
        case .alertSecondButtonReturn: return ConflictChoice(action: .replace, forAll: forAll)
        case .alertThirdButtonReturn: return ConflictChoice(action: .skip, forAll: forAll)
        default: return ConflictChoice(action: .stop, forAll: true)
        }
    }
}
