import AppKit
import ScreenCaptureKit

enum SelectionResult {
    /// A rect in the screen's local coordinates (bottom-left origin, points).
    case area(screen: NSScreen, rect: CGRect)
    case window(SCWindow)
}

struct SelectionOptions {
    enum Mode { case area, window }
    var mode: Mode = .area
    /// A plain click (no drag) selects the whole screen under the cursor.
    var clickSelectsScreen = false
    var allowsWindowMode = true
    var hint: String = "Drag to select · Space for window · Esc to cancel"
}

/// Full-screen crosshair overlay on every display, drawn over a frozen snapshot of the screen.
@MainActor
final class SelectionController {
    private static var active: SelectionController?

    private var overlays: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult?, Never>?
    let options: SelectionOptions
    let windows: [SCWindow]
    var windowMode: Bool

    private init(options: SelectionOptions, windows: [SCWindow]) {
        self.options = options
        self.windows = windows
        windowMode = options.mode == .window
    }

    static func select(frozen: [CGDirectDisplayID: Capture], windows: [SCWindow],
                       options: SelectionOptions) async -> SelectionResult? {
        active?.finish(nil)
        let controller = SelectionController(options: options, windows: windows)
        active = controller
        return await withCheckedContinuation { cont in
            controller.continuation = cont
            controller.present(frozen: frozen)
        }
    }

    private func present(frozen: [CGDirectDisplayID: Capture]) {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(screen: screen, frozen: frozen[screen.displayID], controller: self)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let keyWindow = overlays.first { $0.frame.contains(mouse) } ?? overlays.first
        keyWindow?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        refreshAll()
    }

    func finish(_ result: SelectionResult?) {
        let old = overlays
        old.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        // Keep the windows alive until the current event finishes dispatching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { old.forEach { $0.close() } }
        NSCursor.arrow.set()
        if SelectionController.active === self { SelectionController.active = nil }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    func toggleWindowMode() {
        guard options.allowsWindowMode else { return }
        windowMode.toggle()
        refreshAll()
    }

    func refreshAll() {
        overlays.forEach { $0.contentView?.needsDisplay = true }
    }

    /// Front-most window under a global AppKit point.
    func window(at globalPoint: CGPoint) -> SCWindow? {
        let cgPoint = Geometry.cgPoint(fromAppKit: globalPoint)
        return windows.first { $0.frame.contains(cgPoint) }
    }
}

final class SelectionOverlayWindow: NSWindow {
    init(screen: NSScreen, frozen: Capture?, controller: SelectionController) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        excludeFromCapture()
        setFrame(screen.frame, display: false)
        contentView = SelectionView(screen: screen, frozen: frozen, controller: controller)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionView: NSView {
    private let screen: NSScreen
    private let frozen: Capture?
    private let frozenImage: NSImage?
    /// Weak: overlay windows outlive the controller briefly after a selection finishes.
    private weak var controller: SelectionController?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var mouse: CGPoint?
    private var hoveredWindow: SCWindow?

    init(screen: NSScreen, frozen: Capture?, controller: SelectionController) {
        self.screen = screen
        self.frozen = frozen
        self.controller = controller
        frozenImage = frozen.map { NSImage(cgImage: $0.image, size: screen.frame.size) }
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) {
        if controller != nil { NSCursor.crosshair.set() }
    }

    private var selectionRect: CGRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        guard let controller else { return }
        NSCursor.crosshair.set()
        mouse = convert(event.locationInWindow, from: nil)
        if controller.windowMode {
            hoveredWindow = controller.window(at: NSEvent.mouseLocation)
            controller.refreshAll()
        } else {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if controller.windowMode { return }
        dragStart = p
        dragCurrent = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        guard !controller.windowMode else { return }
        if event.modifierFlags.contains(.shift), let start = dragStart {
            // Shift constrains to a square.
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            dragCurrent = CGPoint(x: start.x + (p.x >= start.x ? side : -side),
                                  y: start.y + (p.y >= start.y ? side : -side))
        } else {
            dragCurrent = p
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        if controller.windowMode {
            if let window = controller.window(at: NSEvent.mouseLocation) {
                controller.finish(.window(window))
            }
            return
        }
        guard let rect = selectionRect else { return }
        if rect.width >= 4, rect.height >= 4 {
            controller.finish(.area(screen: screen, rect: rect))
        } else if controller.options.clickSelectsScreen {
            controller.finish(.area(screen: screen, rect: bounds))
        } else {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return }
        switch Int(event.keyCode) {
        case 53: // Esc
            controller.finish(nil)
        case 49: // Space
            dragStart = nil
            dragCurrent = nil
            controller.toggleWindowMode()
            hoveredWindow = controller.window(at: NSEvent.mouseLocation)
        case 36, 76: // Return: capture the whole screen
            controller.finish(.area(screen: screen, rect: bounds))
        default:
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.finish(nil) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        frozenImage?.draw(in: bounds)

        let dim = NSColor.black.withAlphaComponent(0.35)
        if controller.windowMode {
            drawWindowMode(ctx: ctx, dim: dim)
        } else if let rect = selectionRect, rect.width > 0 {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(rect)
            ctx.addPath(path)
            ctx.setFillColor(dim.cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawSizeLabel(for: rect)
        } else {
            dim.withAlphaComponent(0.15).setFill()
            bounds.fill()
            drawCrosshair()
            drawHint()
        }

        if !controller.windowMode, Preferences.showMagnifier, let mouse, bounds.contains(mouse) {
            drawMagnifier(at: mouse)
        }
    }

    private func drawWindowMode(ctx: CGContext, dim: NSColor) {
        guard let controller else { return }
        let global = hoveredWindow.map { Geometry.appKitRect(fromCG: $0.frame) }
        let local = global.map { CGRect(x: $0.minX - screen.frame.minX, y: $0.minY - screen.frame.minY,
                                        width: $0.width, height: $0.height) }
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds)
        if let local, local.intersects(bounds) { path.addRect(local) }
        ctx.addPath(path)
        ctx.setFillColor(dim.cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        if let local, local.intersects(bounds) {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            local.fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
            let name = hoveredWindow?.owningApplication?.applicationName ?? ""
            let title = hoveredWindow?.title ?? ""
            drawLabel(title.isEmpty ? name : "\(name) — \(title)", centeredIn: local)
        }
        drawHint(text: "Click a window to capture · Space for area · Esc to cancel")
    }

    private func drawCrosshair() {
        guard let mouse else { return }
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.move(to: CGPoint(x: 0, y: mouse.y + 0.5))
        path.line(to: CGPoint(x: bounds.width, y: mouse.y + 0.5))
        path.move(to: CGPoint(x: mouse.x + 0.5, y: 0))
        path.line(to: CGPoint(x: mouse.x + 0.5, y: bounds.height))
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let scale = frozen?.scale ?? screen.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = CGPoint(x: rect.maxX - size.width - 12, y: rect.minY - size.height - 12)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        if origin.x < 4 { origin.x = rect.minX + 6 }
        let bg = CGRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawLabel(_ text: String, centeredIn rect: CGRect) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let bg = CGRect(x: origin.x - 10, y: origin.y - 5, width: size.width + 20, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawHint(text: String? = nil) {
        guard let controller else { return }
        guard let mouse, bounds.contains(mouse) || controller.windowMode else { return }
        let message = text ?? controller.options.hint
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.height - 90)
        let bg = CGRect(x: origin.x - 14, y: origin.y - 8, width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        (message as NSString).draw(at: origin, withAttributes: attrs)
    }

    private func drawMagnifier(at point: CGPoint) {
        guard let frozen else { return }
        let scale = frozen.scale
        let pixels = 15 // odd so the centre pixel is the cursor
        let loupe: CGFloat = 120
        let px = Int(point.x * scale) - pixels / 2
        let py = Int((bounds.height - point.y) * scale) - pixels / 2
        guard let crop = frozen.image.cropping(to: CGRect(x: px, y: py, width: pixels, height: pixels)) else { return }

        var origin = CGPoint(x: point.x + 24, y: point.y - loupe - 24)
        if origin.x + loupe > bounds.width { origin.x = point.x - loupe - 24 }
        if origin.y < 0 { origin.y = point.y + 24 }
        let rect = CGRect(origin: origin, size: CGSize(width: loupe, height: loupe))

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        clip.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: rect.size).draw(in: rect)
        // Centre pixel marker.
        let cell = loupe / CGFloat(pixels)
        NSColor.white.setStroke()
        let marker = NSBezierPath(rect: CGRect(x: rect.midX - cell / 2, y: rect.midY - cell / 2, width: cell, height: cell))
        marker.lineWidth = 1.5
        marker.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        clip.lineWidth = 2
        clip.stroke()

        let coords = "\(Int(point.x)), \(Int(bounds.height - point.y))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (coords as NSString).size(withAttributes: attrs)
        let labelOrigin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: CGRect(x: labelOrigin.x - 5, y: labelOrigin.y - 2,
                                         width: size.width + 10, height: size.height + 4),
                     xRadius: 4, yRadius: 4).fill()
        (coords as NSString).draw(at: labelOrigin, withAttributes: attrs)
    }
}
