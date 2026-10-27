import AppKit

/// Windows keys on a Mac keyboard. Ctrl+C/X/V/A/Z/Y work like Cmd (also while typing in a field);
/// Ctrl+N/T/W/F/E/L/R/D and Ctrl+Shift+N, Option+arrows, Option+D/P/Return and F3/F4/F5 work outside text fields.
enum KeyMap {
    enum Action {
        case menu(NSEvent)
        case send(Selector)
    }

    private static let typingSafe: Set<String> = ["a", "c", "v", "x", "z", "y"]

    static func action(for event: NSEvent, typing: Bool) -> Action? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.isEmpty && !typing {
            switch event.keyCode {
            case 96: return .send(#selector(BrowserWindowController.refresh(_:)))          // F5
            case 99: return .send(#selector(BrowserWindowController.focusSearch(_:)))      // F3
            case 118: return .send(#selector(BrowserWindowController.focusAddressBar(_:))) // F4
            default: return nil
            }
        }

        if flags == [.control] || flags == [.control, .shift] {
            if typing && !typingSafe.contains(key) { return nil }
            let shift = flags.contains(.shift)
            switch (key, shift) {
            case ("n", true): return .send(#selector(BrowserWindowController.newFolder(_:)))
            case ("e", false), ("f", false): return .send(#selector(BrowserWindowController.focusSearch(_:)))
            case ("l", false): return .send(#selector(BrowserWindowController.focusAddressBar(_:)))
            case ("r", false): return .send(#selector(BrowserWindowController.refresh(_:)))
            case ("d", false): return .send(#selector(BrowserWindowController.moveToTrash(_:)))
            case ("y", false): return .menu(command(event, "z", [.command, .shift]))
            case ("a", false), ("c", false), ("v", false), ("x", false), ("z", false), ("n", false), ("t", false), ("w", false):
                return .menu(command(event, key, [.command]))
            default: return nil
            }
        }

        if flags == [.option] && !typing {
            switch event.keyCode {
            case 123: return .send(#selector(BrowserWindowController.goBack(_:)))
            case 124: return .send(#selector(BrowserWindowController.goForward(_:)))
            case 126: return .send(#selector(BrowserWindowController.goUp(_:)))
            case 2: return .send(#selector(BrowserWindowController.focusAddressBar(_:)))   // D
            case 35: return .send(#selector(BrowserWindowController.togglePreview(_:)))    // P
            case 36: return .send(#selector(BrowserWindowController.showProperties(_:)))   // Return
            default: return nil
            }
        }
        return nil
    }

    private static func command(_ event: NSEvent, _ key: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
                         timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: event.isARepeat,
                         keyCode: event.keyCode) ?? event
    }
}

/// The browser window: runs Windows keys through `KeyMap` before AppKit sees them.
final class AtriumWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let action = KeyMap.action(for: event, typing: firstResponder is NSText) {
            switch action {
            case .menu(let translated):
                if NSApp.mainMenu?.performKeyEquivalent(with: translated) == true { return }
            case .send(let selector):
                if NSApp.sendAction(selector, to: nil, from: self) { return }
            }
        }
        super.sendEvent(event)
    }
}
