import AppKit
import AVFoundation
import SwiftUI

enum QuickAccessContent {
    case image(Capture, URL?, saved: Bool)
    case media(URL, HistoryItem.Kind)
}

@MainActor
final class QuickAccessItem: ObservableObject, Identifiable {
    let id = UUID()
    let content: QuickAccessContent
    @Published var thumbnail: NSImage?
    @Published var fileURL: URL?
    @Published var isSaved: Bool

    var isImage: Bool { if case .image = content { return true }; return false }
    var capture: Capture? { if case let .image(c, _, _) = content { return c }; return nil }
    var badge: String? {
        if case let .media(_, kind) = content { return kind == .gif ? "GIF" : "VIDEO" }
        return nil
    }

    init(content: QuickAccessContent) {
        self.content = content
        switch content {
        case let .image(capture, url, saved):
            fileURL = url
            isSaved = saved
            thumbnail = capture.image.nsImage(scale: capture.scale)
        case let .media(url, kind):
            fileURL = url
            isSaved = true
            if kind == .gif {
                thumbnail = NSImage(contentsOf: url)
            } else {
                loadVideoThumbnail(url)
            }
        }
    }

    private func loadVideoThumbnail(_ url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        Task {
            if let result = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
                self.thumbnail = NSImage(cgImage: result.image, size: .zero)
            }
        }
    }
}

/// Floating thumbnails in the screen corner after each capture, like CleanShot's Quick Access Overlay.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private struct Entry {
        let item: QuickAccessItem
        let panel: NSPanel
        var timer: Timer?
    }

    private var entries: [Entry] = []
    private let size = CGSize(width: 260, height: 176)

    func show(_ content: QuickAccessContent) {
        let item = QuickAccessItem(content: content)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.excludeFromCapture()

        let view = QuickAccessView(item: item,
                                   onHover: { [weak self] hovering in self?.setHovering(item, hovering) },
                                   perform: { [weak self] action in self?.perform(action, on: item) },
                                   drag: { [weak self] phase in self?.handleDrag(phase) })
        panel.contentView = FirstMouseHostingView(rootView: view)
        entries.insert(Entry(item: item, panel: panel, timer: nil), at: 0)
        layout(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        layout(animated: true)
        scheduleClose(item)
        // Keep the stack manageable.
        while entries.count > 5, let last = entries.last { close(last.item) }
    }

    enum Action { case copy, save, edit, pin, open, close }

    private func perform(_ action: Action, on item: QuickAccessItem) {
        switch action {
        case .copy:
            if let capture = item.capture {
                Clipboard.copy(image: capture.image, scale: capture.scale)
            } else if let url = item.fileURL {
                Clipboard.copy(fileURL: url)
            }
            HUD.show("Copied to clipboard")
            close(item)
        case .save:
            if item.isSaved, let url = item.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if let capture = item.capture,
                      let url = OutputManager.saveToFolder(capture, existing: item.fileURL) {
                item.fileURL = url
                item.isSaved = true
                HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "folder.fill")
            }
        case .edit:
            if let capture = item.capture {
                EditorWindowController.open(capture: capture, fileURL: item.fileURL)
                close(item)
            }
        case .pin:
            if let capture = item.capture {
                PinnedImageWindow.pin(capture)
                close(item)
            }
        case .open:
            if let url = item.fileURL { NSWorkspace.shared.open(url) }
            close(item)
        case .close:
            close(item)
        }
    }

    private func setHovering(_ item: QuickAccessItem, _ hovering: Bool) {
        guard let index = entries.firstIndex(where: { $0.item === item }) else { return }
        if hovering {
            entries[index].timer?.invalidate()
            entries[index].timer = nil
        } else {
            scheduleClose(item)
        }
    }

    private func scheduleClose(_ item: QuickAccessItem) {
        let delay = Preferences.quickAccessAutoClose
        guard delay > 0, !isDragging, let index = entries.firstIndex(where: { $0.item === item }) else { return }
        entries[index].timer?.invalidate()
        entries[index].timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close(item) }
        }
    }

    func close(_ item: QuickAccessItem) {
        guard let index = entries.firstIndex(where: { $0.item === item }) else { return }
        let entry = entries.remove(at: index)
        entry.timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            entry.panel.animator().alphaValue = 0
        }, completionHandler: {
            entry.panel.orderOut(nil)
        })
        layout(animated: true)
    }

    // MARK: Positioning

    private var isDragging = false
    private var grabOffset: CGFloat = 0

    /// The screen the stack lives on (remembered across launches, falls back to the main screen).
    private var screen: NSScreen {
        Preferences.quickAccessDisplay.flatMap { NSScreen.screen(withDisplayID: $0) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var stackHeight: CGFloat {
        CGFloat(max(entries.count, 1)) * (size.height - 8) + 8
    }

    /// Bottom y of the stack, clamped so the whole stack stays on screen.
    private func baseY(on screen: NSScreen) -> CGFloat {
        let visible = screen.visibleFrame
        let travel = max(0, visible.height - stackHeight)
        return visible.minY + travel * CGFloat(Preferences.quickAccessOffset)
    }

    enum DragPhase { case began(CGPoint), moved(CGPoint), ended }

    /// Dragging the grip slides the stack along the left or right screen edge.
    func handleDrag(_ phase: DragPhase) {
        switch phase {
        case let .began(point):
            isDragging = true
            for i in entries.indices { entries[i].timer?.invalidate(); entries[i].timer = nil }
            grabOffset = point.y - baseY(on: screen)
        case let .moved(point):
            guard isDragging else { return }
            let target = NSScreen.screens.first { $0.frame.contains(point) } ?? screen
            Preferences.quickAccessDisplay = target.displayID
            Preferences.quickAccessEdge = point.x < target.frame.midX ? .left : .right
            let visible = target.visibleFrame
            let travel = max(1, visible.height - stackHeight)
            Preferences.quickAccessOffset = Double((point.y - grabOffset - visible.minY) / travel)
            layout(animated: false, followingX: point.x)
        case .ended:
            guard isDragging else { return }
            isDragging = false
            layout(animated: true)
            for entry in entries { scheduleClose(entry.item) }
        }
    }

    func resetPosition() {
        Preferences.resetQuickAccessPosition()
        layout(animated: true)
    }

    /// `followingX`: while dragging, the stack follows the pointer horizontally; on release it snaps to the edge.
    private func layout(animated: Bool, followingX: CGFloat? = nil) {
        let screen = screen
        let visible = screen.visibleFrame
        let base = baseY(on: screen)
        let x: CGFloat
        if let followingX {
            x = max(visible.minX, min(visible.maxX - size.width, followingX - size.width / 2))
        } else {
            x = Preferences.quickAccessEdge == .left ? visible.minX + 8 : visible.maxX - size.width - 8
        }
        for (i, entry) in entries.enumerated() {
            let frame = CGRect(x: x, y: base + CGFloat(i) * (size.height - 8), width: size.width, height: size.height)
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    entry.panel.animator().setFrame(frame, display: true)
                }
            } else {
                entry.panel.setFrame(frame, display: true)
            }
        }
    }
}

/// A grip that reports global mouse positions so the overlay can be repositioned.
struct DragGrip: NSViewRepresentable {
    var onDrag: (QuickAccessManager.DragPhase) -> Void

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: GripView, context: Context) {
        view.onDrag = onDrag
    }

    final class GripView: NSView {
        var onDrag: ((QuickAccessManager.DragPhase) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.push()
            onDrag?(.began(NSEvent.mouseLocation))
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(.moved(NSEvent.mouseLocation))
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
            onDrag?(.ended)
        }
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct QuickAccessView: View {
    @ObservedObject var item: QuickAccessItem
    var onHover: (Bool) -> Void
    var perform: (QuickAccessManager.Action) -> Void
    var drag: (QuickAccessManager.DragPhase) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }

            if let badge = item.badge, !hovering {
                VStack {
                    Spacer()
                    HStack {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.7)))
                            .foregroundColor(.white)
                        Spacer()
                    }
                }
                .padding(8)
            }

            if hovering {
                Color.black.opacity(0.5)
                VStack(spacing: 8) {
                    pill("Copy") { perform(.copy) }
                    pill(item.isSaved ? "Show in Finder" : "Save") { perform(.save) }
                }
                VStack {
                    HStack {
                        corner("xmark") { perform(.close) }
                        Spacer()
                        if item.isImage { corner("pencil") { perform(.edit) } }
                    }
                    Spacer()
                    HStack {
                        if item.isImage {
                            corner("pin.fill") { perform(.pin) }
                        } else {
                            corner("play.fill") { perform(.open) }
                        }
                        Spacer()
                    }
                }
                .padding(8)
            }
        }
        .overlay(alignment: .top) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(hovering ? 0.95 : 0.55))
                    .frame(width: 36, height: 5)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                DragGrip(onDrag: drag)
            }
            .frame(width: 72, height: 18)
            .help("Drag to move along the screen edge")
        }
        .frame(width: 240, height: 156)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .padding(10)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
            onHover(h)
        }
        .onDrag {
            if let url = item.fileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
            return NSItemProvider()
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    private func corner(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}
