import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var recordingTimer: Timer?
    private let coordinator = CaptureCoordinator.shared

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIdleAppearance()
        coordinator.onRecordingChanged = { [weak self] recording in
            self?.recordingChanged(recording)
        }
    }

    // MARK: Appearance

    private func setIdleAppearance() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snippy")
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.target = nil
        button.action = nil
        button.toolTip = "Snippy"
    }

    private func recordingChanged(_ recording: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard recording else {
            statusItem.menu = menu
            setIdleAppearance()
            return
        }
        // While recording, a click on the status item stops the recording.
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        button.image?.isTemplate = true
        button.contentTintColor = .systemRed
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Click to stop recording · Right-click for options"
        updateElapsed()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    private func updateElapsed() {
        guard let start = coordinator.recordingStart else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let options = NSMenu()
            options.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = self
            options.addItem(withTitle: "Discard Recording", action: #selector(discardRecording), keyEquivalent: "").target = self
            statusItem.menu = options
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            stopRecording()
        }
    }

    @objc private func stopRecording() {
        Task { await coordinator.stopRecording() }
    }

    @objc private func discardRecording() {
        Task { await coordinator.cancelRecording() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addHeader("Screenshot")
        for action in [CaptureAction.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow,
                       .scrollingCapture, .selfTimer, .captureText] {
            menu.addItem(item(for: action))
        }
        menu.addItem(.separator())
        addHeader("Recording")
        menu.addItem(item(for: .recordVideo))
        menu.addItem(item(for: .recordGIF))
        menu.addItem(.separator())

        menu.addItem(makeItem("Annotate Image…", symbol: "pencil.tip.crop.circle", action: #selector(openImage)))
        let clipboard = makeItem("Annotate Clipboard Image", symbol: "doc.on.clipboard", action: #selector(annotateClipboard))
        clipboard.isEnabled = NSImage.canInit(with: NSPasteboard.general)
        menu.addItem(clipboard)
        menu.addItem(historyMenuItem())
        menu.addItem(makeItem("Open Captures Folder", symbol: "folder", action: #selector(openFolder)))
        menu.addItem(.separator())

        let desktop = item(for: .toggleDesktopIcons)
        desktop.state = DesktopIconsHider.shared.isHidden ? .on : .off
        menu.addItem(desktop)
        menu.addItem(.separator())

        let settings = makeItem("Settings…", symbol: "gearshape", action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(makeItem("About Snippy", symbol: "info.circle", action: #selector(openAbout)))
        let quit = makeItem("Quit Snippy", symbol: "power", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func addHeader(_ title: String) {
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        }
    }

    private func item(for action: CaptureAction) -> NSMenuItem {
        let item = makeItem(action.title, symbol: action.symbol, action: #selector(performAction(_:)))
        item.representedObject = action.rawValue
        if let hotkey = action.hotkey, !hotkey.menuKeyEquivalent.isEmpty {
            item.keyEquivalent = hotkey.menuKeyEquivalent
            item.keyEquivalentModifierMask = hotkey.modifierFlags
        }
        if action == .recordVideo || action == .recordGIF, coordinator.isRecording {
            item.title = "Stop Recording"
        }
        return item
    }

    private func makeItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func historyMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let sub = NSMenu()
        HistoryStore.shared.prune()
        let items = HistoryStore.shared.items.prefix(12)
        if items.isEmpty {
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for entry in items {
            let item = NSMenuItem(title: "\(entry.url.lastPathComponent) · \(formatter.localizedString(for: entry.date, relativeTo: Date()))",
                                  action: #selector(openHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.uuidString
            switch entry.kind {
            case .image:
                if let image = NSImage(contentsOf: entry.url) { item.image = thumbnail(image) }
            case .gif:
                item.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
            case .video:
                item.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            }
            sub.addItem(item)
        }
        if !items.isEmpty {
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        parent.submenu = sub
        return parent
    }

    private func thumbnail(_ image: NSImage) -> NSImage {
        let maxSide: CGFloat = 32
        let ratio = image.size.width / max(image.size.height, 1)
        let size = ratio > 1 ? CGSize(width: maxSide, height: maxSide / ratio) : CGSize(width: maxSide * ratio, height: maxSide)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    // MARK: Actions

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = CaptureAction(rawValue: raw) else { return }
        coordinator.perform(action, fromMenu: true)
    }

    @objc private func openImage() { EditorWindowController.openImageFile() }

    @objc private func annotateClipboard() {
        guard let clip = Clipboard.image() else { return }
        EditorWindowController.open(capture: Capture(image: clip.0, scale: clip.1), fileURL: nil)
    }

    @objc private func openHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = HistoryStore.shared.items.first(where: { $0.id.uuidString == id }) else { return }
        OutputManager.reopen(entry)
    }

    @objc private func clearHistory() { HistoryStore.shared.clear() }

    @objc private func openFolder() {
        let dir = Preferences.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Snippy",
            .credits: NSAttributedString(string: "Screenshots, recordings, annotations and OCR — from your menu bar."),
        ])
    }

    @objc private func quit() {
        Task {
            if coordinator.isRecording { await coordinator.stopRecording() }
            NSApp.terminate(nil)
        }
    }
}
