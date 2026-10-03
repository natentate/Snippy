import AppKit
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case standard, high

    var id: String { rawValue }
    var title: String { self == .high ? "High" : "Standard" }
}

/// Typed access to user settings. SwiftUI views use `@AppStorage` with the same keys.
enum Preferences {
    enum Key {
        static let saveDirectory = "saveDirectory"
        static let imageFormat = "imageFormat"
        static let copyToClipboard = "copyToClipboard"
        static let saveAfterCapture = "saveAfterCapture"
        static let showQuickAccess = "showQuickAccess"
        static let quickAccessAutoClose = "quickAccessAutoClose"
        static let openEditorAfterCapture = "openEditorAfterCapture"
        static let playSound = "playSound"
        static let captureWindowShadow = "captureWindowShadow"
        static let showMagnifier = "showMagnifier"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let recordingFPS = "recordingFPS"
        static let recordingQuality = "recordingQuality"
        static let recordShowCursor = "recordShowCursor"
        static let recordHighlightClicks = "recordHighlightClicks"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordCountdown = "recordCountdown"
        static let gifFPS = "gifFPS"
        static let gifMaxWidth = "gifMaxWidth"
        static let ocrKeepLineBreaks = "ocrKeepLineBreaks"
        static let lastArea = "lastArea"
    }

    static let defaults = UserDefaults.standard

    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snippy", isDirectory: true)
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.saveDirectory: defaultSaveDirectory.path,
            Key.imageFormat: ImageFormat.png.rawValue,
            Key.copyToClipboard: true,
            Key.saveAfterCapture: true,
            Key.showQuickAccess: true,
            Key.quickAccessAutoClose: 8.0,
            Key.openEditorAfterCapture: false,
            Key.playSound: true,
            Key.captureWindowShadow: true,
            Key.showMagnifier: true,
            Key.hideDesktopIcons: false,
            Key.recordingFPS: 30,
            Key.recordingQuality: VideoQuality.high.rawValue,
            Key.recordShowCursor: true,
            Key.recordHighlightClicks: false,
            Key.recordSystemAudio: false,
            Key.recordMicrophone: false,
            Key.recordCountdown: true,
            Key.gifFPS: 15,
            Key.gifMaxWidth: 800,
            Key.ocrKeepLineBreaks: true,
        ])
    }

    static var saveDirectory: URL {
        get {
            let path = defaults.string(forKey: Key.saveDirectory) ?? defaultSaveDirectory.path
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.saveDirectory) }
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: Key.imageFormat) ?? "") ?? .png
    }

    static var copyToClipboard: Bool { defaults.bool(forKey: Key.copyToClipboard) }
    static var saveAfterCapture: Bool { defaults.bool(forKey: Key.saveAfterCapture) }
    static var showQuickAccess: Bool { defaults.bool(forKey: Key.showQuickAccess) }
    static var quickAccessAutoClose: Double { defaults.double(forKey: Key.quickAccessAutoClose) }
    static var openEditorAfterCapture: Bool { defaults.bool(forKey: Key.openEditorAfterCapture) }
    static var playSound: Bool { defaults.bool(forKey: Key.playSound) }
    static var captureWindowShadow: Bool { defaults.bool(forKey: Key.captureWindowShadow) }
    static var showMagnifier: Bool { defaults.bool(forKey: Key.showMagnifier) }
    static var hideDesktopIcons: Bool {
        get { defaults.bool(forKey: Key.hideDesktopIcons) }
        set { defaults.set(newValue, forKey: Key.hideDesktopIcons) }
    }
    static var recordingFPS: Int { max(5, min(60, defaults.integer(forKey: Key.recordingFPS))) }
    static var recordingQuality: VideoQuality {
        VideoQuality(rawValue: defaults.string(forKey: Key.recordingQuality) ?? "") ?? .high
    }
    static var recordShowCursor: Bool { defaults.bool(forKey: Key.recordShowCursor) }
    static var recordHighlightClicks: Bool { defaults.bool(forKey: Key.recordHighlightClicks) }
    static var recordSystemAudio: Bool { defaults.bool(forKey: Key.recordSystemAudio) }
    static var recordMicrophone: Bool { defaults.bool(forKey: Key.recordMicrophone) }
    static var recordCountdown: Bool { defaults.bool(forKey: Key.recordCountdown) }
    static var gifFPS: Int { max(5, min(30, defaults.integer(forKey: Key.gifFPS))) }
    static var gifMaxWidth: Int { max(200, defaults.integer(forKey: Key.gifMaxWidth)) }
    static var ocrKeepLineBreaks: Bool { defaults.bool(forKey: Key.ocrKeepLineBreaks) }

    /// The last area captured, so "Capture Previous Area" can repeat it.
    static var lastArea: SavedArea? {
        get {
            guard let data = defaults.data(forKey: Key.lastArea) else { return nil }
            return try? JSONDecoder().decode(SavedArea.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.lastArea)
            } else {
                defaults.removeObject(forKey: Key.lastArea)
            }
        }
    }
}

/// A rectangle on a particular display, in screen-local points (bottom-left origin).
struct SavedArea: Codable {
    var displayID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}
