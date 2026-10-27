import AppKit
import Quartz
import AtriumCore

/// Explorer's preview pane, drawn by Quick Look. The Quick Look view only exists while the pane is open.
final class PreviewController: NSViewController {
    private var preview: QLPreviewView?
    private let placeholder = NSTextField(labelWithString: "Select a file to preview.")

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive {
                preview?.close()
                preview?.removeFromSuperview()
                preview = nil
            }
            update()
        }
    }

    var entries: [FileEntry] = [] { didSet { if isActive { update() } } }

    override func loadView() {
        let root = NSView()
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
        ])
        view = root
    }

    private func update() {
        // An online-only file isn't previewed: Quick Look would download it just for arrowing past it.
        guard isActive, entries.count == 1, entries[0].sync != .cloudOnly else {
            preview?.previewItem = nil
            preview?.isHidden = true
            placeholder.stringValue = entries.count > 1 ? "\(entries.count) items selected"
                : entries.first?.sync == .cloudOnly ? "Online only.\nOpen it, or choose Download now, to preview it."
                : "Select a file to preview."
            placeholder.isHidden = false
            return
        }
        if preview == nil, let made = QLPreviewView(frame: view.bounds, style: .normal) {
            made.autoresizingMask = [.width, .height]
            made.shouldCloseWithWindow = false
            view.addSubview(made)
            preview = made
        }
        preview?.previewItem = entries[0].url as NSURL
        preview?.isHidden = false
        placeholder.isHidden = true
    }
}
