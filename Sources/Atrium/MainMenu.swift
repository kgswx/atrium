import AppKit
import AtriumCore

/// The menu bar. Mac shortcuts live here; the Windows ones are added on top by `KeyMap`.
enum MainMenu {
    private typealias B = BrowserWindowController

    static func build() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(top("Atrium", app()))
        bar.addItem(top("File", file()))
        bar.addItem(top("Edit", edit()))
        bar.addItem(top("View", view()))
        bar.addItem(top("Go", go()))
        let window = window()
        bar.addItem(top("Window", window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Atrium on GitHub", #selector(AppDelegate.openWebsite(_:))))
        bar.addItem(top("Help", help))
        NSApp.helpMenu = help
        return bar
    }

    private static func app() -> NSMenu {
        let menu = NSMenu(title: "Atrium")
        menu.addItem(item("About Atrium", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Use Atrium Instead of Finder for Folders", #selector(AppDelegate.toggleDefaultViewer(_:))))
        menu.addItem(item("Start Quietly at Login", #selector(AppDelegate.toggleLoginItem(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Atrium", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Atrium", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Tab", #selector(NSResponder.newWindowForTab(_:)), "t"))
        menu.addItem(item("New Folder", #selector(B.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item("New Text Document", #selector(B.newTextDocument(_:)), "n", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Open", #selector(B.openSelection(_:)), "o"))
        menu.addItem(item("Open", #selector(B.openSelection(_:)), key(NSDownArrowFunctionKey), hidden: true))
        menu.addItem(item("Open in New Tab", #selector(B.openInNewTab(_:))))
        menu.addItem(item("Close Tab", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(B.renameItem(_:)), key(NSF2FunctionKey), []))
        menu.addItem(item("Move to Trash", #selector(B.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item("Delete Immediately…", #selector(B.deleteImmediately(_:)), "\u{8}", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Compress to ZIP File", #selector(B.compress(_:))))
        menu.addItem(item("Copy as Path", #selector(B.copyPath(_:)), "c", [.command, .option]))
        menu.addItem(item("Open in Terminal", #selector(B.openInTerminal(_:))))
        menu.addItem(item("Open in Finder", #selector(B.openInFinder(_:))))
        menu.addItem(item("Pin to Quick Access", #selector(B.pinToQuickAccess(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Properties", #selector(B.showProperties(_:)), "i"))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(B.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(B.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(B.paste(_:)), "v"))
        menu.addItem(item("Move Item Here", #selector(B.moveHere(_:)), "v", [.command, .option]))
        menu.addItem(item("Duplicate", #selector(B.duplicate(_:)), "d"))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(item("Invert Selection", #selector(B.invertSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Find", #selector(B.focusSearch(_:)), "f"))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: "View")
        let sort = NSMenu(title: "Sort by")
        for key in SortKey.allCases { sort.addItem(item(key.title, #selector(B.sortBy(_:)), value: key.rawValue)) }
        sort.addItem(.separator())
        sort.addItem(item("Ascending", #selector(B.sortAscending(_:))))
        sort.addItem(item("Descending", #selector(B.sortDescending(_:))))
        menu.addItem(top("Sort by", sort))
        let group = NSMenu(title: "Group by")
        for key in GroupKey.allCases { group.addItem(item(key.title, #selector(B.groupBy(_:)), value: key.rawValue)) }
        menu.addItem(top("Group by", group))
        menu.addItem(.separator())
        menu.addItem(item("Navigation Pane", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Preview Pane", #selector(B.togglePreview(_:)), "p", [.command, .shift]))
        menu.addItem(item("Hidden Items", #selector(B.toggleHidden(_:)), ".", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Refresh", #selector(B.refresh(_:)), "r"))
        return menu
    }

    private static func go() -> NSMenu {
        let menu = NSMenu(title: "Go")
        menu.addItem(item("Back", #selector(B.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(B.goForward(_:)), "]"))
        menu.addItem(item("Up", #selector(B.goUp(_:)), key(NSUpArrowFunctionKey)))
        menu.addItem(.separator())
        let places: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Home", "~", "h", [.command, .shift]),
            ("Desktop", "~/Desktop", "d", [.command, .shift]),
            ("Documents", "~/Documents", "o", [.command, .shift]),
            ("Downloads", "~/Downloads", "l", [.command, .option]),
            ("Applications", "/Applications", "a", [.command, .shift]),
            ("iCloud Drive", "~/Library/Mobile Documents/com~apple~CloudDocs", "i", [.command, .shift]),
        ]
        for (title, path, key, flags) in places {
            menu.addItem(item(title, #selector(B.goPlace(_:)), key, flags, value: path))
        }
        menu.addItem(.separator())
        menu.addItem(item("Go to Folder…", #selector(B.focusAddressBar(_:)), "g", [.command, .shift]))
        menu.addItem(item("Address Bar", #selector(B.focusAddressBar(_:)), "l"))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func top(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        item.submenu = submenu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ flags: NSEvent.ModifierFlags = [.command], value: String? = nil,
                             hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : flags
        item.representedObject = value
        if hidden {
            // Works as a shortcut, never shown: Cmd+Down opens, as in Finder.
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func key(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
}
