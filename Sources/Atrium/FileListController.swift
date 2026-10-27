import AppKit
import Quartz
import AtriumCore

/// Explorer's keys inside the list. Return opens (Finder renames on Return; Explorer opens), the delete key
/// (Backspace on a Windows keyboard) goes back, Space is Quick Look.
final class FileTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var list: FileListController?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard let list, let browser = list.browser else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            flags.contains(.command) || flags.contains(.control) ? browser.openInNewTab(nil) : browser.openSelection(nil)
        case 51 where flags.isEmpty: // Backspace
            browser.goBack(nil)
        case 117: // Forward delete
            flags.contains(.shift) ? browser.deleteImmediately(nil) : browser.moveToTrash(nil)
        case 49 where flags.isEmpty: // Space
            toggleQuickLook()
        case 53: // Esc
            if !Clipboard.cutPaths.isEmpty { Clipboard.clearCut() } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if event.buttonNumber == 2, row >= 0, let entry = list?.entry(at: row), entry.isFolder {
            list?.browser?.openTab(entry.url)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking an item outside the selection selects it first; right-clicking blank space clears it.
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 || list?.entry(at: row) == nil {
            deselectAll(nil)
        } else if !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { list?.selectedURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        list?.selectedURLs[index] as NSURL?
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}

/// The Details view: sortable, resizable columns, optional groups, inline rename, drag and drop.
final class FileListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private enum Row {
        case group(String, Int)
        case item(FileEntry)
    }

    weak var browser: BrowserWindowController?
    let table = FileTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var entries: [FileEntry] = []
    private var rows: [Row] = []
    private var renaming: FileEntry?
    private var renameCancelled = false
    private var cut: Set<String> = []
    /// Set while showing search results: the folder the search started in, for the "Folder" column.
    private(set) var searchRoot: URL?

    private static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Icon and words together, so the colour is never the only clue.
    private static let statusSymbols: [SyncState: String] = [
        .cloudOnly: "cloud", .local: "checkmark.circle", .syncing: "arrow.triangle.2.circlepath", .waiting: "arrow.up.circle",
    ]

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override func loadView() {
        table.list = self
        table.style = .inset
        // 20-point icons, a little larger than Explorer's 16, so folder colours and symbols read at a glance.
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = true
        table.usesAlternatingRowBackgroundColors = false
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.every, forLocal: false)
        table.setDraggingSourceOperationMask(.every, forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.setAccessibilityLabel("Items")

        addColumn("Name", key: .name, width: 280, min: 140)
        let status = NSTableColumn(identifier: .init("Status"))
        status.title = "Status"
        status.width = 120
        status.minWidth = 40
        status.isHidden = true
        table.addTableColumn(status)
        addColumn("Date modified", key: .modified, width: 140, min: 90)
        addColumn("Type", key: .kind, width: 140, min: 70)
        addColumn("Size", key: .size, width: 90, min: 60)
        let folder = NSTableColumn(identifier: .init("Folder"))
        folder.title = "Folder"
        folder.width = 220
        folder.minWidth = 80
        folder.isHidden = true
        table.addTableColumn(folder)
        // v2: Status joined after Name; a new name so saved layouts from 0.1 don't push it to the end.
        table.autosaveName = "AtriumDetailsColumns2"
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: Settings.sortKey.rawValue, ascending: Settings.sortAscending)]

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 60),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
        ])
        view = scroll

        NotificationCenter.default.addObserver(self, selector: #selector(clipboardChanged), name: Clipboard.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func addColumn(_ title: String, key: SortKey, width: CGFloat, min: CGFloat) {
        let column = NSTableColumn(identifier: .init(key.rawValue))
        column.title = title
        column.width = width
        column.minWidth = min
        column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key == .name)
        if key == .size { column.headerCell.alignment = .right }
        table.addTableColumn(column)
    }

    // MARK: Showing items

    func show(_ newEntries: [FileEntry], selecting urls: [URL], searchRoot: URL? = nil, scrollToTop: Bool,
              emptyText: String? = nil, cloud: Bool = false) {
        entries = newEntries
        self.searchRoot = searchRoot
        table.tableColumn(withIdentifier: .init("Folder"))?.isHidden = searchRoot == nil
        table.tableColumn(withIdentifier: .init("Status"))?.isHidden = !cloud
        cut = Clipboard.cutPaths
        rebuild(selecting: urls)
        // A revealed file wins over the top of the list (rebuild has already scrolled to it).
        if scrollToTop && table.selectedRowIndexes.isEmpty { table.scrollRowToVisible(0) }
        emptyLabel.stringValue = emptyText ?? (searchRoot == nil ? "This folder is empty." : "No items match your search.")
        emptyLabel.isHidden = !entries.isEmpty
    }

    /// Re-sorts and re-groups what is already loaded, keeping the selection.
    func rebuild(selecting urls: [URL]? = nil) {
        let keep = Set((urls ?? selectedURLs).map(\.key))
        let sorted = Listing.sorted(entries, by: Settings.sortKey, ascending: Settings.sortAscending)
        let groupKey = searchRoot == nil ? Settings.groupKey : .none
        rows = groupKey == .none
            ? sorted.map(Row.item)
            : Listing.grouped(sorted, by: groupKey).flatMap { [Row.group($0.title, $0.entries.count)] + $0.entries.map(Row.item) }
        let descriptor = NSSortDescriptor(key: Settings.sortKey.rawValue, ascending: Settings.sortAscending)
        if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
        table.reloadData()
        let indexes = IndexSet(rows.indices.filter { if case .item(let e) = rows[$0] { return keep.contains(e.url.key) } else { return false } })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { table.scrollRowToVisible(first) }
    }

    func entry(at row: Int) -> FileEntry? {
        guard row >= 0, row < rows.count, case .item(let entry) = rows[row] else { return nil }
        return entry
    }

    var allEntries: [FileEntry] { entries }
    var selectedEntries: [FileEntry] { table.selectedRowIndexes.compactMap(entry(at:)) }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }

    func selectAll() { table.selectAll(nil) }

    func invertSelection() {
        let all = IndexSet(rows.indices.filter { entry(at: $0) != nil })
        table.selectRowIndexes(all.subtracting(table.selectedRowIndexes), byExtendingSelection: false)
    }

    /// The row Explorer lands on after the selection is deleted: the next item, else the previous one.
    func neighbour(after removed: [URL]) -> URL? {
        let gone = Set(removed.map(\.key))
        guard let last = table.selectedRowIndexes.last else { return nil }
        let after = ((last + 1)..<rows.count).lazy.compactMap(entry(at:)).first { !gone.contains($0.url.key) }
        let before = (0..<last).reversed().lazy.compactMap(entry(at:)).first { !gone.contains($0.url.key) }
        return (after ?? before)?.url
    }

    @objc private func clipboardChanged() {
        cut = Clipboard.cutPaths
        table.enumerateAvailableRowViews { rowView, row in
            guard let entry = self.entry(at: row) else { return }
            rowView.alphaValue = self.alpha(for: entry)
        }
    }

    private func alpha(for entry: FileEntry) -> CGFloat { cut.contains(entry.url.key) || entry.isHidden ? 0.5 : 1 }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, entry(at: table.clickedRow) != nil else { return }
        browser?.openSelection(nil)
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entry(at: row) != nil }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if let entry = entry(at: row) { rowView.alphaValue = alpha(for: entry) }
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let title, let count):
            let cell = reuse("Group", in: tableView) { self.textCell($0, bold: true) }
            cell.textField?.stringValue = "\(title) (\(count))"
            return cell
        case .item(let entry):
            guard let id = column?.identifier.rawValue else { return nil }
            switch id {
            case SortKey.name.rawValue:
                let cell = reuse("Name", in: tableView, make: nameCell)
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = IconCache.shared.icon(for: entry, size: 20)
                return cell
            case SortKey.modified.rawValue:
                return plain(id, entry.modified.map(Self.dates.string(from:)) ?? "", in: tableView)
            case SortKey.kind.rawValue:
                return plain(id, entry.kind, in: tableView)
            case SortKey.size.rawValue:
                return plain(id, entry.size.map(Self.bytes.string(fromByteCount:)) ?? "", in: tableView, right: true)
            case "Status":
                let cell = reuse("Status", in: tableView, make: nameCell)
                cell.textField?.stringValue = entry.sync.title
                cell.textField?.textColor = .secondaryLabelColor
                cell.imageView?.image = Self.statusSymbols[entry.sync].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                cell.imageView?.contentTintColor = .secondaryLabelColor
                return cell
            default:
                let parent = entry.url.deletingLastPathComponent().path
                let root = searchRoot?.path ?? ""
                let shown = parent.hasPrefix(root) ? String(parent.dropFirst(root.count)).trimmingCharacters(in: ["/"]) : parent
                return plain(id, shown.isEmpty ? "." : shown, in: tableView)
            }
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        entry(at: row)?.name
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = SortKey(rawValue: first.key ?? "") else { return }
        if key != Settings.sortKey || first.ascending != Settings.sortAscending {
            Settings.sortKey = key
            Settings.sortAscending = first.ascending
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        browser?.selectionChanged()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    private func reuse(_ id: String, in tableView: NSTableView, make: (NSUserInterfaceItemIdentifier) -> NSTableCellView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        return tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? make(identifier)
    }

    private func plain(_ id: String, _ text: String, in tableView: NSTableView, right: Bool = false) -> NSTableCellView {
        let cell = reuse(id, in: tableView) { self.textCell($0, bold: false) }
        cell.textField?.stringValue = text
        cell.textField?.alignment = right ? .right : .left
        return cell
    }

    private func textCell(_ id: NSUserInterfaceItemIdentifier, bold: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.textColor = bold ? .labelColor : .secondaryLabelColor
        text.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func nameCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.cell?.isScrollable = false
        for view in [icon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = text
        icon.imageScaling = .scaleProportionallyUpOrDown
        let side: CGFloat = id.rawValue == "Name" ? 20 : 16
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: side),
            icon.heightAnchor.constraint(equalToConstant: side),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Rename in place (F2)

    func beginRename(_ url: URL) {
        guard let row = rows.firstIndex(where: { if case .item(let e) = $0 { return e.url.key == url.key } else { return false } }),
              let entry = entry(at: row),
              let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == SortKey.name.rawValue }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renaming = entry
        renameCancelled = false
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.lineBreakMode = .byClipping
        guard view.window?.makeFirstResponder(field) == true else { return }
        field.currentEditor()?.selectedRange = FileNaming.stemRange(of: entry.name, isFolder: entry.isFolder)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let entry = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingMiddle
        let name = field.stringValue
        field.stringValue = entry.name
        if view.window?.firstResponder == nil || view.window?.firstResponder === view.window { view.window?.makeFirstResponder(table) }
        browser?.renameFinished(entry, to: renameCancelled ? nil : name)
    }

    var isRenaming: Bool { renaming != nil }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entry(at: row)?.url as NSURL?
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        // Dropped on the Trash in the Dock.
        if operation == .delete, let urls = session.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            FileOperations.shared.trash(urls)
            browser?.reload()
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let target = dropTarget(info, row: row, operation: operation), let urls = info.fileURLs,
              let mode = DragRules.mode(for: info, sources: urls, target: target) else { return [] }
        if target.key == browser?.folder.key { tableView.setDropRow(-1, dropOperation: .on) }
        return mode == .copy ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let target = dropTarget(info, row: row, operation: dropOperation), let urls = info.fileURLs,
              let mode = DragRules.mode(for: info, sources: urls, target: target) else { return false }
        browser?.transfer(urls, to: target, mode: mode)
        return true
    }

    private func dropTarget(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> URL? {
        guard searchRoot == nil, let folder = browser?.folder else { return nil }
        if operation == .on, let entry = entry(at: row), entry.isFolder, info.fileURLs?.contains(where: { $0.key == entry.url.key }) != true {
            return entry.url
        }
        return folder
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        browser?.fillContextMenu(menu, forItems: !selectedEntries.isEmpty)
    }
}
