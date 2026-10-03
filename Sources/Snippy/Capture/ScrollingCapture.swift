import AppKit
import ScreenCaptureKit

/// Stitches successive captures of a scrolling region into one tall image.
final class ScrollStitcher {
    private var strips: [CGImage] = []
    private var lastProfile: [Float] = []
    private var width = 0
    private var height = 0
    private(set) var totalHeight = 0
    static let maxHeight = 40_000
    private static let columns = 32

    var frameCount: Int { strips.count }

    /// Adds a frame; returns true if it contributed new content.
    @discardableResult
    func add(_ image: CGImage) -> Bool {
        guard let profile = Self.rowProfile(image) else { return false }
        if strips.isEmpty {
            strips.append(image)
            lastProfile = profile
            width = image.width
            height = image.height
            totalHeight = height
            return true
        }
        guard image.width == width, image.height == height, totalHeight < Self.maxHeight,
              let dy = Self.scrollOffset(previous: lastProfile, current: profile, height: height), dy > 0,
              let strip = image.cropping(to: CGRect(x: 0, y: height - dy, width: width, height: dy)) else {
            return false
        }
        strips.append(strip)
        totalHeight += dy
        lastProfile = profile
        return true
    }

    func makeImage() -> CGImage? {
        guard let first = strips.first else { return nil }
        let space = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for strip in strips {
            // CoreGraphics' origin is bottom-left.
            ctx.draw(strip, in: CGRect(x: 0, y: totalHeight - top - strip.height, width: strip.width, height: strip.height))
            top += strip.height
        }
        return ctx.makeImage()
    }

    /// Per-row averages of `columns` horizontal blocks, in grayscale.
    private static func rowProfile(_ image: CGImage) -> [Float]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h)
        let bytesPerRow = ctx.bytesPerRow
        var profile = [Float](repeating: 0, count: h * columns)
        let blockWidth = max(1, w / columns)
        for y in 0..<h {
            let row = bytes + y * bytesPerRow
            for c in 0..<columns {
                let start = c * blockWidth
                let end = min(w, start + blockWidth)
                guard start < end else { continue }
                var sum = 0
                var x = start
                while x < end { sum += Int(row[x]); x += 2 }
                profile[y * columns + c] = Float(sum) / Float((end - start + 1) / 2)
            }
        }
        return profile
    }

    /// How many rows the content moved up between two frames (nil if no confident match).
    private static func scrollOffset(previous: [Float], current: [Float], height h: Int) -> Int? {
        let cols = columns
        func score(_ dy: Int) -> Float {
            // Row y of `current` should equal row y+dy of `previous`.
            let rows = h - dy
            var total: Float = 0
            var n = 0
            var y = 0
            while y < rows {
                let a = (y + dy) * cols, b = y * cols
                for c in 0..<cols { total += abs(previous[a + c] - current[b + c]) }
                n += cols
                y += 2
            }
            return n > 0 ? total / Float(n) : .greatestFiniteMagnitude
        }

        let still = score(0)
        if still < 0.5 { return 0 }
        let minOverlap = max(16, h / 6)
        var best = (dy: 0, score: Float.greatestFiniteMagnitude)
        for dy in 1..<(h - minOverlap) {
            let s = score(dy)
            if s < best.score { best = (dy, s) }
        }
        guard best.score < 4, best.score < still * 0.6 else { return nil }
        return best.dy
    }
}

/// Drives a scrolling capture: periodically grabs the selected region while the user scrolls.
@MainActor
final class ScrollingCaptureSession {
    private static var active: ScrollingCaptureSession?

    private let screen: NSScreen
    private let display: SCDisplay
    private let localRect: CGRect
    private let stitcher = ScrollStitcher()
    private let stitchQueue = DispatchQueue(label: "app.snippy.stitch")
    private var timer: Timer?
    private var inFlight = false
    private var border: RegionBorderWindow?
    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var completion: ((Capture?) -> Void)?
    private var scale: CGFloat = 2
    private var finished = false

    static func start(screen: NSScreen, display: SCDisplay, rect: CGRect, completion: @escaping (Capture?) -> Void) {
        active?.finish(cancelled: true)
        let session = ScrollingCaptureSession(screen: screen, display: display, rect: rect)
        session.completion = completion
        active = session
        session.begin()
    }

    private init(screen: NSScreen, display: SCDisplay, rect: CGRect) {
        self.screen = screen
        self.display = display
        localRect = rect
    }

    private func begin() {
        let global = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let border = RegionBorderWindow(globalRect: global, color: .systemBlue)
        border.orderFrontRegardless()
        self.border = border
        showPanel(near: global)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    private func showPanel(near rect: CGRect) {
        let size = CGSize(width: 340, height: 44)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + 12 }
        if origin.y + size.height > screen.visibleFrame.maxY { origin.y = rect.minY + 12 }
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.excludeFromCapture()

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        let label = NSTextField(labelWithString: "Scroll slowly…")
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let stack = NSStackView(views: [label, NSView(), cancel, done])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        stack.frame = effect.bounds
        stack.autoresizingMask = [.width, .height]
        effect.addSubview(stack)
        panel.contentView = effect
        panel.orderFrontRegardless()
        self.panel = panel
        statusLabel = label
    }

    private func tick() async {
        guard !finished, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let content = try await ScreenCapture.content()
            let capture = try await ScreenCapture.capture(display: display, content: content,
                                                          sourceRect: screen.displayLocalTopLeftRect(localRect))
            scale = capture.scale
            let stitcher = stitcher
            let total: Int = await withCheckedContinuation { cont in
                stitchQueue.async {
                    stitcher.add(capture.image)
                    cont.resume(returning: stitcher.totalHeight)
                }
            }
            statusLabel?.stringValue = "Scroll slowly… \(Int(CGFloat(total) / scale)) pt captured"
            if total >= ScrollStitcher.maxHeight { finish(cancelled: false) }
        } catch {
            NSLog("Snippy scrolling capture frame failed: \(error)")
        }
    }

    @objc private func donePressed() { finish(cancelled: false) }
    @objc private func cancelPressed() { finish(cancelled: true) }

    private func finish(cancelled: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        border?.orderOut(nil)
        panel?.orderOut(nil)
        if ScrollingCaptureSession.active === self { ScrollingCaptureSession.active = nil }
        let completion = completion
        guard !cancelled else { completion?(nil); return }
        let stitcher = stitcher
        let scale = scale
        stitchQueue.async {
            let image = stitcher.makeImage()
            DispatchQueue.main.async { completion?(image.map { Capture(image: $0, scale: scale) }) }
        }
    }
}
