import AppKit

/// Explorer's Properties window (Alt+Enter, or Cmd+I): kind, location, size with folder contents counted, dates.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindowController] = []

    static func show(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let controller = PropertiesWindowController(urls: urls)
        open.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
    }

    private let urls: [URL]
    private let sizeLabel = NSTextField(labelWithString: "Calculating…")
    private let diskLabel = NSTextField(labelWithString: "")
    private let containsLabel = NSTextField(labelWithString: "")
    private var cancelled = false

    private init(urls: [URL]) {
        self.urls = urls
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.title = urls.count == 1 ? "\(urls[0].lastPathComponent) Properties" : "\(urls.count) Items Properties"
        build()
        measure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let first = urls[0]
        let values = try? first.resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey])
        let dates = DateFormatter()
        dates.dateStyle = .long
        dates.timeStyle = .short

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: first.path))
        icon.image?.size = NSSize(width: 48, height: 48)
        let name = NSTextField(labelWithString: urls.count == 1 ? FileManager.default.displayName(atPath: first.path) : "\(urls.count) items")
        name.font = .boldSystemFont(ofSize: 15)
        name.isSelectable = true
        let header = NSStackView(views: [icon, name])
        header.spacing = 12

        var rows: [[NSView]] = []
        func row(_ title: String, _ value: NSView) {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            rows.append([label, value])
        }
        func text(_ s: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.isSelectable = true
            return t
        }
        if urls.count == 1 { row("Type:", text(values?.localizedTypeDescription ?? "")) }
        row("Location:", text(urls.count == 1 ? first.deletingLastPathComponent().path : "Several"))
        row("Size:", sizeLabel)
        row("Size on disk:", diskLabel)
        row("Contains:", containsLabel)
        if urls.count == 1 {
            row("Created:", text(values?.creationDate.map(dates.string(from:)) ?? ""))
            row("Modified:", text(values?.contentModificationDate.map(dates.string(from:)) ?? ""))
        }
        for label in [sizeLabel, diskLabel, containsLabel] { label.isSelectable = true }

        let grid = NSGridView(views: rows)
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 300

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    /// Counts in the background and updates a few times a second; closing the window stops it.
    private func measure() {
        let urls = self.urls
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var size: Int64 = 0, onDisk: Int64 = 0, files = 0, folders = 0
            var lastUpdate = Date.distantPast
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
            func add(_ url: URL) {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return }
                if v.isDirectory == true { folders += 1 } else {
                    files += 1
                    size += Int64(v.fileSize ?? 0)
                    onDisk += Int64(v.totalFileAllocatedSize ?? 0)
                }
            }
            func publish(done: Bool) {
                let (s, d, f, g) = (size, onDisk, files, folders)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let bytes = ByteCountFormatter()
                    bytes.countStyle = .file
                    self.sizeLabel.stringValue = "\(bytes.string(fromByteCount: s)) (\(s.formatted()) bytes)" + (done ? "" : "…")
                    self.diskLabel.stringValue = bytes.string(fromByteCount: d)
                    self.containsLabel.stringValue = "\(f.formatted()) files, \(g.formatted()) folders"
                }
            }
            for url in urls {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if !isFolder { add(url); continue }
                folders += 1
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                while let next = walker?.nextObject() as? URL {
                    if self?.cancelled != false { return }
                    add(next)
                    if Date().timeIntervalSince(lastUpdate) > 0.25 {
                        lastUpdate = Date()
                        publish(done: false)
                    }
                }
            }
            if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders -= 1 }
            publish(done: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelled = true
        Self.open.removeAll { $0 === self }
    }
}
