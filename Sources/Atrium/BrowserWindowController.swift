import AppKit
import AtriumCore

/// One browser tab or window: navigation pane, command bar, Details list, preview pane, status bar,
/// with back/forward/up, the address bar and search in the toolbar.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    private(set) var folder: URL
    var onClose: ((BrowserWindowController) -> Void)?

    private let sidebar = SidebarController()
    let list = FileListController()
    private let preview = PreviewController()
    private let commandBar = CommandBar()
    private let statusBar = StatusBar()
    private let addressBar = AddressBar()
    private var previewItem: NSSplitViewItem!
    private(set) var searchField = NSSearchField()

    private var back: [URL] = []
    private var forward: [URL] = []
    private let watcher = DirectoryWatcher()
    private let search = FolderSearch()
    private var folderEntries: [FileEntry] = []
    private var generation = 0
    private var shownHidden = Settings.showHidden
    private var pendingRename: URL?
    private var reloadAfterRename = false
    private var searchText = ""
    private var searchDelay: DispatchWorkItem?
    private let textUndo = UndoManager()

    private static let frameName = "AtriumBrowser"

    init(folder: URL, selecting: [URL] = []) {
        self.folder = folder
        let window = AtriumWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "AtriumBrowser"
        window.tabbingMode = .automatic
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        buildToolbar(in: window)
        // Restore the last size, unless it is missing or smaller than the window allows.
        if !window.setFrameUsingName(Self.frameName) || window.frame.width < window.minSize.width
            || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1120, height: 700))
            window.center()
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsChanged), name: Settings.changed, object: nil)
        center.addObserver(self, selector: #selector(activity(_:)), name: FileOperations.activity, object: nil)
        center.addObserver(self, selector: #selector(refreshCommands), name: Clipboard.changed, object: nil)
        navigate(to: folder, selecting: selecting, record: false)
        #if DEBUG
        Self.alive += 1
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        #if DEBUG
        Self.alive -= 1
        #endif
    }

    #if DEBUG
    /// Open browser controllers, so the self-test can tell a closed window was really freed.
    static var alive = 0
    #endif

    // MARK: Building the window

    private func buildContent(in window: NSWindow) {
        sidebar.onOpen = { [weak self] url, newTab in newTab ? self?.openTab(url) : self?.navigate(to: url) }
        sidebar.onDrop = { [weak self] urls, target, mode in self?.transfer(urls, to: target, mode: mode) }
        list.browser = self

        let inner = NSSplitViewController()
        inner.splitView.dividerStyle = .thin
        let listItem = NSSplitViewItem(viewController: list)
        listItem.minimumThickness = 320
        previewItem = NSSplitViewItem(viewController: preview)
        previewItem.canCollapse = true
        previewItem.minimumThickness = 220
        previewItem.maximumThickness = 800
        previewItem.holdingPriority = .init(260)
        previewItem.isCollapsed = !Settings.previewPane
        preview.isActive = Settings.previewPane
        inner.addSplitViewItem(listItem)
        inner.addSplitViewItem(previewItem)

        let main = NSViewController()
        main.view = NSView()
        main.addChild(inner)
        for view in [commandBar, inner.view, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            main.view.addSubview(view)
        }
        NSLayoutConstraint.activate([
            commandBar.topAnchor.constraint(equalTo: main.view.safeAreaLayoutGuide.topAnchor),
            commandBar.leadingAnchor.constraint(equalTo: main.view.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            inner.view.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            inner.view.leadingAnchor.constraint(equalTo: main.view.leadingAnchor),
            inner.view.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            inner.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: main.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: main.view.bottomAnchor),
        ])
        buildCommandBar()

        let root = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        root.addSplitViewItem(sidebarItem)
        root.addSplitViewItem(NSSplitViewItem(viewController: main))
        root.splitView.autosaveName = "AtriumSidebarSplit"
        // Size the content before it becomes the window's: an unsized split view shrinks the window to nothing.
        root.view.setFrameSize(NSSize(width: 1120, height: 700))
        NSLayoutConstraint.activate([
            root.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            root.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        window.contentViewController = root
        window.setContentSize(NSSize(width: 1120, height: 700))
    }

    private func buildCommandBar() {
        commandBar.addMenu("plus.circle", title: "New", tip: "New folder or document") { [weak self] in self?.newMenu() ?? NSMenu() }
        commandBar.addSeparator()
        commandBar.add("scissors", tip: "Cut (Ctrl+X)", action: #selector(cut(_:)))
        commandBar.add("doc.on.doc", tip: "Copy (Ctrl+C)", action: #selector(copy(_:)))
        commandBar.add("doc.on.clipboard", tip: "Paste (Ctrl+V)", action: #selector(paste(_:)))
        commandBar.add("character.cursor.ibeam", tip: "Rename (F2)", action: #selector(renameItem(_:)))
        commandBar.add("square.and.arrow.up", tip: "Share", action: #selector(share(_:)))
        commandBar.add("trash", tip: "Move to Trash (Delete)", action: #selector(moveToTrash(_:)))
        commandBar.addSeparator()
        commandBar.addMenu("arrow.up.arrow.down", title: "Sort", tip: "Sort and group") { [weak self] in self?.sortMenu() ?? NSMenu() }
        commandBar.addMenu("eye", title: "View", tip: "Panes and hidden items") { [weak self] in self?.viewMenu() ?? NSMenu() }
        commandBar.addMenu("ellipsis", title: nil, tip: "More") { [weak self] in self?.moreMenu() ?? NSMenu() }
        commandBar.add("sidebar.right", title: "Preview", tip: "Preview pane (Option+P)",
                       action: #selector(togglePreview(_:)), trailing: true, toggle: true)
    }

    private enum Item {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let up = NSToolbarItem.Identifier("up")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let address = NSToolbarItem.Identifier("address")
        static let search = NSToolbarItem.Identifier("search")
    }

    private func buildToolbar(in window: NSWindow) {
        addressBar.onPick = { [weak self] url in self?.navigate(to: url) }
        addressBar.onSubmit = { [weak self] text in self?.go(to: text) }
        addressBar.onFinish = { [weak self] in self?.focusList() }
        // Wide but never so wide that the toolbar overflows: it takes the room, the search box keeps a fixed width.
        addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        addressBar.widthAnchor.constraint(lessThanOrEqualToConstant: 1400).isActive = true
        let wide = addressBar.widthAnchor.constraint(equalToConstant: 1400)
        wide.priority = .defaultLow
        wide.isActive = true

        let toolbar = NSToolbar(identifier: "AtriumToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Item.back, Item.forward, Item.up, Item.refresh, Item.address, Item.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case Item.back: return button("chevron.left", "Back (Option+Left)", #selector(goBack(_:)))
        case Item.forward: return button("chevron.right", "Forward (Option+Right)", #selector(goForward(_:)))
        case Item.up: return button("arrow.up", "Up (Option+Up)", #selector(goUp(_:)))
        case Item.refresh: return button("arrow.clockwise", "Refresh (F5)", #selector(refresh(_:)))
        case Item.address:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = addressBar
            item.label = "Address"
            item.visibilityPriority = .high
            return item
        case Item.search:
            // A plain field with a fixed width: a search toolbar item would collapse to an icon to make room.
            let item = NSToolbarItem(itemIdentifier: id)
            searchField.placeholderString = "Search"
            searchField.sendsSearchStringImmediately = false
            searchField.target = self
            searchField.action = #selector(searchChanged(_:))
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
            item.view = searchField
            item.label = "Search"
            return item
        default:
            return nil
        }
    }

    // MARK: Navigation

    func navigate(to url: URL, selecting: [URL] = [], record: Bool = true) {
        let url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        guard isDirectory.boolValue else {
            navigate(to: url.deletingLastPathComponent(), selecting: [url], record: record)
            return
        }
        if record && url.key != folder.key {
            back.append(folder)
            forward.removeAll()
        }
        folder = url
        clearSearch()
        load(selecting: selecting, scrollToTop: true)
        watcher.watch(url) { [weak self] in self?.reload() }
        addressBar.url = url
        window?.title = FileManager.default.displayName(atPath: url.path)
        window?.representedURL = url
        sidebar.highlight(url)
        refreshCommands()
    }

    private func go(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), let web = URL(string: trimmed) {
            NSWorkspace.shared.open(web)
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = PathInput.candidates(for: text, current: folder, home: home)
        guard let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let alert = NSAlert()
            alert.messageText = "Atrium can't find “\(trimmed)”."
            alert.informativeText = "Check the spelling and try again."
            alert.beginSheetModal(for: window!) { _ in self.addressBar.beginEditing() }
            return
        }
        navigate(to: hit)
        focusList()
    }

    func reload() {
        if list.isRenaming { reloadAfterRename = true; return }
        load(selecting: nil, scrollToTop: false)
    }

    private func load(selecting: [URL]?, scrollToTop: Bool) {
        generation += 1
        let ticket = generation, url = folder, hidden = Settings.showHidden
        shownHidden = hidden
        let keep = selecting ?? list.selectedURLs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DirectoryLoader.entries(in: url, includeHidden: hidden) }
            DispatchQueue.main.async {
                guard let self, ticket == self.generation else { return }
                switch result {
                case .success(let entries):
                    self.folderEntries = entries
                    if self.searchText.isEmpty { self.list.show(entries, selecting: keep, scrollToTop: scrollToTop) }
                case .failure(let error):
                    self.folderEntries = []
                    self.list.show([], selecting: [], scrollToTop: true, emptyText: Self.describe(error))
                }
                if let rename = self.pendingRename {
                    self.pendingRename = nil
                    self.list.beginRename(rename)
                }
                self.selectionChanged()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            return "Atrium isn't allowed to open this folder.\nAllow it in System Settings > Privacy & Security > Files and Folders, or Full Disk Access."
        }
        return error.localizedDescription
    }

    func openTab(_ url: URL) { AppDelegate.shared.openTab(at: url, beside: self) }

    private func focusList() { window?.makeFirstResponder(list.table) }

    @objc func goBack(_ sender: Any?) {
        guard let previous = back.popLast() else { return }
        forward.append(folder)
        navigate(to: previous, selecting: [folder], record: false)
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forward.popLast() else { return }
        back.append(folder)
        navigate(to: next, record: false)
    }

    @objc func goUp(_ sender: Any?) {
        guard folder.path != "/" else { return }
        navigate(to: folder.deletingLastPathComponent(), selecting: [folder])
    }

    @objc func goPlace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        navigate(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    @objc func refresh(_ sender: Any?) { reload() }

    @objc func focusAddressBar(_ sender: Any?) { addressBar.beginEditing() }

    @objc func focusSearch(_ sender: Any?) { window?.makeFirstResponder(searchField) }

    override func newWindowForTab(_ sender: Any?) { openTab(FileManager.default.homeDirectoryForCurrentUser) }

    // MARK: Opening

    @objc func openSelection(_ sender: Any?) {
        let selected = list.selectedEntries
        let folders = selected.filter(\.isFolder)
        for file in selected where !file.isFolder { NSWorkspace.shared.open(file.url) }
        guard let first = folders.first else { return }
        navigate(to: first.url)
        for other in folders.dropFirst() { openTab(other.url) }
    }

    @objc func openInNewTab(_ sender: Any?) {
        for entry in list.selectedEntries where entry.isFolder { openTab(entry.url) }
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(list.selectedURLs, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOther(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        let urls = list.selectedURLs
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Clipboard

    @objc func cut(_ sender: Any?) { Clipboard.put(list.selectedURLs, cut: true) }

    @objc func copy(_ sender: Any?) { Clipboard.put(list.selectedURLs, cut: false) }

    @objc func paste(_ sender: Any?) {
        let urls = Clipboard.fileURLs
        guard !urls.isEmpty else { return }
        let cut = Clipboard.cutPaths
        let isCut = !cut.isEmpty && Set(urls.map(\.key)).isSubset(of: cut)
        transfer(urls, to: folder, mode: isCut ? .move : .copy) { if isCut { Clipboard.clearCut() } }
    }

    /// Finder's Option+Cmd+V: paste as a move whatever was copied.
    @objc func moveHere(_ sender: Any?) {
        let urls = Clipboard.fileURLs
        guard !urls.isEmpty else { return }
        transfer(urls, to: folder, mode: .move) { Clipboard.clearCut() }
    }

    @objc func duplicate(_ sender: Any?) { transfer(list.selectedURLs, to: folder, mode: .copy) }

    func transfer(_ urls: [URL], to target: URL, mode: TransferMode, then: (() -> Void)? = nil) {
        FileOperations.shared.transfer(urls, to: target, mode: mode) { [weak self] made in
            then?()
            guard let self else { return }
            self.load(selecting: target.key == self.folder.key ? made : nil, scrollToTop: false)
        }
    }

    // MARK: Changing things

    @objc func newFolder(_ sender: Any?) { create("New folder", isFolder: true) }

    @objc func newTextDocument(_ sender: Any?) { create("New Text Document.txt", isFolder: false) }

    private func create(_ base: String, isFolder: Bool) {
        guard searchText.isEmpty else { return }
        let here = folder
        let name = FileNaming.numberedName(for: base, isFolder: isFolder) {
            FileManager.default.fileExists(atPath: here.appendingPathComponent($0).path)
        }
        let url = here.appendingPathComponent(name)
        do {
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            presentError(error)
            return
        }
        FileOperations.shared.registerCreated(url, actionName: isFolder ? "New Folder" : "New Text Document")
        pendingRename = url
        load(selecting: [url], scrollToTop: false)
    }

    @objc func renameItem(_ sender: Any?) {
        guard let url = list.selectedURLs.first else { return }
        list.beginRename(url)
    }

    /// Called by the list when an in-place rename ends; `name` is nil when it was cancelled or unchanged.
    func renameFinished(_ entry: FileEntry, to name: String?) {
        defer {
            if reloadAfterRename {
                reloadAfterRename = false
                reload()
            }
        }
        guard let name, name != entry.name else { return }
        if let problem = FileNaming.problem(with: name) {
            warn(problem)
            return
        }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        let caseOnly = name.lowercased() == entry.name.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            warn("There's already an item named “\(name)” here.")
            return
        }
        if !entry.isFolder && FileNaming.changesExtension(from: entry.name, to: name) {
            let old = FileNaming.split(entry.name, isFolder: false).ext, new = FileNaming.split(name, isFolder: false).ext
            let alert = NSAlert()
            alert.messageText = new.isEmpty ? "Remove the extension “.\(old)”?" : "Change the extension to “.\(new)”?"
            alert.informativeText = "If you change it, the file may open in a different app, or not open at all."
            alert.addButton(withTitle: new.isEmpty ? "Remove" : "Use .\(new)")
            alert.addButton(withTitle: old.isEmpty ? "Cancel" : "Keep .\(old)")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let done = FileOperations.shared.relocate([(from: entry.url, to: target)], actionName: "Rename")
        reloadAfterRename = false
        load(selecting: done, scrollToTop: false)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = list.selectedURLs
        guard !urls.isEmpty, !list.isRenaming else { return }
        let next = list.neighbour(after: urls)
        FileOperations.shared.trash(urls)
        load(selecting: next.map { [$0] } ?? [], scrollToTop: false)
    }

    @objc func delete(_ sender: Any?) { moveToTrash(sender) }

    @objc func deleteImmediately(_ sender: Any?) {
        let urls = list.selectedURLs
        guard !urls.isEmpty else { return }
        let next = list.neighbour(after: urls)
        if FileOperations.shared.deleteImmediately(urls, window: window) {
            load(selecting: next.map { [$0] } ?? [], scrollToTop: false)
        }
    }

    @objc func compress(_ sender: Any?) {
        FileOperations.shared.compress(list.selectedURLs, in: folder) { [weak self] zip in
            self?.load(selecting: zip.map { [$0] } ?? [], scrollToTop: false)
        }
    }

    @objc override func selectAll(_ sender: Any?) { list.selectAll() }

    @objc func selectNone(_ sender: Any?) { list.table.deselectAll(nil) }

    @objc func invertSelection(_ sender: Any?) { list.invertSelection() }

    // MARK: Other actions

    /// The selection, or the folder being shown when nothing is selected.
    private var targets: [URL] { list.selectedURLs.isEmpty ? [folder] : list.selectedURLs }

    private var targetFolders: [URL] {
        let folders = list.selectedEntries.filter(\.isFolder).map(\.url)
        return folders.isEmpty ? [folder] : folders
    }

    @objc func copyPath(_ sender: Any?) { Shell.copyPaths(targets) }

    @objc func openInTerminal(_ sender: Any?) { Shell.openInTerminal(targetFolders[0]) }

    @objc func openInFinder(_ sender: Any?) { Shell.openInFinder(targetFolders) }

    @objc func pinToQuickAccess(_ sender: Any?) {
        let urls = targetFolders
        Settings.pinned = Settings.pinned.filter { pin in !urls.contains { $0.key == pin.key } } + urls
    }

    @objc func showProperties(_ sender: Any?) { PropertiesWindowController.show(for: targets) }

    @objc func share(_ sender: Any?) {
        let urls = list.selectedURLs
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        if let button = sender as? NSView, button.window != nil {
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let row = list.table.selectedRowIndexes.first {
            picker.show(relativeTo: list.table.rect(ofRow: row), of: list.table, preferredEdge: .minY)
        }
    }

    // MARK: View

    @objc func togglePreview(_ sender: Any?) {
        let show = previewItem.isCollapsed
        previewItem.animator().isCollapsed = !show
        preview.isActive = show
        preview.urls = list.selectedURLs
        Settings.previewPane = show
        refreshCommands()
    }

    var isPreviewShown: Bool { !previewItem.isCollapsed }

    @objc func toggleHidden(_ sender: Any?) { Settings.showHidden.toggle() }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let key = SortKey(rawValue: sender.representedObject as? String ?? "") else { return }
        if key == Settings.sortKey { Settings.sortAscending.toggle() } else {
            Settings.sortKey = key
            Settings.sortAscending = key == .name || key == .kind
        }
    }

    @objc func sortAscending(_ sender: Any?) { Settings.sortAscending = true }

    @objc func sortDescending(_ sender: Any?) { Settings.sortAscending = false }

    @objc func groupBy(_ sender: NSMenuItem) {
        guard let key = GroupKey(rawValue: sender.representedObject as? String ?? "") else { return }
        Settings.groupKey = key
    }

    @objc private func settingsChanged() {
        if Settings.showHidden != shownHidden {
            reload()
        } else {
            list.rebuild()
        }
    }

    // MARK: Search

    @objc func searchChanged(_ sender: NSSearchField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        searchDelay?.cancel()
        guard !text.isEmpty else {
            endSearch()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.runSearch(text) }
        searchDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Matches in this folder show at once; matches further down arrive from Spotlight a moment later.
    private func runSearch(_ text: String) {
        searchText = text
        let root = folder
        let here = Listing.filter(folderEntries, matching: text)
        list.show(here, selecting: [], searchRoot: root, scrollToTop: true)
        statusBar.right.stringValue = "Searching…"
        selectionChanged()
        search.start(text, in: root, includeHidden: Settings.showHidden) { [weak self] found in
            guard let self, self.searchText == text, self.folder == root else { return }
            var seen = Set(here.map(\.url.key))
            let all = here + found.filter { seen.insert($0.url.key).inserted }
            self.list.show(all, selecting: self.list.selectedURLs, searchRoot: root, scrollToTop: false)
            self.statusBar.right.stringValue = ""
            self.selectionChanged()
        }
    }

    private func endSearch() {
        search.stop()
        guard !searchText.isEmpty else { return }
        searchText = ""
        statusBar.right.stringValue = ""
        list.show(folderEntries, selecting: [], scrollToTop: false)
        selectionChanged()
    }

    private func clearSearch() {
        searchDelay?.cancel()
        search.stop()
        searchText = ""
        searchField.stringValue = ""
    }

    // MARK: State

    func selectionChanged() {
        let selected = list.selectedEntries
        preview.urls = selected.map(\.url)
        let count = list.allEntries.count
        var text = searchText.isEmpty
            ? (count == 1 ? "1 item" : "\(count.formatted()) items")
            : (count == 1 ? "1 result" : "\(count.formatted()) results")
        if !selected.isEmpty {
            text += "     " + (selected.count == 1 ? "1 item selected" : "\(selected.count.formatted()) items selected")
            let sizes = selected.compactMap(\.size)
            if !sizes.isEmpty { text += "   " + ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file) }
        }
        statusBar.left.stringValue = text
        refreshCommands()
    }

    @objc private func activity(_ note: Notification) {
        statusBar.right.stringValue = note.object as? String ?? ""
    }

    @objc func refreshCommands() {
        commandBar.refresh({ canPerform($0) }, isOn: { $0 == #selector(togglePreview(_:)) && !previewItem.isCollapsed })
    }

    private func canPerform(_ action: Selector) -> Bool {
        let selected = list.selectedEntries
        let searching = !searchText.isEmpty
        // While a name or path is being typed, Cmd+Delete, F2, Cmd+D, Cmd+Up/Down belong to the text.
        let typing = window?.firstResponder is NSText
        let fileKeys: [Selector] = [#selector(moveToTrash(_:)), #selector(delete(_:)), #selector(deleteImmediately(_:)),
                                    #selector(renameItem(_:)), #selector(duplicate(_:)), #selector(openSelection(_:)),
                                    #selector(openInNewTab(_:)), #selector(goUp(_:)), #selector(compress(_:))]
        if typing && fileKeys.contains(action) { return false }
        switch action {
        case #selector(cut(_:)), #selector(copy(_:)), #selector(moveToTrash(_:)), #selector(delete(_:)),
             #selector(deleteImmediately(_:)), #selector(compress(_:)), #selector(share(_:)), #selector(openSelection(_:)):
            return !selected.isEmpty
        case #selector(duplicate(_:)):
            return !selected.isEmpty && !searching
        case #selector(renameItem(_:)):
            return selected.count == 1
        case #selector(openInNewTab(_:)):
            return selected.contains(where: \.isFolder)
        case #selector(paste(_:)), #selector(moveHere(_:)):
            return !searching && Clipboard.hasFiles
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return !searching
        case #selector(goBack(_:)):
            return !back.isEmpty
        case #selector(goForward(_:)):
            return !forward.isEmpty
        case #selector(goUp(_:)):
            return folder.path != "/"
        default:
            return true
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = item.action else { return false }
        if let menuItem = item as? NSMenuItem, let on = isOn(menuItem) { menuItem.state = on ? .on : .off }
        return canPerform(action)
    }

    private func isOn(_ item: NSMenuItem) -> Bool? {
        let value = item.representedObject as? String
        switch item.action {
        case #selector(togglePreview(_:)): return !previewItem.isCollapsed
        case #selector(toggleHidden(_:)): return Settings.showHidden
        case #selector(sortBy(_:)): return value == Settings.sortKey.rawValue
        case #selector(sortAscending(_:)): return Settings.sortAscending
        case #selector(sortDescending(_:)): return !Settings.sortAscending
        case #selector(groupBy(_:)): return value == Settings.groupKey.rawValue
        default: return nil
        }
    }

    private func warn(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector, _ key: String = "", value: String? = nil,
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.representedObject = value
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Folder", #selector(newFolder(_:)), symbol: "folder"))
        menu.addItem(item("Text Document", #selector(newTextDocument(_:)), symbol: "doc.text"))
        return menu
    }

    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for key in SortKey.allCases { menu.addItem(item(key.title, #selector(sortBy(_:)), value: key.rawValue)) }
        menu.addItem(.separator())
        menu.addItem(item("Ascending", #selector(sortAscending(_:))))
        menu.addItem(item("Descending", #selector(sortDescending(_:))))
        menu.addItem(.separator())
        let group = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
        group.submenu = groupMenu()
        menu.addItem(group)
        return menu
    }

    func groupMenu() -> NSMenu {
        let menu = NSMenu()
        for key in GroupKey.allCases { menu.addItem(item(key.title, #selector(groupBy(_:)), value: key.rawValue)) }
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Navigation pane", #selector(NSSplitViewController.toggleSidebar(_:)), symbol: "sidebar.left"))
        menu.addItem(item("Preview pane", #selector(togglePreview(_:)), symbol: "sidebar.right"))
        menu.addItem(.separator())
        menu.addItem(item("Hidden items", #selector(toggleHidden(_:)), symbol: "eye.slash"))
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Select all", #selector(selectAll(_:))))
        menu.addItem(item("Select none", #selector(selectNone(_:))))
        menu.addItem(item("Invert selection", #selector(invertSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Copy as path", #selector(copyPath(_:)), symbol: "link"))
        menu.addItem(item("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal"))
        menu.addItem(item("Open in Finder", #selector(openInFinder(_:)), symbol: "macwindow"))
        menu.addItem(item("Pin to Quick access", #selector(pinToQuickAccess(_:)), symbol: "pin"))
        menu.addItem(item("Compress to ZIP file", #selector(compress(_:)), symbol: "doc.zipper"))
        menu.addItem(.separator())
        menu.addItem(item("Properties", #selector(showProperties(_:)), symbol: "info.circle"))
        return menu
    }

    /// Right-click menu for the list: one for the selected items, one for blank space.
    func fillContextMenu(_ menu: NSMenu, forItems: Bool) {
        let selected = list.selectedEntries
        guard forItems else {
            let view = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
            view.submenu = sortMenu()
            menu.addItem(view)
            let group = NSMenuItem(title: "Group by", action: nil, keyEquivalent: "")
            group.submenu = groupMenu()
            menu.addItem(group)
            menu.addItem(item("Refresh", #selector(refresh(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Paste", #selector(paste(_:))))
            menu.addItem(.separator())
            let new = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
            new.submenu = newMenu()
            menu.addItem(new)
            menu.addItem(.separator())
            menu.addItem(item("Open in Terminal", #selector(openInTerminal(_:))))
            menu.addItem(item("Copy as Path", #selector(copyPath(_:))))
            menu.addItem(item("Pin to Quick access", #selector(pinToQuickAccess(_:))))
            menu.addItem(item("Open in Finder", #selector(openInFinder(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Properties", #selector(showProperties(_:))))
            return
        }
        menu.addItem(item("Open", #selector(openSelection(_:))))
        if selected.contains(where: \.isFolder) { menu.addItem(item("Open in New Tab", #selector(openInNewTab(_:)))) }
        if selected.count == 1, !selected[0].isFolder {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: selected[0].url)
            menu.addItem(openWith)
        }
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(cut(_:)), symbol: "scissors"))
        menu.addItem(item("Copy", #selector(copy(_:)), symbol: "doc.on.doc"))
        menu.addItem(item("Copy as Path", #selector(copyPath(_:)), symbol: "link"))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(renameItem(_:)), symbol: "character.cursor.ibeam"))
        menu.addItem(item("Duplicate", #selector(duplicate(_:)), symbol: "plus.square.on.square"))
        menu.addItem(item("Move to Trash", #selector(moveToTrash(_:)), symbol: "trash"))
        menu.addItem(.separator())
        menu.addItem(item("Compress to ZIP file", #selector(compress(_:)), symbol: "doc.zipper"))
        menu.addItem(item("Share…", #selector(share(_:)), symbol: "square.and.arrow.up"))
        if selected.count == 1, selected[0].isFolder {
            menu.addItem(item("Pin to Quick access", #selector(pinToQuickAccess(_:)), symbol: "pin"))
            menu.addItem(item("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Properties", #selector(showProperties(_:)), symbol: "info.circle"))
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)
        var apps = workspace.urlsForApplications(toOpen: url)
        if let preferred {
            apps.removeAll { $0 == preferred }
            apps.insert(preferred, at: 0)
        }
        for (index, app) in apps.prefix(24).enumerated() {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let entry = NSMenuItem(title: index == 0 && preferred != nil ? "\(name) (default)" : name,
                                   action: #selector(openWith(_:)), keyEquivalent: "")
            entry.representedObject = app
            entry.image = IconCache.shared.icon(forPath: app.path)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Other…", #selector(openWithOther(_:))))
        return menu
    }

    // MARK: Window

    /// File operations share one history across windows; typing in the address bar or a name has its own.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSText ? textUndo : FileOperations.shared.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshCommands() }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, window.isVisible, window.frame.width >= window.minSize.width else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        watcher.stop()
        search.stop()
        preview.isActive = false
        onClose?(self)
    }
}
