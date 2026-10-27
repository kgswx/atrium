#if DEBUG
import AppKit
import AtriumCore

/// `Atrium --selftest [report.txt]`, debug builds only: drives a real (invisible) window with Explorer's keys in a
/// scratch folder and writes PASS/FAIL per step. Keys go through `KeyMap` and the menu shortcuts as in normal use,
/// then to the window's responder chain directly, so the test never needs to take focus from the app you are using.
enum SelfTest {
    static func run(report: String?) {
        var (lines, failures) = autoreleasepool { drive() }
        // The window is closed and the test holds nothing now: what is left is what an idle Atrium keeps.
        let end = Date().addingTimeInterval(2)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let freed = BrowserWindowController.alive == 0
        lines.append((freed ? "PASS " : "FAIL ") + "the closed window's controller was freed (\(BrowserWindowController.alive) left)")
        if !freed { failures += 1 }
        lines.append("INFO memory after closing the window: \(Memory.footprint / 1_048_576) MB (pid \(getpid()))")
        lines.append("INFO windows still around: " + NSApp.windows.map { "\(type(of: $0)) '\($0.title)' visible=\($0.isVisible)" }.joined(separator: ", "))
        if ProcessInfo.processInfo.environment["ATRIUM_FOOTPRINT"] != nil {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            probe.arguments = ["-p", "\(getpid())"]
            let pipe = Pipe()
            probe.standardOutput = pipe
            try? probe.run()
            probe.waitUntilExit()
            lines.append(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        lines.append(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        let text = lines.joined(separator: "\n") + "\n"
        if let report { try? text.write(toFile: report, atomically: true, encoding: .utf8) } else { print(text) }
        // ATRIUM_RESTART=1: finish by restarting in place, as an idle Atrium does, so its memory can be read after.
        if ProcessInfo.processInfo.environment["ATRIUM_RESTART"] != nil { AppDelegate.shared.restartIfIdle() }
        exit(failures == 0 ? 0 : 1)
    }

    private static func drive() -> ([String], Int) {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/selftest-\(UUID().uuidString.prefix(6))")
        try! fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try! "bye".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let saved = (Settings.showHidden, Settings.groupKey, Settings.previewPane)

        var lines: [String] = []
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            lines.append((ok ? "PASS " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        func wait(_ seconds: Double = 0.5, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if done() { return }
            }
        }
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(path).path) }
        func names(_ c: BrowserWindowController) -> [String] { c.list.allEntries.map(\.name).sorted() }

        let c = AppDelegate.shared.openWindow(at: root)
        let w = c.window!
        w.alphaValue = 0
        wait(3) { c.list.allEntries.count == 3 }
        check("opens the folder and lists it", names(c) == ["a.txt", "b.txt", "sub"])
        w.makeFirstResponder(c.list.table)

        /// Each real key press is its own run-loop pass and so its own undo group; the test is one long pass,
        /// so close whatever group the previous step opened (the next registration opens a new one by itself).
        func freshUndoGroup() {
            let undo = FileOperations.shared.undoManager
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        /// What AppKit does with a key press in the key window, minus needing to be the key window.
        func deliver(_ action: Selector, from item: NSMenuItem?) {
            var responder: NSResponder? = w.firstResponder
            var chain: [AnyObject] = []
            while let r = responder { chain.append(r); responder = r.nextResponder }
            chain += [w, c]
            guard let target = chain.first(where: { $0.responds(to: action) }) else { return }
            if let item, let validator = target as? NSUserInterfaceValidations, !validator.validateUserInterfaceItem(item) { return }
            _ = target.perform(action, with: item)
        }
        func menuItem(for event: NSEvent, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            for item in menu?.items ?? [] {
                if let found = menuItem(for: event, in: item.submenu) { return found }
                guard !item.keyEquivalent.isEmpty, item.action != nil else { continue }
                let chars = event.charactersIgnoringModifiers ?? ""
                if item.keyEquivalent.lowercased() == chars.lowercased(),
                   item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == flags { return item }
            }
            return nil
        }
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
            freshUndoGroup()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
            if let item = menuItem(for: event) {
                deliver(item.action!, from: item)
            } else if let mapped = KeyMap.action(for: event, typing: w.firstResponder is NSText) {
                switch mapped {
                case .send(let action): deliver(action, from: nil)
                case .menu(let translated): if let item = menuItem(for: translated) { deliver(item.action!, from: item) }
                }
            } else {
                w.firstResponder?.keyDown(with: event)
            }
            wait(0.05)
        }
        func select(_ name: String) {
            guard let row = (0..<c.list.table.numberOfRows).first(where: { c.list.entry(at: $0)?.name == name }) else { return }
            c.list.table.selectRowIndexes([row], byExtendingSelection: false)
        }
        func typeName(_ text: String) {
            freshUndoGroup()
            guard let editor = w.firstResponder as? NSTextView else { return }
            editor.insertText(text, replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            wait(0.1)
        }
        let F2 = String(Character(UnicodeScalar(UInt32(NSF2FunctionKey))!))

        select("a.txt")
        key(8, "c", .control)
        check("Ctrl+C copies the file", Clipboard.fileURLs.map(\.lastPathComponent) == ["a.txt"])
        key(9, "v", .control)
        wait(2) { exists("a - Copy.txt") && c.list.allEntries.count == 4 }
        check("Ctrl+V in the same folder makes “a - Copy.txt”", exists("a - Copy.txt"))
        check("the copy is selected after pasting", c.list.selectedEntries.map(\.name) == ["a - Copy.txt"])

        select("b.txt")
        key(7, "x", .control)
        check("Ctrl+X marks the file as cut", Clipboard.cutPaths.contains(root.appendingPathComponent("b.txt").key))
        select("sub")
        key(36, "\r")
        wait(2) { c.folder.key == root.appendingPathComponent("sub").key }
        check("Return opens the folder", c.folder.lastPathComponent == "sub")
        w.makeFirstResponder(c.list.table)
        key(9, "v", .control)
        wait(2) { exists("sub/b.txt") }
        check("paste after cut moves the file", exists("sub/b.txt") && !exists("b.txt"))
        check("the cut is cleared after the move", Clipboard.cutPaths.isEmpty)

        key(51, "\u{7f}")
        wait(2) { c.folder.key == root.key && c.list.allEntries.count == 3 }
        check("Backspace goes back", c.folder.key == root.key)
        check("…with the folder we came from selected", c.list.selectedEntries.map(\.name) == ["sub"])

        key(45, "N", [.control, .shift])
        wait(2) { c.list.isRenaming }
        check("Ctrl+Shift+N makes a folder and starts renaming", exists("New folder") && c.list.isRenaming)
        typeName("Projects")
        wait(1) { exists("Projects") }
        check("typing a name and Return renames it", exists("Projects") && !exists("New folder"))
        w.makeFirstResponder(c.list.table)
        key(6, "z", .control)
        wait(1) { exists("New folder") }
        check("Ctrl+Z undoes the rename", exists("New folder") && !exists("Projects"))
        key(16, "y", .control)
        wait(1) { exists("Projects") }
        check("Ctrl+Y redoes it", exists("Projects"))

        wait(1) { c.list.allEntries.contains { $0.name == "a.txt" } }
        select("a.txt")
        w.makeFirstResponder(c.list.table)
        key(120, F2)
        wait(0.3)
        let range = (w.firstResponder as? NSTextView)?.selectedRange()
        check("F2 renames with only the name before the extension selected", range == NSRange(location: 0, length: 1))
        typeName("alpha")
        wait(1) { exists("alpha.txt") }
        check("…and keeps the extension", exists("alpha.txt") && !exists("a.txt"))

        w.makeFirstResponder(c.list.table)
        wait(1) { c.list.allEntries.contains { $0.name == "alpha.txt" } }
        select("alpha.txt")
        key(117, String(Character(UnicodeScalar(UInt32(NSDeleteFunctionKey))!)))
        wait(1) { !exists("alpha.txt") }
        check("Delete moves to the Trash", !exists("alpha.txt"))
        wait(1) { !c.list.selectedEntries.isEmpty }
        check("…and selects the next item", !c.list.selectedEntries.isEmpty)
        key(6, "z", .control)
        wait(1) { exists("alpha.txt") }
        check("Ctrl+Z brings it back from the Trash", exists("alpha.txt"))

        key(126, "", .option)
        wait(2) { c.folder.key == root.deletingLastPathComponent().key }
        check("Option+Up goes up a level", c.folder.key == root.deletingLastPathComponent().key)
        wait(1) { !c.list.selectedEntries.isEmpty }
        check("…with the folder we left selected", c.list.selectedEntries.first?.url.key == root.key)
        key(123, "", .option)
        wait(2) { c.folder.key == root.key }
        check("Option+Left goes back", c.folder.key == root.key)

        w.makeFirstResponder(c.list.table)
        let previewWas = c.isPreviewShown
        key(35, "π", .option)
        check("Option+P toggles the preview pane", c.isPreviewShown != previewWas)
        key(35, "π", .option)
        check("…and back", c.isPreviewShown == previewWas)

        key(37, "l", .control)
        check("all toolbar items fit (none pushed into the overflow menu)", Set(c.window?.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
              .isSuperset(of: ["back", "forward", "up", "refresh", "address", "search"]))
        check("Ctrl+L puts a path in the address bar", (w.firstResponder as? NSTextView)?.string == root.path)
        if let editor = w.firstResponder as? NSTextView {
            editor.string = "sub"
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        wait(2) { c.folder.lastPathComponent == "sub" }
        check("typing a relative path and Return goes there", c.folder.lastPathComponent == "sub")
        c.goBack(nil)
        wait(2) { c.folder.key == root.key && !c.list.allEntries.isEmpty }

        try? "x".write(to: root.appendingPathComponent(".dotfile"), atomically: true, encoding: .utf8)
        Settings.showHidden = true
        wait(2) { c.list.allEntries.contains { $0.name == ".dotfile" } }
        check("hidden items show when switched on", c.list.allEntries.contains { $0.name == ".dotfile" })
        Settings.showHidden = false
        wait(2) { !c.list.allEntries.contains { $0.name == ".dotfile" } }
        check("…and hide again", !c.list.allEntries.contains { $0.name == ".dotfile" })

        Settings.groupKey = .kind
        wait(0.3)
        check("Group by Type adds group rows", c.list.table.numberOfRows > c.list.allEntries.count)
        Settings.groupKey = .none

        c.searchField.stringValue = "copy"
        c.searchChanged(c.searchField)
        wait(1) { c.list.allEntries.count == 1 }
        check("search finds “a - Copy.txt” in this folder", c.list.allEntries.map(\.name) == ["a - Copy.txt"])
        c.searchField.stringValue = "b.txt"
        c.searchChanged(c.searchField)
        wait(6) { c.list.allEntries.contains { $0.name == "b.txt" } }
        lines.append((c.list.allEntries.contains { $0.name == "b.txt" } ? "PASS " : "SKIP ")
                     + "search finds sub/b.txt through Spotlight (SKIP = not indexed yet)")
        c.searchField.stringValue = ""
        c.searchChanged(c.searchField)
        wait(0.5)
        check("clearing the search shows the folder again", c.list.allEntries.count >= 4)

        // The full path, from the drive down.
        let chain = AddressBar.chain(for: root)
        check("the address bar path starts at the drive and has every folder", chain.first?.path == "/"
              && chain.count == root.pathComponents.count && chain.last?.key == root.key)

        // Folder colour and symbol, on the folder itself.
        wait(2) { c.list.allEntries.contains { $0.name == "sub" } }
        select("sub")
        let red = NSMenuItem(title: "Red", action: #selector(BrowserWindowController.setFolderColor(_:)), keyEquivalent: "")
        red.tag = FolderColor.red.rawValue
        c.setFolderColor(red)
        let star = NSMenuItem(title: "Star", action: #selector(BrowserWindowController.setFolderSymbol(_:)), keyEquivalent: "")
        star.representedObject = "star.fill"
        c.setFolderSymbol(star)
        wait(2) { c.list.allEntries.first { $0.name == "sub" }?.style.symbol == "star.fill" }
        let styled = c.list.allEntries.first { $0.name == "sub" }?.style
        check("Folder colour sets the Finder colour tag", (try? root.appendingPathComponent("sub").resourceValues(forKeys: [.tagNamesKey]).tagNames) == ["Red"])
        check("…and the list shows the folder red with a star", styled?.color == .red && styled?.symbol == "star.fill")
        let none = NSMenuItem(title: "No colour", action: #selector(BrowserWindowController.setFolderColor(_:)), keyEquivalent: "")
        select("sub")
        c.setFolderColor(none)
        c.setFolderSymbol(NSMenuItem(title: "No symbol", action: nil, keyEquivalent: ""))
        wait(2) { c.list.allEntries.first { $0.name == "sub" }?.style.isPlain == true }
        check("No colour and No symbol put it back", c.list.allEntries.first { $0.name == "sub" }?.style.isPlain == true)

        // Optional, against a real cloud folder: ATRIUM_CLOUD_TEST=<folder in Google Drive> scripts/selftest.sh
        // Downloads one small online-only file and frees it again, so nothing is left changed.
        if let cloudPath = ProcessInfo.processInfo.environment["ATRIUM_CLOUD_TEST"] {
            let cloudFolder = URL(fileURLWithPath: cloudPath)
            c.navigate(to: cloudFolder)
            wait(10) { c.list.allEntries.first?.url.deletingLastPathComponent().key == cloudFolder.key }
            lines.append("INFO cloud: folder \(c.folder.lastPathComponent), \(c.list.allEntries.count) items, states \(Set(c.list.allEntries.map { $0.sync.title }))")
            check("cloud: the Status column shows", c.list.table.tableColumn(withIdentifier: .init("Status"))?.isHidden == false)
            check("cloud: files have a sync state", c.list.allEntries.contains { $0.sync != .none })
            let small = c.list.allEntries.first {
                $0.sync == .cloudOnly && ($0.size ?? .max) < 300_000 && ($0.size ?? 0) > 0 && !$0.name.hasPrefix(".")
                    && !["gdoc", "gsheet", "gslides"].contains($0.url.pathExtension)
            }
            if let small {
                func state() -> SyncState? { c.list.allEntries.first { $0.url.key == small.url.key }?.sync }
                select(small.name)
                // Never let an empty selection turn Download now into "download the whole folder".
                if c.list.selectedEntries.map(\.url.key) == [small.url.key] {
                    c.downloadNow(nil)
                    wait(45) { state() == .local }
                    check("cloud: Download now brings the file to this Mac", state() == .local)
                    select(small.name)
                    c.freeUpSpace(nil)
                    wait(45) { state() == .cloudOnly }
                    check("cloud: Free up space makes it online only again", state() == .cloudOnly)
                    select(small.name)
                    c.copyDriveLink(nil)
                    let link = NSPasteboard.general.string(forType: .string) ?? ""
                    check("cloud: Copy Google Drive link gives a Drive link", link.hasPrefix("https://drive.google.com/open?id="))
                } else {
                    check("cloud: the test file could be selected", false)
                }
            } else {
                lines.append("SKIP cloud: no small online-only file in that folder")
            }
            c.navigate(to: root)
            wait(3) { c.folder.key == root.key && !c.list.allEntries.isEmpty }
        }

        c.list.table.deselectAll(nil)
        key(8, "c", [.command, .option])
        check("Copy as Path copies the folder path", NSPasteboard.general.string(forType: .string) == root.path)

        c.showProperties(nil)
        wait(1.5)
        let properties = NSApp.windows.first { $0.title == "\(root.lastPathComponent) Properties" }
        properties?.alphaValue = 0
        check("Properties opens", properties != nil)
        properties?.close()

        // Tabs.
        check("the tab bar shows with one tab", w.tabGroup?.isTabBarVisible == true)
        select("sub")
        key(2, "D", [.control, .shift])
        wait(2) { (w.tabbedWindows?.count ?? 1) == 2 }
        let copy = w.tabbedWindows?.first { $0 !== w }
        copy?.alphaValue = 0
        let twin = copy?.windowController as? BrowserWindowController
        wait(2) { twin?.list.allEntries.isEmpty == false }
        check("Ctrl+Shift+D duplicates the tab", w.tabbedWindows?.count == 2 && twin?.folder.key == c.folder.key)
        check("…with the same history and selection", twin?.history.back == c.history.back
              && twin?.list.selectedEntries.map(\.name) == ["sub"])
        copy?.close()
        wait(0.5)
        w.makeFirstResponder(c.list.table)

        w.close()
        wait(1) { NSApp.activationPolicy() == .accessory }
        check("closing the last window leaves the Dock", NSApp.activationPolicy() == .accessory)

        (Settings.showHidden, Settings.groupKey, Settings.previewPane) = saved
        try? fm.removeItem(at: root)
        return (lines, failures)
    }
}
#endif
