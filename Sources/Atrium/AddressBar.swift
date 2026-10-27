import AppKit

/// Explorer's address bar: a breadcrumb you click, which turns into a path you can type when you click beside it
/// (or press Cmd+L, Ctrl+L, Option+D or F4).
final class AddressBar: NSView, NSTextFieldDelegate {
    var onPick: ((URL) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onFinish: (() -> Void)?

    private let crumbs = NSPathControl()
    private let field = NSTextField()
    private(set) var isEditing = false

    var url: URL? {
        didSet {
            crumbs.url = url
            if !isEditing { field.stringValue = url?.path ?? "" }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        crumbs.pathStyle = .standard
        crumbs.isEditable = false
        crumbs.focusRingType = .none
        crumbs.backgroundColor = .clear
        crumbs.font = .systemFont(ofSize: NSFont.systemFontSize)
        crumbs.target = self
        crumbs.action = #selector(crumbClicked)
        crumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.isHidden = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Address")

        for view in [crumbs, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = (isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
    }

    override func mouseDown(with event: NSEvent) { beginEditing() }

    @objc private func crumbClicked() {
        if let picked = crumbs.clickedPathItem?.url { onPick?(picked) } else { beginEditing() }
    }

    func beginEditing() {
        isEditing = true
        needsDisplay = true
        crumbs.isHidden = true
        field.isHidden = false
        field.stringValue = url?.path ?? ""
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing() {
        guard isEditing else { return }
        isEditing = false
        needsDisplay = true
        field.isHidden = true
        crumbs.isHidden = false
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
