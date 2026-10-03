import AppKit
import Combine

/// Interactive canvas: shows the image fitted to the view and handles all drawing tools.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
    enum Command { case copy, save, saveAs, close, done }

    let state: EditorState
    var onCommand: ((Command) -> Void)?

    private var cancellable: AnyCancellable?
    private var draft: Annotation?
    private var dragOrigin: CGPoint?
    private var movingCheckpointed = false
    private var cropStart: CGPoint?
    private var textField: NSTextField?
    private var textFieldImagePoint: CGPoint = .zero

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        cancellable = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var imagePointSize: CGSize {
        CGSize(width: CGFloat(state.base.width) / state.scale, height: CGFloat(state.base.height) / state.scale)
    }

    /// Where the image sits in the view, aspect-fit and never upscaled beyond 1:1 points.
    private var imageRect: CGRect {
        let padding: CGFloat = 24
        let available = bounds.insetBy(dx: padding, dy: padding)
        let size = imagePointSize
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let fit = min(1, available.width / size.width, available.height / size.height)
        let w = size.width * fit, h = size.height * fit
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h).integral
    }

    /// View points per image pixel.
    private var viewScale: CGFloat { imageRect.width / CGFloat(max(1, state.base.width)) }

    private func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (viewPoint.x - r.minX) / viewScale, y: (viewPoint.y - r.minY) / viewScale)
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + imagePoint.x * viewScale, y: r.minY + imagePoint.y * viewScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black)?.setFill()
        bounds.fill()

        let r = imageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(r)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.clip(to: state.renderer.imageRect)
        var all = state.annotations
        if let draft { all.append(draft) }
        state.renderer.draw(all, in: ctx)

        if let id = state.selectedID, let selected = state.annotations.first(where: { $0.id == id }) {
            let box = selected.bounds.insetBy(dx: -6 / viewScale, dy: -6 / viewScale)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / viewScale)
            ctx.setLineDash(phase: 0, lengths: [5 / viewScale, 4 / viewScale])
            ctx.stroke(box)
        }

        if state.tool == .crop, let crop = state.cropRect {
            let path = CGMutablePath()
            path.addRect(state.renderer.imageRect)
            path.addRect(crop)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 / viewScale)
            ctx.stroke(crop)
        }
        ctx.restoreGState()

        if state.tool == .crop {
            let hint = state.cropRect == nil ? "Drag to choose the crop area" : "Press Return to crop · Esc to cancel"
            drawHint(hint)
        }
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: CGRect(x: origin.x - 10, y: origin.y - 4, width: size.width + 20, height: size.height + 8),
                     xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        commitTextField()

        switch state.tool {
        case .select:
            if let hit = state.annotations.last(where: { $0.hitTest(p) }) {
                if event.clickCount == 2, hit.tool == .text {
                    beginEditingText(hit)
                    return
                }
                state.selectedID = hit.id
                dragOrigin = p
                movingCheckpointed = false
            } else {
                state.selectedID = nil
            }
        case .text:
            beginTextField(at: p, existing: nil)
        case .counter:
            state.add(Annotation(tool: .counter, start: p, end: p, color: state.color,
                                 lineWidth: state.lineWidth, number: state.nextCounterNumber))
        case .crop:
            cropStart = clamp(p)
            state.cropRect = nil
        default:
            // Clicking on an existing mark with a drawing tool selects it for quick edits.
            if event.modifierFlags.contains(.command), let hit = state.annotations.last(where: { $0.hitTest(p) }) {
                state.tool = .select
                state.selectedID = hit.id
                dragOrigin = p
                return
            }
            draft = Annotation(tool: state.tool, start: p, end: p, points: [p], color: state.color,
                               lineWidth: state.lineWidth)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        switch state.tool {
        case .select:
            guard let origin = dragOrigin, let id = state.selectedID,
                  let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
            if !movingCheckpointed { state.checkpoint(); movingCheckpointed = true }
            state.annotations[index].offset(dx: p.x - origin.x, dy: p.y - origin.y)
            dragOrigin = p
        case .crop:
            guard let start = cropStart else { return }
            let q = clamp(p)
            state.cropRect = CGRect(x: min(start.x, q.x), y: min(start.y, q.y),
                                    width: abs(start.x - q.x), height: abs(start.y - q.y))
        default:
            guard var d = draft else { return }
            if d.tool.isFreehand {
                d.points.append(p)
            } else {
                d.end = event.modifierFlags.contains(.shift) ? constrained(from: d.start, to: p, tool: d.tool) : p
            }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        cropStart = nil
        guard let d = draft else { return }
        draft = nil
        let big = d.tool.isFreehand ? d.points.count > 1 : hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 4
        if big { state.add(d) }
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(CGFloat(state.base.width), p.x)), y: max(0, min(CGFloat(state.base.height), p.y)))
    }

    /// Shift: lines snap to 45°, boxes become squares.
    private func constrained(from a: CGPoint, to b: CGPoint, tool: AnnotationTool) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if tool == .arrow || tool == .line {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }

    // MARK: Text

    private func beginEditingText(_ annotation: Annotation) {
        state.checkpoint()
        state.annotations.removeAll { $0.id == annotation.id }
        state.color = annotation.color
        beginTextField(at: annotation.start, existing: annotation)
    }

    private func beginTextField(at p: CGPoint, existing: Annotation?) {
        let fontSize = existing?.fontSize ?? state.defaultFontSize
        let field = NSTextField(string: existing?.text ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize * viewScale, weight: .bold)
        field.textColor = existing?.color ?? state.color
        field.delegate = self
        field.placeholderString = "Text"
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        let origin = viewPoint(p)
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: max(200, bounds.maxX - origin.x - 10),
                             height: fontSize * viewScale * 1.4)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        textFieldImagePoint = p
    }

    private func commitTextField() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        let color = field.textColor ?? state.color
        let fontSize = (field.font?.pointSize ?? 24) / max(viewScale, 0.0001)
        field.removeFromSuperview()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.add(Annotation(tool: .text, start: textFieldImagePoint, end: textFieldImagePoint, color: color,
                             lineWidth: state.lineWidth, text: text, fontSize: fontSize))
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextField()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117: // Delete / forward delete
            state.deleteSelected()
        case 53: // Esc
            if state.cropRect != nil { state.cropRect = nil } else if state.selectedID != nil { state.selectedID = nil } else { onCommand?(.close) }
        case 36, 76: // Return
            if state.tool == .crop, state.cropRect != nil { state.applyCrop() } else { onCommand?(.done) }
        default:
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if flags.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = AnnotationTool.allCases.first(where: { $0.shortcut == ch }) {
                state.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let an active text field handle its own copy/paste/undo.
        if textField != nil { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, flags.contains(.shift)) {
        case ("z", false): state.undo()
        case ("z", true): state.redo()
        case ("c", _): onCommand?(.copy)
        case ("s", false): onCommand?(.save)
        case ("s", true): onCommand?(.saveAs)
        case ("w", _): onCommand?(.close)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
