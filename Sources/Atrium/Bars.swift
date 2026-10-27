import AppKit

/// A command-bar button that opens a menu under itself (New, Sort, View, "...").
final class MenuButton: NSButton {
    var makeMenu: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let menu = makeMenu?() else { return }
        highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
        highlight(false)
    }
}

/// The Windows 11 command bar: New, cut/copy/paste/rename/share/delete, Sort, View, more, and the preview toggle.
final class CommandBar: NSView {
    private(set) var buttons: [(button: NSButton, action: Selector, toggle: Bool)] = []
    private let stack = NSStackView()
    private let trailing = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for s in [stack, trailing] {
            s.orientation = .horizontal
            s.spacing = 2
            s.translatesAutoresizingMaskIntoConstraints = false
            addSubview(s)
        }
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func add(_ symbol: String, title: String? = nil, tip: String, action: Selector, trailing: Bool = false,
             toggle: Bool = false) -> NSButton {
        let button = NSButton(title: title ?? "", image: Self.image(symbol, tip), target: nil, action: action)
        style(button, title: title, tip: tip)
        if toggle { button.setButtonType(.pushOnPushOff) }
        (trailing ? self.trailing : stack).addArrangedSubview(button)
        buttons.append((button, action, toggle))
        return button
    }

    func addMenu(_ symbol: String, title: String?, tip: String, menu: @escaping () -> NSMenu) {
        let button = MenuButton(title: title ?? "", image: Self.image(symbol, tip), target: nil, action: nil)
        button.makeMenu = menu
        style(button, title: title, tip: tip)
        if let title { button.title = title + " ▾" }
        stack.addArrangedSubview(button)
    }

    func addSeparator() {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(line)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.setCustomSpacing(8, after: line)
    }

    /// Greys out what can't be done right now, asking the same question the menus ask.
    func refresh(_ canDo: (Selector) -> Bool, isOn: (Selector) -> Bool) {
        for (button, action, toggle) in buttons {
            button.isEnabled = canDo(action)
            if toggle {
                button.state = isOn(action) ? .on : .off
                button.contentTintColor = button.state == .on ? .controlAccentColor : nil
            }
        }
    }

    private func style(_ button: NSButton, title: String?, tip: String) {
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    private static func image(_ symbol: String, _ tip: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config) ?? NSImage()
    }
}

/// "24 items   3 items selected  4.2 MB", and what's running ("Copying 12 items…") on the right.
final class StatusBar: NSView {
    let left = NSTextField(labelWithString: "")
    let right = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for label in [left, right] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        right.alignment = .right
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
