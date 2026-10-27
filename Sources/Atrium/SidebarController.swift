import AppKit
import AtriumCore

final class SidebarNode: NSObject {
    enum Kind { case section, place, folder, volume }

    let kind: Kind
    let title: String
    let url: URL?
    let isPinned: Bool
    /// nil until the node is first expanded; folders are read only when someone opens them.
    var children: [SidebarNode]?

    init(_ kind: Kind, _ title: String, url: URL? = nil, isPinned: Bool = false, children: [SidebarNode]? = nil) {
        self.kind = kind
        self.title = title
        self.url = url
        self.isPinned = isPinned
        self.children = children
    }

    var isExpandable: Bool { kind == .section || kind == .folder || kind == .volume }
}

/// A middle click opens a folder in a new tab, as in Explorer.
final class SidebarOutlineView: NSOutlineView {
    var onMiddleClick: ((Int) -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0 { onMiddleClick?(row) } else { super.otherMouseDown(with: event) }
    }
}

/// The navigation pane: Quick access (with pinned folders), Cloud (iCloud Drive, Google Drive and other
/// File Provider folders), then This Mac with a folder tree and the drives.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpen: ((URL, _ newTab: Bool) -> Void)?
    var onDrop: (([URL], URL, TransferMode) -> Void)?

    private let outline = SidebarOutlineView()
    private var sections: [SidebarNode] = []
    private var quietSelection = false

    override func loadView() {
        let column = NSTableColumn(identifier: .init("Sidebar"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onMiddleClick = { [weak self] row in
            if let url = (self?.outline.item(atRow: row) as? SidebarNode)?.url { self?.onOpen?(url, true) }
        }
        outline.setAccessibilityLabel("Navigation pane")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(self, selector: #selector(reload), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Settings.changed, object: nil)
        reload()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc func reload() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var quick: [SidebarNode] = []
        var seen = Set<String>()
        func place(_ url: URL, _ title: String? = nil, pinned: Bool = false) {
            guard fm.fileExists(atPath: url.path), seen.insert(url.path).inserted else { return }
            quick.append(SidebarNode(.place, title ?? fm.displayName(atPath: url.path), url: url, isPinned: pinned))
        }
        place(home)
        place(home.appendingPathComponent("Desktop"))
        place(home.appendingPathComponent("Documents"))
        place(home.appendingPathComponent("Downloads"))
        place(URL(fileURLWithPath: "/Applications"))
        for url in Settings.pinned { place(url, pinned: true) }

        // Cloud folders open like any other tree; Google Drive's holds My Drive and Shared drives.
        var cloud: [SidebarNode] = []
        let iCloud = CloudPlaces.iCloudDrive(home: home)
        if fm.fileExists(atPath: iCloud.path) { cloud.append(SidebarNode(.folder, "iCloud Drive", url: iCloud)) }
        let storage = CloudPlaces.storage(home: home)
        let accounts = ((try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let described = accounts.map { CloudPlaces.describe(folderName: $0.lastPathComponent) }
        for (url, (provider, account)) in zip(accounts, described) {
            let several = described.filter { $0.provider == provider }.count > 1
            let title = several && account != nil ? "\(provider) (\(account!))" : provider
            cloud.append(SidebarNode(.folder, title, url: url))
        }

        var mac = [SidebarNode(.folder, fm.displayName(atPath: home.path), url: home)]
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey]
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let name = (try? volume.resourceValues(forKeys: Set(keys)).volumeLocalizedName) ?? volume.lastPathComponent
            mac.append(SidebarNode(.volume, name, url: volume))
        }

        let expanded = Set(sections.flatMap(expandedPaths))
        sections = [SidebarNode(.section, "Quick access", children: quick)]
        if !cloud.isEmpty { sections.append(SidebarNode(.section, "Cloud", children: cloud)) }
        sections.append(SidebarNode(.section, "This Mac", children: mac))
        outline.reloadData()
        for section in sections {
            outline.expandItem(section)
            restore(expanded, in: section.children ?? [])
        }
    }

    private func expandedPaths(_ node: SidebarNode) -> [String] {
        guard outline.isItemExpanded(node) else { return [] }
        return (node.url.map { [$0.path] } ?? []) + (node.children ?? []).flatMap(expandedPaths)
    }

    private func restore(_ paths: Set<String>, in nodes: [SidebarNode]) {
        for node in nodes where node.url.map({ paths.contains($0.path) }) == true {
            outline.expandItem(node)
            restore(paths, in: node.children ?? [])
        }
    }

    /// Selects the row for the folder being shown, if one is visible; nothing is expanded to find it.
    func highlight(_ url: URL) {
        quietSelection = true
        defer { quietSelection = false }
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, node.url?.key == url.key {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        outline.deselectAll(nil)
    }

    private func subfolders(of url: URL) -> [SidebarNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = Settings.showHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)) ?? []
        return urls
            .filter { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { SidebarNode(.folder, FileManager.default.displayName(atPath: $0.path), url: $0) }
    }

    private func node(_ item: Any?) -> SidebarNode? { item as? SidebarNode }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = node(item) else { return sections.count }
        if node.children == nil, let url = node.url { node.children = subfolders(of: url) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = node(item) else { return sections[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = node(item) else { return false }
        return node.isExpandable && (node.children.map { !$0.isEmpty } ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { node(item)?.kind == .section }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { node(item)?.kind != .section }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = node(item) else { return nil }
        let isSection = node.kind == .section
        let id = NSUserInterfaceItemIdentifier(isSection ? "HeaderCell" : "DataCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id, image: !isSection)
        cell.textField?.stringValue = node.title
        if let url = node.url { cell.imageView?.image = IconCache.shared.icon(forPath: url.path) }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, image: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                           text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4)]
        if image {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            constraints += [icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    // MARK: Opening

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !quietSelection, let url = node(outline.item(atRow: outline.selectedRow))?.url else { return }
        onOpen?(url, false)
    }

    @objc private func clicked() {
        guard outline.clickedRow >= 0, let url = node(outline.item(atRow: outline.clickedRow))?.url else { return }
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        onOpen?(url, newTab)
    }

    // MARK: Drop onto a folder

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard index == NSOutlineViewDropOnItemIndex, let target = node(item)?.url, let urls = info.fileURLs,
              let mode = DragRules.mode(for: info, sources: urls, target: target) else { return [] }
        return mode == .copy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = node(item)?.url, let urls = info.fileURLs,
              let mode = DragRules.mode(for: info, sources: urls, target: target) else { return false }
        onDrop?(urls, target, mode)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = node(item), node.kind == .folder || node.kind == .place, let url = node.url else { return nil }
        return url as NSURL
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let node = node(outline.item(atRow: outline.clickedRow)), let url = node.url else { return }
        menu.addItem(item("Open in New Tab", #selector(openInNewTab(_:)), url))
        if node.isPinned {
            menu.addItem(item("Unpin from Quick access", #selector(unpin(_:)), url))
        } else if node.kind != .place {
            menu.addItem(item("Pin to Quick access", #selector(pin(_:)), url))
        }
        if node.kind == .volume, url.path != "/" {
            menu.addItem(.separator())
            menu.addItem(item("Eject “\(node.title)”", #selector(eject(_:)), url))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open in Terminal", #selector(openInTerminal(_:)), url))
        menu.addItem(item("Copy as Path", #selector(copyPath(_:)), url))
    }

    private func item(_ title: String, _ action: Selector, _ url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        return item
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) { (sender.representedObject as? URL).map { onOpen?($0, true) } }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Settings.pinned = Settings.pinned.filter { $0.key != url.key } + [url]
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Settings.pinned = Settings.pinned.filter { $0.key != url.key }
    }

    @objc private func eject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { NSAlert(error: error).runModal() }
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) { (sender.representedObject as? URL).map(Shell.openInTerminal) }

    @objc private func copyPath(_ sender: NSMenuItem) { (sender.representedObject as? URL).map { Shell.copyPaths([$0]) } }
}
