// Renders the Snippy app icon into an .iconset folder. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let s = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background with a violet → blue gradient.
    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.47, green: 0.29, blue: 0.98, alpha: 1),
                        NSColor(red: 0.16, green: 0.55, blue: 0.99, alpha: 1)])?.draw(in: path, angle: -60)

    // Viewfinder corners.
    let frame = body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)
    let len = frame.width * 0.28
    let corners = NSBezierPath()
    corners.lineWidth = s * 0.055
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        corners.move(to: CGPoint(x: x, y: y + dy * len))
        corners.line(to: CGPoint(x: x, y: y))
        corners.line(to: CGPoint(x: x + dx * len, y: y))
    }
    NSColor.white.setStroke()
    corners.stroke()

    // Scissor-ish "snip" dot in the centre.
    let r = frame.width * 0.14
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: frame.midX - r, y: frame.midY - r, width: r * 2, height: r * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale)?.write(to: out.appendingPathComponent(name))
    }
}
print("Wrote \(out.path)")
