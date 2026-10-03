import AppKit
import CoreImage

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, filledRectangle, ellipse, pen, highlighter, text, counter
    case pixelate, blur, spotlight, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop.fill"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcuts while the canvas has focus.
    var shortcut: Character? {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .filledRectangle: return "f"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "x"
        case .blur: return "b"
        case .spotlight: return "s"
        case .crop: return "c"
        }
    }

    var isFreehand: Bool { self == .pen || self == .highlighter }
}

/// A single mark on the image. All geometry is in image pixel coordinates with a top-left origin.
struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 24
    var number: Int = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    var counterRadius: CGFloat { lineWidth * 2.5 + 10 }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = fontSize * 0.08
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    /// Bounding box used for hit-testing and selection handles.
    var bounds: CGRect {
        switch tool {
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        case .text:
            let size = (text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: start, size: size)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .arrow, .line:
            return rect.insetBy(dx: -lineWidth * 2 - 6, dy: -lineWidth * 2 - 6)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let tolerance = max(8, lineWidth * 2)
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= tolerance
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= tolerance }
        case .rectangle, .ellipse:
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Draws a base image plus annotations into a flipped (top-left origin) graphics context.
struct AnnotationRenderer {
    let base: CGImage
    let pixelated: CGImage?
    let blurred: CGImage?

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    static func makeEffects(for image: CGImage, scale: CGFloat) -> (pixelated: CGImage?, blurred: CGImage?) {
        let ci = CIImage(cgImage: image)
        let context = CIContext()
        var pixelated: CGImage?
        if let filter = CIFilter(name: "CIPixellate") {
            filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(max(10, 10 * scale), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            if let output = filter.outputImage?.cropped(to: ci.extent) {
                pixelated = context.createCGImage(output, from: ci.extent)
            }
        }
        var blurred: CGImage?
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(12 * scale, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage?.cropped(to: ci.extent) {
                blurred = context.createCGImage(output, from: ci.extent)
            }
        }
        return (pixelated, blurred)
    }

    /// `ctx` must be flipped so that y grows downward, in image pixel units.
    func draw(_ annotations: [Annotation], in ctx: CGContext) {
        drawImage(base, in: imageRect, ctx: ctx)

        // Redactions first, then spotlight dimming, then marks on top.
        for a in annotations where a.tool == .pixelate || a.tool == .blur {
            guard let source = a.tool == .pixelate ? pixelated : blurred else { continue }
            ctx.saveGState()
            ctx.clip(to: a.rect)
            drawImage(source, in: imageRect, ctx: ctx)
            ctx.restoreGState()
        }

        let spotlights = annotations.filter { $0.tool == .spotlight }
        if !spotlights.isEmpty {
            ctx.saveGState()
            let path = CGMutablePath()
            path.addRect(imageRect)
            for s in spotlights { path.addPath(Self.roundedRect(s.rect, radius: 8)) }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for a in annotations { drawMark(a, in: ctx) }
    }

    func drawMark(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)

        switch a.tool {
        case .arrow:
            drawArrow(from: a.start, to: a.end, width: a.lineWidth, color: a.color, ctx: ctx)
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rectangle:
            ctx.addPath(Self.roundedRect(a.rect, radius: a.lineWidth))
            ctx.strokePath()
        case .filledRectangle:
            ctx.addPath(Self.roundedRect(a.rect, radius: a.lineWidth))
            ctx.fillPath()
        case .ellipse:
            ctx.strokeEllipse(in: a.rect)
        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            if a.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(a.lineWidth * 4)
                ctx.setLineCap(.square)
            }
            ctx.move(to: first)
            for p in a.points.dropFirst() { ctx.addLine(to: p) }
            if a.points.count == 1 { ctx.addLine(to: first) }
            ctx.strokePath()
        case .text:
            guard !a.text.isEmpty else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (a.text as NSString).draw(at: a.start, withAttributes: a.textAttributes)
            NSGraphicsContext.restoreGraphicsState()
        case .counter:
            let r = a.counterRadius
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            ctx.setShadow(offset: .zero, blur: r * 0.3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ]
            let s = "\(a.number)" as NSString
            let size = s.size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            s.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate, .blur, .spotlight, .crop, .select:
            break
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor, ctx: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(max(width * 4.5, 18), length * 0.6)
        let headWidth = headLength * 0.85
        let base = CGPoint(x: end.x - cos(angle) * headLength * 0.8, y: end.y - sin(angle) * headLength * 0.8)

        ctx.setShadow(offset: .zero, blur: width, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.strokePath()

        let back = CGPoint(x: end.x - cos(angle) * headLength, y: end.y - sin(angle) * headLength)
        let left = CGPoint(x: back.x + cos(angle + .pi / 2) * headWidth / 2, y: back.y + sin(angle + .pi / 2) * headWidth / 2)
        let right = CGPoint(x: back.x + cos(angle - .pi / 2) * headWidth / 2, y: back.y + sin(angle - .pi / 2) * headWidth / 2)
        ctx.move(to: end)
        ctx.addLine(to: left)
        ctx.addLine(to: base)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    /// Rounded-rect path that never violates CoreGraphics' radius <= half-side requirement.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Draws a CGImage upright inside a flipped context.
    private func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.origin.y + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: rect.origin.x, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// Flattens everything to a new bitmap of the same pixel size.
    func flatten(_ annotations: [Annotation]) -> CGImage? {
        let colorSpace = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, in: ctx)
        return ctx.makeImage()
    }
}

extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.7
    }
}
