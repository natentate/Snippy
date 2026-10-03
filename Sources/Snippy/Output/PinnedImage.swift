import AppKit

/// An always-on-top floating screenshot. Drag to move, scroll to zoom, right-click for options, Esc/double-click to close.
final class PinnedImageWindow: NSPanel {
    private static var pins: [PinnedImageWindow] = []

    private let capture: Capture
    private let baseSize: CGSize
    private var zoomLevel: CGFloat = 1

    @MainActor
    static func pin(_ capture: Capture) {
        let window = PinnedImageWindow(capture: capture)
        pins.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private init(capture: Capture) {
        self.capture = capture
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var size = CGSize(width: CGFloat(capture.image.width) / capture.scale,
                          height: CGFloat(capture.image.height) / capture.scale)
        let maxSize = CGSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        baseSize = size
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = size

        let imageView = PinnedImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = capture.image.nsImage(scale: capture.scale)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        imageView.menu = makeMenu()
        imageView.onDoubleClick = { [weak self] in self?.closePin() }
        imageView.onScroll = { [weak self] delta in self?.applyZoom(delta) }
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyImage()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            closePin()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func applyZoom(_ delta: CGFloat) {
        zoomLevel = max(0.2, min(4, zoomLevel * (1 + delta * 0.01)))
        let newSize = CGSize(width: baseSize.width * zoomLevel, height: baseSize.height * zoomLevel)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        setFrame(CGRect(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2,
                        width: newSize.width, height: newSize.height), display: true)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save…", action: #selector(saveImage), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Annotate", action: #selector(annotate), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 75, 50, 25] {
            let item = sub.addItem(withTitle: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(withTitle: "Actual Size", action: #selector(resetZoom), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() {
        Clipboard.copy(image: capture.image, scale: capture.scale)
        Task { @MainActor in HUD.show("Copied to clipboard") }
    }

    @objc private func saveImage() {
        Task { @MainActor in _ = OutputManager.saveAs(capture) }
    }

    @objc private func annotate() {
        let capture = capture
        Task { @MainActor in EditorWindowController.open(capture: capture, fileURL: nil) }
        closePin()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func resetZoom() {
        zoomLevel = 1
        applyZoom(0)
    }

    @objc private func closePin() {
        orderOut(nil)
        PinnedImageWindow.pins.removeAll { $0 === self }
    }
}

private final class PinnedImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }
}
