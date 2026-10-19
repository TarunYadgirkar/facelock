import FaceLockCore
import SwiftUI

/// The pre-lock warning: a draining ring around the seconds left, what stops it, and "I'm here".
struct CountdownCard: View {
    let endsAt: Date
    let total: TimeInterval
    let reason: CountdownReason
    var onHere: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: false)) { context in
            let left = max(0, endsAt.timeIntervalSince(context.date))
            HStack(alignment: .center, spacing: Space.l + 4) {
                dial(left: left)
                VStack(alignment: .leading, spacing: Space.xs + 2) {
                    Text(CountdownCopy.title(reason, secondsLeft: Int(left.rounded(.up))))
                        .font(Typeface.title)
                        .monospacedDigit()
                    Text(CountdownCopy.detail(reason))
                        .font(Typeface.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if reason == .away {
                        Button("I'm here", action: onHere)
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            .padding(.top, Space.xs)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
            .padding(Space.xl)
            .background {
                RoundedRectangle(cornerRadius: Radius.well)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func dial(left: TimeInterval) -> some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 5)
            Circle()
                .trim(from: 0, to: total > 0 ? left / total : 0)
                .stroke(Theme.critical, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(left.rounded(.up)))")
                .font(Typeface.countdown)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 104, height: 104)
        .accessibilityHidden(true)
    }
}
