import AppKit
import QuartzCore

/// Small transient toast in the lower-centre of the active screen.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.6) {
        panel?.orderOut(nil)
        let screen = NSScreen.main ?? NSScreen.screens[0]

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 80,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.excludeFromCapture()
        p.contentView = effect
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// Big centred countdown before a timed capture or a recording starts.
@MainActor
enum Countdown {
    /// Returns false if cancelled with Esc.
    static func run(seconds: Int, on screen: NSScreen? = nil) async -> Bool {
        guard seconds > 0 else { return true }
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let side: CGFloat = 160
        let frame = CGRect(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2, width: side, height: side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.excludeFromCapture()

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 32
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 84, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: (side - 100) / 2, width: side, height: 100)
        effect.addSubview(label)
        panel.contentView = effect
        panel.orderFrontRegardless()

        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelled = true }
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { cancelled = true; return nil }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            panel.orderOut(nil)
        }

        for remaining in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(remaining)"
            NSSound(named: "Tink")?.play()
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if cancelled { return false }
            }
        }
        panel.orderOut(nil)
        // Let the window server remove the panel before capturing.
        try? await Task.sleep(nanoseconds: 120_000_000)
        return !cancelled
    }
}

/// Hides desktop icons by covering them with the wallpaper (visible in captures, below all app windows).
@MainActor
final class DesktopIconsHider {
    static let shared = DesktopIconsHider()
    private var windows: [NSWindow] = []
    private var observer: NSObjectProtocol?

    var isHidden: Bool { !windows.isEmpty }

    func setHidden(_ hidden: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Preferences.hideDesktopIcons = hidden
        guard hidden else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            let imageView = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                imageView.image = image
                window.backgroundColor = .black
            } else {
                window.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
            }
            window.contentView = imageView
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            windows.append(window)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { _ in
            Task { @MainActor in DesktopIconsHider.shared.setHidden(true) }
        }
    }
}

/// Draws an expanding ring wherever the user clicks (shown in recordings).
@MainActor
final class ClickHighlighter {
    static let shared = ClickHighlighter()
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let point = NSEvent.mouseLocation
            let color: NSColor = event.type == .rightMouseDown ? .systemBlue : .systemYellow
            Task { @MainActor in ClickHighlighter.ripple(at: point, color: color) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func ripple(at point: CGPoint, color: NSColor) {
        let side: CGFloat = 64
        let frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: CGRect(x: 8, y: 8, width: side - 16, height: side - 16), transform: nil)
        circle.fillColor = color.withAlphaComponent(0.35).cgColor
        circle.strokeColor = color.cgColor
        circle.lineWidth = 3
        circle.frame = view.bounds
        view.layer?.addSublayer(circle)
        window.contentView = view
        window.orderFrontRegardless()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        circle.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.orderOut(nil) }
    }
}

/// Dashed outline drawn just outside the area being recorded / scroll-captured.
final class RegionBorderWindow: NSWindow {
    init(globalRect: CGRect, color: NSColor = .systemRed) {
        let inset: CGFloat = -4
        super.init(contentRect: globalRect.insetBy(dx: inset, dy: inset), styleMask: .borderless,
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        excludeFromCapture()
        contentView = BorderView(color: color)
    }

    private final class BorderView: NSView {
        let color: NSColor
        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            color.setStroke()
            path.stroke()
        }
    }
}
