import AppKit
import Carbon.HIToolbox

/// Every user-triggerable capture command. Each can carry a global shortcut.
enum CaptureAction: String, CaseIterable, Identifiable {
    case captureArea
    case capturePreviousArea
    case captureFullscreen
    case captureWindow
    case scrollingCapture
    case captureText
    case selfTimer
    case recordVideo
    case recordGIF
    case toggleDesktopIcons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .scrollingCapture: return "Scrolling Capture"
        case .captureText: return "Capture Text (OCR)"
        case .selfTimer: return "Self-Timer (5s)"
        case .recordVideo: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .toggleDesktopIcons: return "Hide Desktop Icons"
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: return "rectangle.dashed"
        case .capturePreviousArea: return "arrow.counterclockwise"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .scrollingCapture: return "arrow.up.and.down.text.horizontal"
        case .captureText: return "text.viewfinder"
        case .selfTimer: return "timer"
        case .recordVideo: return "record.circle"
        case .recordGIF: return "photo.stack"
        case .toggleDesktopIcons: return "eye.slash"
        }
    }

    var defaultHotkey: Hotkey? {
        let ctrlShift = UInt32(controlKey | shiftKey)
        switch self {
        case .captureArea: return Hotkey(keyCode: UInt32(kVK_ANSI_4), modifiers: ctrlShift)
        case .capturePreviousArea: return Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlShift)
        case .captureFullscreen: return Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: ctrlShift)
        case .captureWindow: return Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: ctrlShift)
        case .scrollingCapture: return Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: ctrlShift)
        case .captureText: return Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: ctrlShift)
        case .selfTimer: return nil
        case .recordVideo: return Hotkey(keyCode: UInt32(kVK_ANSI_5), modifiers: ctrlShift)
        case .recordGIF: return Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: ctrlShift)
        case .toggleDesktopIcons: return nil
        }
    }

    private var defaultsKey: String { "hotkey.\(rawValue)" }

    /// The configured shortcut, or nil if the user cleared it.
    var hotkey: Hotkey? {
        get {
            guard let stored = Preferences.defaults.string(forKey: defaultsKey) else { return defaultHotkey }
            return Hotkey(storageString: stored)
        }
        nonmutating set {
            Preferences.defaults.set(newValue?.storageString ?? "none", forKey: defaultsKey)
        }
    }

    func resetHotkey() {
        Preferences.defaults.removeObject(forKey: defaultsKey)
    }
}

/// A key code plus Carbon modifier mask.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(storageString: String) {
        let parts = storageString.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        keyCode = parts[0]
        modifiers = parts[1]
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        let isFunctionKey = Hotkey.functionKeyCodes.contains(Int(code))
        // Require a "real" modifier unless it's a function key, so plain typing is never hijacked.
        guard isFunctionKey || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        keyCode = code
        modifiers = mods
    }

    var storageString: String { "\(keyCode),\(modifiers)" }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// Lower-case key used for NSMenuItem.keyEquivalent (empty if not representable).
    var menuKeyEquivalent: String {
        let name = Hotkey.keyNames[Int(keyCode)] ?? ""
        return name.count == 1 ? name.lowercased() : ""
    }

    var keyName: String { Hotkey.keyNames[Int(keyCode)] ?? "#\(keyCode)" }

    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// Registers system-wide shortcuts through the Carbon hot key API (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: CaptureAction] = [:]
    private var eventHandler: EventHandlerRef?
    var onTrigger: ((CaptureAction) -> Void)?

    private init() {}

    func reloadAll() {
        unregisterAll()
        installHandlerIfNeeded()
        var nextID: UInt32 = 1
        for action in CaptureAction.allCases {
            guard let hotkey = action.hotkey else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x534E_5059), id: nextID) // 'SNPY'
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                handlers[nextID] = action
            } else {
                NSLog("Snippy: could not register hotkey \(hotkey.displayString) for \(action.title) (\(status))")
            }
            nextID += 1
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        guard let action = handlers[id] else { return }
        onTrigger?(action)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.handle(id: id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
