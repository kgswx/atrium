import AppKit

/// Atrium stays running with no windows (no Dock icon, no menu bar, no timers) so the hotkey and
/// "Show in Finder" open a window at once. It becomes a normal app while a window is open.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var controllers: [BrowserWindowController] = []
    private var hotKey: HotKey?
    private var restartTimer: Timer?
    private let startedQuietly = CommandLine.arguments.contains("--background")
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.register()
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        // What NSWorkspace sends the file viewer for "Show in Finder" (activateFileViewerSelecting).
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reveal(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards),
                                                     andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey(Settings.hotKey) { [weak self] in
            guard let self else { return }
            self.openWindow(at: self.home)
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
            let out = CommandLine.arguments.dropFirst(index + 1).first
            // A timer, not the main queue: the test waits for main-queue work, which can't run inside a main-queue block.
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in SelfTest.run(report: out) }
            return
        }
        #endif
        let plainLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !startedQuietly && plainLaunch {
            // A launch to open a folder or reveal a file brings its own window; give that event a moment first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                if controllers.isEmpty { openWindow(at: home) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty {
            openWindow(at: home)
        } else if !flag {
            controllers.last?.showWindow(nil)
        }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) { show(urls) }

    @objc private func reveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let items = direct.numberOfItems > 0 ? (1...direct.numberOfItems).compactMap { direct.atIndex($0) } : [direct]
        show(items.compactMap { $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue })
    }

    /// Folders open as themselves; files open their folder with the files selected.
    private func show(_ urls: [URL]) {
        var byFolder: [URL: [URL]] = [:]
        var order: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                .map { $0.isDirectory == true && $0.isPackage != true } ?? false
            let folder = isFolder ? url : url.deletingLastPathComponent()
            if byFolder[folder] == nil { order.append(folder) }
            if !isFolder { byFolder[folder, default: []].append(url) } else { byFolder[folder] = byFolder[folder] ?? [] }
        }
        for folder in order { openWindow(at: folder, selecting: byFolder[folder] ?? []) }
    }

    // MARK: Windows

    @discardableResult
    func openWindow(at url: URL, selecting: [URL] = []) -> BrowserWindowController {
        restartTimer?.invalidate()
        becomeVisible()
        let controller = makeController(url, selecting: selecting)
        if let front = NSApp.keyWindow ?? controllers.dropLast().last?.window, front.isVisible {
            controller.window?.setFrameTopLeftPoint(front.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        controller.showWindow(nil)
        // Shown even if macOS declines to bring Atrium forward (activation is a request since macOS 14).
        controller.window?.orderFrontRegardless()
        NSApp.activate()
        return controller
    }

    func openTab(at url: URL, beside: BrowserWindowController) {
        becomeVisible()
        let controller = makeController(url, selecting: [])
        if let host = beside.window, let tab = controller.window {
            host.addTabbedWindow(tab, ordered: .above)
            tab.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    private func makeController(_ url: URL, selecting: [URL]) -> BrowserWindowController {
        let controller = BrowserWindowController(folder: url, selecting: selecting)
        controller.onClose = { [weak self] closed in self?.closed(closed) }
        controllers.append(controller)
        return controller
    }

    private func closed(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        guard controllers.isEmpty else { return }
        // Back to the background: out of the Dock and the app switcher, images released.
        IconCache.shared.purge()
        DispatchQueue.main.async {
            guard self.controllers.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        }
        // Hand freed memory back to the system once the window's teardown has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.controllers.isEmpty { malloc_zone_pressure_relief(nil, 0) }
        }
        scheduleRestart()
    }

    // MARK: Staying small

    /// Windows leave system caches behind (Core Animation, the allocator) that macOS doesn't hand back, so an
    /// Atrium that was used sits at 60-90 MB instead of the 10 MB it starts with. A minute after the last window
    /// closes, with nothing pending, it replaces itself with a fresh copy of itself: same process, still in the
    /// background, about 0.1 s of work. One timer, once; nothing else runs while idle.
    private func scheduleRestart() {
        restartTimer?.invalidate()
        let seconds = Settings.idleRestartSeconds
        guard seconds > 0 else { return }
        restartTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.restartIfIdle()
        }
    }

    func restartIfIdle() {
        guard controllers.isEmpty,
              !NSApp.windows.contains(where: \.isVisible),   // Properties, alerts
              FileOperations.shared.running == 0,
              Clipboard.cutPaths.isEmpty,                     // a pending cut lives only in memory
              Memory.footprint > 25 << 20,
              let executable = Bundle.main.executablePath else { return }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("--background"), nil]
        execv(executable, &arguments)
        // Only reached if exec failed: carry on as we are.
    }

    private func becomeVisible() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) { openWindow(at: home) }

    @objc func toggleDefaultViewer(_ sender: Any?) { DefaultViewer.set(!DefaultViewer.isOn) }

    @objc func toggleLoginItem(_ sender: Any?) {
        do { try LoginItem.set(!LoginItem.isOn) } catch { NSAlert(error: error).runModal() }
    }

    @objc func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/kgswx/atrium")!)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleDefaultViewer(_:)): item.state = DefaultViewer.isOn ? .on : .off
        case #selector(toggleLoginItem(_:)): item.state = LoginItem.isOn ? .on : .off
        default: break
        }
        return true
    }
}
