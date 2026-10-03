import AVFoundation
import AppKit
import ScreenCaptureKit

/// Runs every capture / recording workflow.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var isBusy = false
    private var recorder: ScreenRecorder?
    private var recordingKind: HistoryItem.Kind = .video
    private var recordingBorder: RegionBorderWindow?
    private(set) var recordingStart: Date?

    /// Called whenever recording starts or stops so the menu bar can update.
    var onRecordingChanged: ((Bool) -> Void)?

    var isRecording: Bool { recorder != nil }

    func perform(_ action: CaptureAction, fromMenu: Bool = false) {
        Task { await run(action, fromMenu: fromMenu) }
    }

    private func run(_ action: CaptureAction, fromMenu: Bool) async {
        if (action == .recordVideo || action == .recordGIF), isRecording {
            await stopRecording()
            return
        }
        if action == .toggleDesktopIcons {
            DesktopIconsHider.shared.setHidden(!DesktopIconsHider.shared.isHidden)
            return
        }
        guard !isBusy else { return }
        guard Permissions.ensureScreenRecording() else { return }
        isBusy = true
        defer { isBusy = false }
        // Give the status menu time to fade out so it isn't captured.
        if fromMenu { try? await Task.sleep(nanoseconds: 250_000_000) }

        do {
            switch action {
            case .captureArea: try await captureArea(mode: .area)
            case .captureWindow: try await captureArea(mode: .window)
            case .capturePreviousArea: try await capturePreviousArea()
            case .captureFullscreen: try await captureFullscreen()
            case .selfTimer:
                if await Countdown.run(seconds: 5) { try await captureFullscreen() }
            case .scrollingCapture: try await scrollingCapture()
            case .captureText: try await captureText()
            case .recordVideo: try await startRecording(kind: .video)
            case .recordGIF: try await startRecording(kind: .gif)
            case .toggleDesktopIcons: break
            }
        } catch {
            Alerts.show(error, title: "\(action.title) failed")
        }
    }

    // MARK: Screenshots

    private struct Frozen {
        let content: SCShareableContent
        let displays: [CGDirectDisplayID: Capture]
        let windows: [SCWindow]
    }

    private func freeze() async throws -> Frozen {
        let content = try await ScreenCapture.content()
        let displays = try await ScreenCapture.captureAllDisplays(content: content)
        return Frozen(content: content, displays: displays, windows: ScreenCapture.windowsFrontToBack(content: content))
    }

    private func crop(_ capture: Capture, screen: NSScreen, rect: CGRect) -> Capture? {
        let s = CGFloat(capture.image.width) / screen.frame.width
        let pixelRect = CGRect(x: rect.minX * s, y: (screen.frame.height - rect.maxY) * s,
                               width: rect.width * s, height: rect.height * s).integral
        return capture.image.cropping(to: pixelRect).map { Capture(image: $0, scale: capture.scale) }
    }

    private func captureArea(mode: SelectionOptions.Mode) async throws {
        let frozen = try await freeze()
        var options = SelectionOptions()
        options.mode = mode
        guard let result = await SelectionController.select(frozen: frozen.displays, windows: frozen.windows,
                                                            options: options) else { return }
        switch result {
        case let .area(screen, rect):
            guard let full = frozen.displays[screen.displayID], let capture = crop(full, screen: screen, rect: rect) else {
                return
            }
            Preferences.lastArea = SavedArea(displayID: screen.displayID, rect: rect)
            OutputManager.handle(capture)
        case let .window(window):
            let capture = try await ScreenCapture.capture(window: window, shadow: Preferences.captureWindowShadow)
            OutputManager.handle(capture)
        }
    }

    private func capturePreviousArea() async throws {
        guard let area = Preferences.lastArea, let screen = NSScreen.screen(withDisplayID: area.displayID) else {
            try await captureArea(mode: .area)
            return
        }
        let content = try await ScreenCapture.content()
        guard let display = ScreenCapture.display(for: screen, in: content) else { return }
        let capture = try await ScreenCapture.capture(display: display, content: content,
                                                      sourceRect: screen.displayLocalTopLeftRect(area.rect))
        OutputManager.handle(capture)
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func captureFullscreen() async throws {
        let content = try await ScreenCapture.content()
        guard let display = ScreenCapture.display(for: screenUnderMouse(), in: content) else { return }
        OutputManager.handle(try await ScreenCapture.capture(display: display, content: content))
    }

    /// Asks the user for a region; window picks are converted to the window's on-screen rect.
    private func selectRegion(options: SelectionOptions) async throws -> (NSScreen, CGRect, Frozen)? {
        let frozen = try await freeze()
        guard let result = await SelectionController.select(frozen: frozen.displays, windows: frozen.windows,
                                                            options: options) else { return nil }
        switch result {
        case let .area(screen, rect):
            return (screen, rect, frozen)
        case let .window(window):
            let global = Geometry.appKitRect(fromCG: window.frame)
            let center = CGPoint(x: global.midX, y: global.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
            let clipped = global.intersection(screen.frame)
            let local = clipped.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).integral
            return (screen, local, frozen)
        }
    }

    private func scrollingCapture() async throws {
        var options = SelectionOptions()
        options.hint = "Select the scrollable area · Space for window · Esc to cancel"
        guard let selection = try await selectRegion(options: options) else { return }
        let (screen, rect, frozen) = selection
        guard let display = ScreenCapture.display(for: screen, in: frozen.content) else { return }
        ScrollingCaptureSession.start(screen: screen, display: display, rect: rect) { capture in
            if let capture { OutputManager.handle(capture) }
        }
    }

    private func captureText() async throws {
        var options = SelectionOptions()
        options.hint = "Select text to copy · Esc to cancel"
        guard let selection = try await selectRegion(options: options) else { return }
        let (screen, rect, frozen) = selection
        guard let full = frozen.displays[screen.displayID],
              let capture = crop(full, screen: screen, rect: rect) else { return }
        let text = try await TextRecognizer.recognize(capture.image, keepLineBreaks: Preferences.ocrKeepLineBreaks)
        if text.isEmpty {
            HUD.show("No text found", symbol: "text.magnifyingglass")
        } else {
            Clipboard.copy(text: text)
            Sound.playCapture()
            HUD.show("Copied \(text.count) characters", symbol: "text.viewfinder")
        }
    }

    // MARK: Recording

    private func startRecording(kind: HistoryItem.Kind) async throws {
        var options = SelectionOptions()
        options.clickSelectsScreen = true
        options.hint = "Drag to record an area · Click for full screen · Space for window · Esc to cancel"
        guard let selection = try await selectRegion(options: options) else { return }
        let (screen, rect, _) = selection

        let wantsMic = Preferences.recordMicrophone && kind == .video
        if wantsMic {
            if #available(macOS 15.0, *) {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted { HUD.show("Microphone access denied", symbol: "mic.slash.fill") }
            } else {
                HUD.show("Microphone recording requires macOS 15", symbol: "mic.slash.fill")
            }
        }

        let isFullScreen = rect.size == screen.frame.size
        if !isFullScreen {
            let border = RegionBorderWindow(globalRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            border.orderFrontRegardless()
            recordingBorder = border
        }

        if Preferences.recordCountdown, !(await Countdown.run(seconds: 3, on: screen)) {
            recordingBorder?.orderOut(nil)
            recordingBorder = nil
            return
        }

        let content = try await ScreenCapture.content()
        guard let display = ScreenCapture.display(for: screen, in: content) else { return }
        let directory = kind == .gif ? FileManager.default.temporaryDirectory : Preferences.saveDirectory
        let url = FileNamer.uniqueURL(in: directory, prefix: "Snippy Recording", ext: "mp4")
        let recorder = ScreenRecorder(configuration: .init(
            display: display,
            sourceRect: screen.displayLocalTopLeftRect(rect),
            scale: screen.backingScaleFactor,
            fps: kind == .gif ? max(Preferences.gifFPS, 10) : Preferences.recordingFPS,
            showsCursor: Preferences.recordShowCursor,
            systemAudio: Preferences.recordSystemAudio && kind == .video,
            microphone: wantsMic,
            excludedWindows: ScreenCapture.excludedWindows(in: content),
            outputURL: url,
            highQuality: Preferences.recordingQuality == .high
        ))
        recorder.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                await self.stopRecording()
                Alerts.show(error, title: "Recording stopped")
            }
        }
        do {
            try await recorder.start()
        } catch {
            recordingBorder?.orderOut(nil)
            recordingBorder = nil
            throw error
        }
        self.recorder = recorder
        recordingKind = kind
        recordingStart = Date()
        if Preferences.recordHighlightClicks { ClickHighlighter.shared.start() }
        onRecordingChanged?(true)
    }

    func stopRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        recordingStart = nil
        ClickHighlighter.shared.stop()
        recordingBorder?.orderOut(nil)
        recordingBorder = nil
        onRecordingChanged?(false)

        do {
            let videoURL = try await recorder.stop()
            if recordingKind == .gif {
                HUD.show("Exporting GIF…", symbol: "hourglass", duration: 30)
                let gifURL = FileNamer.uniqueURL(in: Preferences.saveDirectory, prefix: "Snippy Recording", ext: "gif")
                try await GIFExporter.export(videoURL: videoURL, to: gifURL, fps: Preferences.gifFPS,
                                             maxWidth: Preferences.gifMaxWidth)
                try? FileManager.default.removeItem(at: videoURL)
                HUD.hide()
                OutputManager.handleRecording(url: gifURL, kind: .gif)
            } else {
                OutputManager.handleRecording(url: videoURL, kind: .video)
            }
        } catch {
            HUD.hide()
            Alerts.show(error, title: "Couldn't save the recording")
        }
    }

    func cancelRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        recordingStart = nil
        ClickHighlighter.shared.stop()
        recordingBorder?.orderOut(nil)
        recordingBorder = nil
        onRecordingChanged?(false)
        await recorder.cancel()
        HUD.show("Recording discarded", symbol: "trash.fill")
    }
}
