import AppKit

/// Everything that happens after a capture: sound, clipboard, file, history, quick access.
@MainActor
enum OutputManager {
    static func handle(_ capture: Capture) {
        Sound.playCapture()
        if Preferences.copyToClipboard {
            Clipboard.copy(image: capture.image, scale: capture.scale)
        }
        let format = Preferences.imageFormat
        let autosave = Preferences.saveAfterCapture
        let directory = autosave ? Preferences.saveDirectory : HistoryStore.directory
        let url = FileNamer.uniqueURL(in: directory, prefix: "Snippy", ext: format.fileExtension)
        var savedURL: URL?
        if let data = ImageEncoder.data(for: capture.image, format: format, scale: capture.scale) {
            do {
                try data.write(to: url)
                savedURL = url
                HistoryStore.shared.add(url: url, kind: .image, isInternal: !autosave)
            } catch {
                HUD.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }

        if Preferences.openEditorAfterCapture {
            EditorWindowController.open(capture: capture, fileURL: savedURL)
        } else if Preferences.showQuickAccess {
            QuickAccessManager.shared.show(.image(capture, savedURL, saved: autosave))
        } else if Preferences.copyToClipboard {
            HUD.show("Copied to clipboard")
        }
    }

    static func handleRecording(url: URL, kind: HistoryItem.Kind) {
        Sound.playCapture()
        HistoryStore.shared.add(url: url, kind: kind, isInternal: false)
        if Preferences.showQuickAccess {
            QuickAccessManager.shared.show(.media(url, kind))
        } else {
            HUD.show(kind == .gif ? "GIF saved" : "Recording saved")
        }
    }

    /// Moves/copies an internal capture into the user's save folder.
    static func saveToFolder(_ capture: Capture, existing: URL?) -> URL? {
        let format = Preferences.imageFormat
        let target = FileNamer.uniqueURL(in: Preferences.saveDirectory, prefix: "Snippy", ext: format.fileExtension)
        do {
            if let existing, existing.path.hasPrefix(HistoryStore.directory.path) {
                try FileManager.default.moveItem(at: existing, to: target)
                HistoryStore.shared.replace(path: existing.path, with: target, isInternal: false)
            } else if let data = ImageEncoder.data(for: capture.image, format: format, scale: capture.scale) {
                try data.write(to: target)
                HistoryStore.shared.add(url: target, kind: .image, isInternal: false)
            }
            return target
        } catch {
            Alerts.show(error, title: "Couldn't save the screenshot")
            return nil
        }
    }

    static func saveAs(_ capture: Capture) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ImageFormat.allCases.map(\.utType)
        panel.nameFieldStringValue = FileNamer.uniqueURL(in: Preferences.saveDirectory, prefix: "Snippy",
                                                         ext: Preferences.imageFormat.fileExtension).lastPathComponent
        panel.directoryURL = Preferences.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let format = ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .png
        guard let data = ImageEncoder.data(for: capture.image, format: format, scale: capture.scale) else { return nil }
        do {
            try data.write(to: url)
            HistoryStore.shared.add(url: url, kind: .image, isInternal: false)
            return url
        } catch {
            Alerts.show(error, title: "Couldn't save the screenshot")
            return nil
        }
    }

    static func reopen(_ item: HistoryItem) {
        switch item.kind {
        case .image:
            guard let image = ImageEncoder.load(url: item.url) else { return }
            let capture = Capture(image: image, scale: ImageEncoder.scale(of: item.url))
            QuickAccessManager.shared.show(.image(capture, item.url, saved: !item.isInternal))
        case .video, .gif:
            QuickAccessManager.shared.show(.media(item.url, item.kind))
        }
    }
}
