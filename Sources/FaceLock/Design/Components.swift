import FaceLockCore
import SwiftUI

/// The state pill: a tinted capsule with a shape that carries the tone without colour.
struct StatusPill: View {
    let tone: StatusTone
    let label: String

    var body: some View {
        HStack(spacing: Space.xs) {
            ToneMark(tone: tone)
            Text(label).font(Typeface.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.tone(tone))
        .padding(.horizontal, Space.s)
        .padding(.vertical, 3)
        .background(Theme.tone(tone).opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Filled for good, half for warning, a bar for critical, open for neutral.
struct ToneMark: View {
    let tone: StatusTone

    var body: some View {
        ZStack {
            switch tone {
            case .good: Circle()
            case .warning: Circle().trim(from: 0, to: 0.5).rotation(.degrees(90)).overlay(Circle().stroke(lineWidth: 1.2))
            case .critical: RoundedRectangle(cornerRadius: 1).frame(width: 7, height: 2.4)
            case .neutral: Circle().stroke(lineWidth: 1.2)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
}

/// A quality chip during enrollment: filled check when it passes, an open ring when it doesn't.
struct QualityChip: View {
    let title: String
    let passes: Bool?

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            Image(systemName: passes == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passes == true ? Theme.good : Theme.neutral)
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(Typeface.caption.weight(.medium)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, 5)
        .background(passes == true ? Theme.good.opacity(0.12) : Theme.surface, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(passes == true ? "good" : passes == false ? "not yet" : "waiting for a face")")
    }
}

/// A progress ring: track plus an accent arc from the top.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

/// Four corner brackets: the FaceLock mark, the preview frame and the menu glyph share it.
struct ViewfinderCorners: Shape {
    var arm: CGFloat = 22

    func path(in r: CGRect) -> Path {
        var p = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX, y: r.minY), 1, 1), (CGPoint(x: r.maxX, y: r.minY), -1, 1),
            (CGPoint(x: r.minX, y: r.maxY), 1, -1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1),
        ]
        for (c, dx, dy) in corners {
            p.move(to: CGPoint(x: c.x + dx * arm, y: c.y))
            p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x, y: c.y + dy * arm))
        }
        return p
    }
}

/// The filled accent button for the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.bodyEmphasis)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Space.l)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: Radius.control))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quiet filled button for secondary actions next to a primary one.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.body)
            .padding(.horizontal, Space.m + 2)
            .padding(.vertical, 7)
            .background(Theme.surface.opacity(configuration.isPressed ? 2 : 1), in: RoundedRectangle(cornerRadius: Radius.control))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A menu-like row in the menu bar panel: full-width hit area, highlight on hover and focus.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Typeface.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background((hovering || configuration.isPressed) && isEnabled ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.inner))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// A grouped surface for related content inside a window.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) { content }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
    }
}
