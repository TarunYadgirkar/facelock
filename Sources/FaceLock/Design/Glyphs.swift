import AppKit
import FaceLockCore

/// Monochrome template glyphs for the menu bar. The state is in the shape: a filled centre for
/// Watching, a dot for Checking, an outline with notches for Looking, a draining ring for the
/// countdown, two dots for someone else, bars for Paused and a slash for Not protecting.
enum Glyphs {
    static let size = NSSize(width: 18, height: 18)
    private static let stroke: CGFloat = 1.6
    private static let frame = NSRect(x: 2, y: 2, width: 14, height: 14)
    private static let arm: CGFloat = 4.5
    private static let slashInset: CGFloat = 3.5

    @MainActor private static var cache: [String: NSImage] = [:]

    /// `remaining` is the countdown fraction left (1 to 0); other glyphs ignore it. The ring is
    /// drawn in 5% steps, so every image is built once and reused.
    @MainActor static func image(_ glyph: MenuGlyph, remaining: Double = 1) -> NSImage {
        let step = glyph == .countdown ? (max(0, min(1, remaining)) * 20).rounded(.up) / 20 : 1
        let key = "\(glyph)|\(step)"
        if let hit = cache[key] { return hit }
        let img = render(glyph, remaining: step)
        cache[key] = img
        return img
    }

    private static func render(_ glyph: MenuGlyph, remaining: Double) -> NSImage {
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(glyph, remaining: remaining)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = description(glyph)
        return img
    }

    static func description(_ glyph: MenuGlyph) -> String {
        switch glyph {
        case .watching: return "FaceLock: watching"
        case .checking: return "FaceLock: checking"
        case let .lookingForYou(n): return "FaceLock: looking for you, \(n) check\(n == 1 ? "" : "s") left"
        case .countdown: return "FaceLock: locking soon"
        case .someoneElse: return "FaceLock: someone else is in view"
        case .paused: return "FaceLock: paused"
        case .notProtecting: return "FaceLock: not protecting"
        }
    }

    private static func draw(_ glyph: MenuGlyph, remaining: Double) {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        switch glyph {
        case .watching:
            corners()
            dot(centre, radius: 3.2)
        case .checking:
            corners(skipTopRight: true)
            dot(centre, radius: 3.2)
            dot(NSPoint(x: frame.maxX - 1.5, y: frame.maxY - 1.5), radius: 2)
        case let .lookingForYou(n):
            corners()
            ring(centre, radius: 3, fraction: 1)
            notches(max(0, min(3, n)))
        case .countdown:
            corners()
            ring(centre, radius: 4, fraction: max(0, min(1, remaining)))
        case .someoneElse:
            corners(skipTopRight: true)
            dot(centre, radius: 3.2)
            dot(NSPoint(x: frame.maxX - 3.4, y: frame.maxY - 1.5), radius: 1.5)
            dot(NSPoint(x: frame.maxX - 0.2, y: frame.maxY - 1.5), radius: 1.5)
        case .paused:
            NSGraphicsContext.current?.cgContext.setAlpha(0.5)
            corners()
            bar(x: centre.x - 2.2)
            bar(x: centre.x + 2.2)
        case .notProtecting:
            // Top left to bottom right, stopping short of the corners, so it reads as "off" and
            // never as the corner arrows of "enter full screen".
            corners()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: frame.minX + slashInset, y: frame.maxY - slashInset))
            p.line(to: NSPoint(x: frame.maxX - slashInset, y: frame.minY + slashInset))
            p.lineWidth = stroke
            p.lineCapStyle = .round
            p.stroke()
        }
    }

    private static func corners(skipTopRight: Bool = false) {
        let f = frame
        let all: [(NSPoint, CGFloat, CGFloat, Bool)] = [
            (NSPoint(x: f.minX, y: f.minY), 1, 1, true), (NSPoint(x: f.maxX, y: f.minY), -1, 1, true),
            (NSPoint(x: f.minX, y: f.maxY), 1, -1, true), (NSPoint(x: f.maxX, y: f.maxY), -1, -1, !skipTopRight),
        ]
        for (corner, dx, dy, show) in all where show {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
            p.line(to: corner)
            p.line(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
            p.lineWidth = stroke
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
    }

    private static func dot(_ c: NSPoint, radius r: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }

    private static func ring(_ c: NSPoint, radius r: CGFloat, fraction: Double) {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        p.lineWidth = stroke
        p.lineCapStyle = .round
        p.stroke()
    }

    private static func notches(_ n: Int) {
        let spacing: CGFloat = 3
        let start = frame.midX - spacing * CGFloat(n - 1) / 2
        for i in 0..<n {
            dot(NSPoint(x: start + spacing * CGFloat(i), y: frame.minY + 2.2), radius: 0.9)
        }
    }

    private static func bar(x: CGFloat) {
        NSBezierPath(roundedRect: NSRect(x: x - 0.9, y: frame.midY - 3.5, width: 1.8, height: 7), xRadius: 0.9, yRadius: 0.9).fill()
    }
}
