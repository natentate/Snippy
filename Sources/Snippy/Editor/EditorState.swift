import AppKit
import Combine

@MainActor
final class EditorState: ObservableObject {
    private struct Snapshot {
        var base: CGImage
        var annotations: [Annotation]
    }

    @Published private(set) var base: CGImage
    @Published var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow { didSet { if tool != .select { selectedID = nil }; cropRect = nil } }
    @Published var color: NSColor = .systemRed {
        didSet { updateSelected { $0.color = color } }
    }
    @Published var lineWidth: CGFloat {
        didSet { updateSelected { $0.lineWidth = lineWidth } }
    }
    @Published var selectedID: UUID?
    @Published var cropRect: CGRect?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let scale: CGFloat
    var fileURL: URL?
    private(set) var renderer: AnnotationRenderer
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(capture: Capture, fileURL: URL?) {
        base = capture.image
        scale = capture.scale
        self.fileURL = fileURL
        lineWidth = 3 * capture.scale
        let effects = AnnotationRenderer.makeEffects(for: capture.image, scale: capture.scale)
        renderer = AnnotationRenderer(base: capture.image, pixelated: effects.pixelated, blurred: effects.blurred)
    }

    var nextCounterNumber: Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    var defaultFontSize: CGFloat { 20 * scale + lineWidth * 1.5 }

    // MARK: Mutations (all undoable)

    func checkpoint() {
        undoStack.append(Snapshot(base: base, annotations: annotations))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func clearAll() {
        guard !annotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll()
        selectedID = nil
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, annotations: annotations))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, annotations: annotations))
        restore(next)
    }

    func applyCrop() {
        guard let rect = cropRect?.integral.intersection(renderer.imageRect),
              rect.width >= 2, rect.height >= 2,
              let cropped = base.cropping(to: rect) else { return }
        checkpoint()
        annotations = annotations.map { var a = $0; a.offset(dx: -rect.minX, dy: -rect.minY); return a }
        setBase(cropped)
        cropRect = nil
        tool = .select
    }

    private func restore(_ snapshot: Snapshot) {
        if snapshot.base !== base { setBase(snapshot.base) }
        annotations = snapshot.annotations
        selectedID = nil
        refreshUndoFlags()
    }

    private func setBase(_ image: CGImage) {
        base = image
        let effects = AnnotationRenderer.makeEffects(for: image, scale: scale)
        renderer = AnnotationRenderer(base: image, pixelated: effects.pixelated, blurred: effects.blurred)
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        change(&annotations[index])
    }

    // MARK: Output

    func flattened() -> Capture {
        Capture(image: renderer.flatten(annotations) ?? base, scale: scale)
    }
}
