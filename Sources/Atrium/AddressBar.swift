import AppKit
import AtriumCore

/// One folder in the breadcrumb: click to go there, drop files on it to move them there.
final class CrumbButton: NSButton {
    var folder: URL?
    var onDrop: (([URL], URL, TransferMode) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let folder, let urls = info.fileURLs, let mode = DragRules.mode(for: info, sources: urls, target: folder) else {
            return []
        }
        return mode == .copy ? .copy : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = operation(sender)
        highlight(!op.isEmpty)
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight(false)
        guard let folder, let urls = sender.fileURLs, let mode = DragRules.mode(for: sender, sources: urls, target: folder) else {
            return false
        }
        onDrop?(urls, folder, mode)
        return true
    }
}

/// Explorer's address bar: the whole path from the drive as clickable parts, an arrow after each part that lists
/// the folders inside it, and « for the parts that don't fit. Click beside the parts (or press Ctrl+L, Option+D
/// or F4) to type a path instead.
final class AddressBar: NSView, NSTextFieldDelegate {
    var onPick: ((URL) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onFinish: (() -> Void)?
    var onDrop: (([URL], URL, TransferMode) -> Void)?

    private let icon = NSImageView()
    private let field = NSTextField()
    private let overflow = MenuButton(title: "«", target: nil, action: nil)
    private var parts: [(folder: URL, button: CrumbButton, arrow: MenuButton)] = []
    private var firstShown = 0
    private(set) var isEditing = false

    var url: URL? {
        didSet {
            rebuild()
            if !isEditing { field.stringValue = url?.path ?? "" }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        field.setAccessibilityLabel("Address")
        addSubview(field)

        style(overflow)
        overflow.toolTip = "Folders further up"
        overflow.makeMenu = { [weak self] in self?.overflowMenu() ?? NSMenu() }
        addSubview(overflow)

        heightAnchor.constraint(equalToConstant: 28).isActive = true
        // The toolbar sizes items from their natural width: the full path, which it may stretch or squeeze.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(100), for: .horizontal)
    }

    override var intrinsicContentSize: NSSize {
        let path = parts.reduce(CGFloat(34)) { $0 + $1.button.intrinsicContentSize.width + $1.arrow.intrinsicContentSize.width }
        return NSSize(width: min(max(path, 260), 900), height: 28)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Parts

    /// From the drive down: "/" (Macintosh HD) for the startup disk, /Volumes/Name for any other.
    static func chain(for url: URL) -> [URL] {
        let parts = url.standardizedFileURL.pathComponents   // ["/", "Users", "you", ...]
        let rootCount = parts.count > 2 && parts[1] == "Volumes" ? 3 : 1
        var chain = [URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(rootCount))))]
        for depth in rootCount..<max(rootCount, parts.count) {
            chain.append(URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(depth + 1)))))
        }
        return chain
    }

    private func rebuild() {
        parts.forEach { $0.button.removeFromSuperview(); $0.arrow.removeFromSuperview() }
        parts = []
        guard let url else { return }
        icon.image = IconCache.shared.folderIcon(for: url)
        for folder in Self.chain(for: url) {
            let button = CrumbButton(frame: .zero)
            button.title = FileManager.default.displayName(atPath: folder.path)
            button.folder = folder
            button.target = self
            button.action = #selector(crumbClicked(_:))
            button.onDrop = { [weak self] urls, target, mode in self?.onDrop?(urls, target, mode) }
            button.toolTip = folder.path
            button.lineBreakMode = .byTruncatingTail
            style(button)
            let arrow = MenuButton(title: "›", target: nil, action: nil)
            style(arrow)
            arrow.toolTip = "Folders in “\(button.title)”"
            arrow.makeMenu = { [weak self] in self?.foldersMenu(in: folder) ?? NSMenu() }
            addSubview(button)
            addSubview(arrow)
            parts.append((folder, button, arrow))
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func style(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.controlSize = .regular
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: 7, y: (height - 16) / 2, width: 16, height: 16)
        field.frame = NSRect(x: 28, y: (height - 20) / 2, width: max(0, bounds.width - 34), height: 20)
        let start: CGFloat = 26
        let available = bounds.width - start - 6
        let widths = parts.map { $0.button.intrinsicContentSize.width + $0.arrow.intrinsicContentSize.width }
        let overflowWidth = overflow.intrinsicContentSize.width

        // Drop parts from the front, as Explorer does, until the rest fit; the folder you're in always shows.
        firstShown = 0
        while firstShown < parts.count - 1,
              widths[firstShown...].reduce(0, +) + (firstShown > 0 ? overflowWidth : 0) > available {
            firstShown += 1
        }
        let editing = isEditing
        overflow.isHidden = editing || firstShown == 0
        var x = start
        if !overflow.isHidden {
            overflow.frame = NSRect(x: x, y: (height - 22) / 2, width: overflowWidth, height: 22)
            x += overflowWidth
        }
        for (index, part) in parts.enumerated() {
            let shown = !editing && index >= firstShown
            part.button.isHidden = !shown
            part.arrow.isHidden = !shown
            guard shown else { continue }
            let arrowWidth = part.arrow.intrinsicContentSize.width
            let buttonWidth = min(part.button.intrinsicContentSize.width, max(40, bounds.width - 6 - x - arrowWidth))
            part.button.frame = NSRect(x: x, y: (height - 22) / 2, width: buttonWidth, height: 22)
            x += buttonWidth
            part.arrow.frame = NSRect(x: x, y: (height - 22) / 2, width: arrowWidth, height: 22)
            x += arrowWidth
        }
    }

    @objc private func crumbClicked(_ sender: CrumbButton) {
        if let folder = sender.folder { onPick?(folder) }
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? URL { onPick?(folder) }
    }

    /// The folders inside one part of the path, with the one on the path ticked.
    private func foldersMenu(in folder: URL) -> NSMenu {
        let menu = NSMenu()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .labelNumberKey]
        let options: FileManager.DirectoryEnumerationOptions = Settings.showHidden ? [] : [.skipsHiddenFiles]
        let next = parts.first { $0.folder.deletingLastPathComponent().key == folder.key && $0.folder.key != folder.key }?.folder
        let subfolders = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)) ?? [])
            .filter { let v = try? $0.resourceValues(forKeys: Set(keys)); return v?.isDirectory == true && v?.isPackage != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for sub in subfolders.prefix(300) {
            let entry = NSMenuItem(title: FileManager.default.displayName(atPath: sub.path), action: #selector(menuPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = sub
            entry.image = IconCache.shared.folderIcon(for: sub)
            entry.state = sub.key == next?.key ? .on : .off
            menu.addItem(entry)
        }
        if subfolders.isEmpty {
            let none = NSMenuItem(title: "No folders", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    /// The parts that didn't fit, nearest first.
    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        for part in parts.prefix(firstShown).reversed() {
            let entry = NSMenuItem(title: part.button.title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = part.folder
            entry.image = IconCache.shared.folderIcon(for: part.folder)
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: Look

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = (isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    // MARK: Typing a path

    override func mouseDown(with event: NSEvent) { beginEditing() }

    func beginEditing() {
        isEditing = true
        needsDisplay = true
        needsLayout = true
        field.isHidden = false
        field.stringValue = url?.path ?? ""
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        needsDisplay = true
        needsLayout = true
        field.isHidden = true
        field.stringValue = url?.path ?? ""
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            endEditing()
            onSubmit?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            onFinish?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { endEditing() }
}
