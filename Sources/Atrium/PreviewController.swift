import AppKit
import Quartz

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

    var urls: [URL] = [] { didSet { if isActive { update() } } }

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
        guard isActive, urls.count == 1 else {
            preview?.previewItem = nil
            preview?.isHidden = true
            placeholder.stringValue = urls.count > 1 ? "\(urls.count) items selected" : "Select a file to preview."
            placeholder.isHidden = false
            return
        }
        if preview == nil, let made = QLPreviewView(frame: view.bounds, style: .normal) {
            made.autoresizingMask = [.width, .height]
            made.shouldCloseWithWindow = false
            view.addSubview(made)
            preview = made
        }
        preview?.previewItem = urls[0] as NSURL
        preview?.isHidden = false
        placeholder.isHidden = true
    }
}
