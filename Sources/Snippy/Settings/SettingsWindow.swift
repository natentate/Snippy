import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snippy Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            RecordingSettings().tabItem { Label("Recording", systemImage: "record.circle") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.saveDirectory) private var saveDirectory = Preferences.defaultSaveDirectory.path
    @AppStorage(Preferences.Key.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(Preferences.Key.copyToClipboard) private var copyToClipboard = true
    @AppStorage(Preferences.Key.saveAfterCapture) private var saveAfterCapture = true
    @AppStorage(Preferences.Key.showQuickAccess) private var showQuickAccess = true
    @AppStorage(Preferences.Key.quickAccessAutoClose) private var autoClose = 8.0
    @AppStorage(Preferences.Key.openEditorAfterCapture) private var openEditor = false
    @AppStorage(Preferences.Key.playSound) private var playSound = true
    @AppStorage(Preferences.Key.captureWindowShadow) private var windowShadow = true
    @AppStorage(Preferences.Key.showMagnifier) private var showMagnifier = true
    @AppStorage(Preferences.Key.ocrKeepLineBreaks) private var keepLineBreaks = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Snippy at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder", isOn: $saveAfterCapture)
                Toggle("Show Quick Access overlay", isOn: $showQuickAccess)
                if showQuickAccess {
                    Picker("Auto-close overlay", selection: $autoClose) {
                        Text("Never").tag(0.0)
                        Text("5 seconds").tag(5.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                    }
                }
                Toggle("Open annotation editor immediately", isOn: $openEditor)
                Toggle("Play capture sound", isOn: $playSound)
            }
            Section("Screenshots") {
                Picker("Format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Include window shadow", isOn: $windowShadow)
                Toggle("Show magnifier while selecting", isOn: $showMagnifier)
                Toggle("Keep line breaks in captured text (OCR)", isOn: $keepLineBreaks)
                HStack {
                    Text("Save to")
                    Spacer()
                    Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url.path }
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    HStack {
                        Label(action.title, systemImage: action.symbol)
                        Spacer()
                        HotkeyRecorder(action: action)
                    }
                }
            } footer: {
                Text("Shortcuts work system-wide. Click a shortcut, then press the new key combination (it must include ⌘, ⌥ or ⌃). Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRecorder: View {
    let action: CaptureAction
    @State private var hotkey: Hotkey?
    @State private var isRecording = false
    @State private var monitor: Any?

    init(action: CaptureAction) {
        self.action = action
        _hotkey = State(initialValue: action.hotkey)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : (hotkey?.displayString ?? "None"))
                    .frame(minWidth: 90)
                    .foregroundStyle(isRecording ? Color.accentColor : (hotkey == nil ? Color.secondary : Color.primary))
            }
            Button {
                stopRecording()
                action.hotkey = nil
                hotkey = nil
                HotKeyCenter.shared.reloadAll()
            } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
                .disabled(hotkey == nil)
            Button {
                stopRecording()
                action.resetHotkey()
                hotkey = action.hotkey
                HotKeyCenter.shared.reloadAll()
            } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Reset to default")
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording { stopRecording(); return }
        isRecording = true
        // Suspend global shortcuts so pressing an existing one doesn't fire it.
        HotKeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if let new = Hotkey(event: event) {
                action.hotkey = new
                hotkey = new
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            HotKeyCenter.shared.reloadAll()
        }
    }
}

private struct RecordingSettings: View {
    @AppStorage(Preferences.Key.recordingFPS) private var fps = 30
    @AppStorage(Preferences.Key.recordingQuality) private var quality = VideoQuality.high.rawValue
    @AppStorage(Preferences.Key.recordShowCursor) private var showCursor = true
    @AppStorage(Preferences.Key.recordHighlightClicks) private var highlightClicks = false
    @AppStorage(Preferences.Key.recordSystemAudio) private var systemAudio = false
    @AppStorage(Preferences.Key.recordMicrophone) private var microphone = false
    @AppStorage(Preferences.Key.recordCountdown) private var countdown = true
    @AppStorage(Preferences.Key.gifFPS) private var gifFPS = 15
    @AppStorage(Preferences.Key.gifMaxWidth) private var gifMaxWidth = 800

    var body: some View {
        Form {
            Section("Video") {
                Picker("Frame rate", selection: $fps) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Record system audio", isOn: $systemAudio)
                Toggle("Record microphone (macOS 15+)", isOn: $microphone)
            }
            Section("Video & GIF") {
                Toggle("Show cursor", isOn: $showCursor)
                Toggle("Highlight mouse clicks", isOn: $highlightClicks)
                Toggle("3-second countdown before recording", isOn: $countdown)
            }
            Section("GIF") {
                Picker("Frame rate", selection: $gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                    Text("25 fps").tag(25)
                }
                Picker("Maximum width", selection: $gifMaxWidth) {
                    Text("480 px").tag(480)
                    Text("640 px").tag(640)
                    Text("800 px").tag(800)
                    Text("1200 px").tag(1200)
                    Text("1600 px").tag(1600)
                }
            }
            Section {
                Text("To stop a recording, click the red timer in the menu bar or press the recording shortcut again. Right-click the timer to discard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Snippy").font(.largeTitle.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Screenshots, screen recordings, GIFs, scrolling capture, OCR and annotation — all from the menu bar.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("Screen Recording Permission…") { Permissions.openPrivacyPane("Privacy_ScreenCapture") }
                Button("Open Captures Folder") { NSWorkspace.shared.open(Preferences.saveDirectory) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
