import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

extension NSUserInterfaceItemIdentifier {
    /// Windows with this identifier are hidden from every screenshot and recording.
    static let excludedFromCapture = NSUserInterfaceItemIdentifier("snippy.excludedFromCapture")
}

extension NSWindow {
    func excludeFromCapture() { identifier = .excludedFromCapture }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(withDisplayID id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }

    /// Converts a rect in this screen's local coordinates (bottom-left origin)
    /// to ScreenCaptureKit's display-local coordinates (top-left origin).
    func displayLocalTopLeftRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

enum Geometry {
    /// Converts a global CoreGraphics rect (top-left origin of the primary display) to a global AppKit rect.
    static func appKitRect(fromCG rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: NSScreen.primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: NSScreen.primaryHeight - point.y)
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }

    func nsImage(scale: CGFloat) -> NSImage {
        NSImage(cgImage: self, size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}

enum ImageEncoder {
    static func data(for image: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func load(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Reads the image's DPI to recover its Retina scale factor.
    static func scale(of url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { return 1 }
        return max(1, CGFloat(dpi / 72).rounded())
    }
}

enum FileNamer {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func uniqueURL(in directory: URL, prefix: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(prefix) \(formatter.string(from: Date()))"
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }
}

enum Sound {
    static func playCapture() {
        guard Preferences.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }
}

enum Clipboard {
    static func copy(image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func image() -> (CGImage, CGFloat)? {
        guard let image = NSImage(pasteboard: NSPasteboard.general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = image.size.width > 0 ? max(1, (CGFloat(cg.width) / image.size.width).rounded()) : 1
        return (cg, scale)
    }
}

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true if capture is allowed; otherwise prompts the user and returns false.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snippy needs Screen Recording permission"
        alert.informativeText = "Enable Snippy in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch Snippy."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacyPane("Privacy_ScreenCapture")
        }
        return false
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Alerts {
    static func show(_ error: Error, title: String = "Something went wrong") {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

struct SnippyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
