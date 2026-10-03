import AppKit
import ScreenCaptureKit

/// A captured bitmap plus the Retina scale it was taken at.
struct Capture {
    var image: CGImage
    var scale: CGFloat
}

/// Thin wrapper over ScreenCaptureKit for still images.
enum ScreenCapture {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Our own windows that must never show up in a capture (overlays, HUDs, quick access).
    @MainActor
    static func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        let ids = Set(NSApp.windows.filter { $0.identifier == .excludedFromCapture && $0.windowNumber > 0 }
            .map { CGWindowID($0.windowNumber) })
        return content.windows.filter { ids.contains($0.windowID) }
    }

    @MainActor
    static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == screen.displayID }
    }

    /// Captures a display (optionally a sub-rect in display-local top-left points).
    @MainActor
    static func capture(display: SCDisplay, content: SCShareableContent, sourceRect: CGRect? = nil,
                        showsCursor: Bool = false) async throws -> Capture {
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        let rect = sourceRect ?? CGRect(origin: .zero, size: filter.contentRect.size)
        if let sourceRect { config.sourceRect = sourceRect }
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Capture(image: image, scale: scale)
    }

    /// Captures every connected display, keyed by display ID (used to "freeze" the screen during selection).
    @MainActor
    static func captureAllDisplays(content: SCShareableContent) async throws -> [CGDirectDisplayID: Capture] {
        var result: [CGDirectDisplayID: Capture] = [:]
        for display in content.displays {
            result[display.displayID] = try await capture(display: display, content: content)
        }
        return result
    }

    /// Captures a single window on its own, with transparent background and optional shadow.
    static func capture(window: SCWindow, shadow: Bool) async throws -> Capture {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !shadow
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Capture(image: image, scale: scale)
    }

    /// On-screen, normal-level windows ordered front to back (excluding Snippy's own windows).
    static func windowsFrontToBack(content: SCShareableContent) -> [SCWindow] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { dict -> SCWindow? in
            guard let number = dict[kCGWindowNumber as String] as? NSNumber,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let window = byID[CGWindowID(number.uint32Value)],
                  window.owningApplication?.processID != ownPID,
                  window.frame.width > 40, window.frame.height > 40 else { return nil }
            return window
        }
    }
}
