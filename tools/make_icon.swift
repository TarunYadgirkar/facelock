// Draws Resources/AppIcon.icns: the FaceLock mark (viewfinder corners around a filled centre)
// in white on a mulberry squircle. Run: swift tools/make_icon.swift (from the repo root).
import AppKit

let mulberryTop = NSColor(srgbRed: 0x9C / 255, green: 0x46 / 255, blue: 0x89 / 255, alpha: 1)
let mulberryBottom = NSColor(srgbRed: 0x72 / 255, green: 0x2C / 255, blue: 0x62 / 255, alpha: 1)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Apple's macOS grid: an 824 pt body inset 100 pt, corner radius about 185.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    mulberryBottom.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: mulberryTop, ending: mulberryBottom)!.draw(in: squircle, angle: -90)

    NSColor.white.setStroke()
    NSColor.white.setFill()
    let frame = body.insetBy(dx: 190 * s, dy: 190 * s)
    let arm = 120 * s
    for (cx, cy, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                             (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx + dx * arm, y: cy))
        p.line(to: NSPoint(x: cx, y: cy))
        p.line(to: NSPoint(x: cx, y: cy + dy * arm))
        p.lineWidth = 52 * s
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.stroke()
    }
    let r = 92 * s
    NSBezierPath(ovalIn: NSRect(x: body.midX - r, y: body.midY - r, width: 2 * r, height: 2 * r)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
