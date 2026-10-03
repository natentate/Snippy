import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    let state: EditorState
    private let canvas: CanvasView

    static func open(capture: Capture, fileURL: URL?) {
        let controller = EditorWindowController(capture: capture, fileURL: fileURL)
        openEditors.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    static func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url)
    }

    static func openFile(_ url: URL) {
        guard let image = ImageEncoder.load(url: url) else {
            Alerts.show(SnippyError("The file isn't a readable image."), title: "Couldn't open \(url.lastPathComponent)")
            return
        }
        open(capture: Capture(image: image, scale: ImageEncoder.scale(of: url)), fileURL: url)
    }

    private init(capture: Capture, fileURL: URL?) {
        state = EditorState(capture: capture, fileURL: fileURL)
        canvas = CanvasView(state: state)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pointSize = CGSize(width: CGFloat(capture.image.width) / capture.scale,
                               height: CGFloat(capture.image.height) / capture.scale)
        let toolbarHeight: CGFloat = 52
        let maxW = screen.visibleFrame.width * 0.85, maxH = screen.visibleFrame.height * 0.85
        let size = CGSize(width: min(maxW, max(760, pointSize.width + 48)),
                          height: min(maxH, max(420, pointSize.height + 48 + toolbarHeight)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = fileURL?.lastPathComponent ?? "Annotate"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 640, height: 360)
        window.center()
        super.init(window: window)
        window.delegate = self

        let toolbar = NSHostingView(rootView: EditorToolbar(state: state) { [weak self] action in
            self?.handle(action)
        })
        let container = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        container.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        canvas.onCommand = { [weak self] command in self?.handle(command) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func handle(_ command: CanvasView.Command) {
        switch command {
        case .copy: handle(EditorAction.copy)
        case .save: handle(EditorAction.save)
        case .saveAs: handle(EditorAction.saveAs)
        case .close: window?.performClose(nil)
        case .done: handle(EditorAction.done)
        }
    }

    private func handle(_ action: EditorAction) {
        switch action {
        case .copy:
            let output = state.flattened()
            Clipboard.copy(image: output.image, scale: output.scale)
            HUD.show("Copied to clipboard")
        case .save:
            let output = state.flattened()
            if let url = state.fileURL, !url.path.hasPrefix(HistoryStore.directory.path),
               let data = ImageEncoder.data(for: output.image, format: format(for: url), scale: output.scale) {
                do {
                    try data.write(to: url)
                    HUD.show("Saved", symbol: "folder.fill")
                } catch {
                    Alerts.show(error, title: "Couldn't save")
                }
            } else if let url = OutputManager.saveToFolder(output, existing: nil) {
                state.fileURL = url
                window?.title = url.lastPathComponent
                HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "folder.fill")
            }
        case .saveAs:
            if let url = OutputManager.saveAs(state.flattened()) {
                state.fileURL = url
                window?.title = url.lastPathComponent
            }
        case .pin:
            PinnedImageWindow.pin(state.flattened())
        case .share:
            let output = state.flattened()
            let url = FileNamer.uniqueURL(in: FileManager.default.temporaryDirectory, prefix: "Snippy", ext: "png")
            if let data = ImageEncoder.data(for: output.image, format: .png, scale: output.scale) {
                try? data.write(to: url)
                let picker = NSSharingServicePicker(items: [url])
                let anchor = CGRect(x: canvas.bounds.maxX - 40, y: 0, width: 1, height: 1)
                picker.show(relativeTo: anchor, of: canvas, preferredEdge: .minY)
            }
        case .undo: state.undo()
        case .redo: state.redo()
        case .applyCrop: state.applyCrop()
        case .clear: state.clearAll()
        case .done:
            let output = state.flattened()
            Clipboard.copy(image: output.image, scale: output.scale)
            if let url = state.fileURL,
               let data = ImageEncoder.data(for: output.image, format: format(for: url), scale: output.scale) {
                try? data.write(to: url)
            }
            HUD.show("Copied to clipboard")
            window?.close()
        }
    }

    private func format(for url: URL) -> ImageFormat {
        ImageFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() } ?? .png
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.openEditors.removeAll { $0 === self }
    }
}

enum EditorAction { case copy, save, saveAs, pin, share, undo, redo, applyCrop, clear, done }

struct EditorToolbar: View {
    @ObservedObject var state: EditorState
    var perform: (EditorAction) -> Void

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue,
                                      .systemPurple, .black, .white]
    private let widths: [CGFloat] = [2, 3, 5, 8]
    private let widthLabels: [CGFloat: String] = [2: "S", 3: "M", 5: "L", 8: "XL"]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { state.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(state.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.shortcut ?? " ").uppercased()))")
                }
            }

            Divider().frame(height: 24)

            HStack(spacing: 4) {
                ForEach(palette, id: \.self) { color in
                    Button { state.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary.opacity(state.color == color ? 0.9 : 0.25),
                                                     lineWidth: state.color == color ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { Color(nsColor: state.color) },
                                                   set: { state.color = NSColor($0) }))
                    .labelsHidden()
                    .frame(width: 28)
            }

            Picker("", selection: Binding(get: { state.lineWidth / state.scale },
                                          set: { state.lineWidth = $0 * state.scale })) {
                ForEach(widths, id: \.self) { w in Text(widthLabels[w] ?? "").tag(w) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)

            Spacer(minLength: 8)

            if state.tool == .crop, state.cropRect != nil {
                Button("Apply Crop") { perform(.applyCrop) }
                    .keyboardShortcut(.defaultAction)
            }

            iconButton("arrow.uturn.backward", "Undo (⌘Z)", disabled: !state.canUndo) { perform(.undo) }
            iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", disabled: !state.canRedo) { perform(.redo) }
            iconButton("trash", "Remove all annotations", disabled: state.annotations.isEmpty) { perform(.clear) }

            Divider().frame(height: 24)

            iconButton("pin", "Pin to screen") { perform(.pin) }
            iconButton("square.and.arrow.up", "Share") { perform(.share) }
            iconButton("doc.on.doc", "Copy (⌘C)") { perform(.copy) }
            iconButton("square.and.arrow.down", "Save (⌘S)") { perform(.save) }
            Button("Done") { perform(.done) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
    }
}
