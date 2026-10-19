import FaceLockCore
import SwiftUI

/// Onboarding's face capture: the mirrored preview with live quality chips, and the pose map,
/// nine rings placed where your head goes.
struct EnrollmentView: View {
    @Bindable var enrollment: EnrollmentModel

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                CameraWell(session: enrollment.cameraSession, image: enrollment.preview) {
                    VStack {
                        Spacer()
                        Text(enrollment.hint)
                            .font(Typeface.bodyEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Space.m)
                            .padding(.vertical, Space.s)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, Space.l)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .frame(width: 400)
                HStack(spacing: Space.s) {
                    QualityChip(title: "Distance", passes: enrollment.chips.distance)
                    QualityChip(title: "Light", passes: enrollment.chips.light)
                    QualityChip(title: "Sharp", passes: enrollment.chips.sharp)
                    QualityChip(title: "Facing camera", passes: enrollment.chips.facing)
                }
            }
            VStack(alignment: .leading, spacing: Space.l) {
                PoseMap(session: enrollment.session)
                Text("\(enrollment.acceptedCount) of \(EnrollmentTarget.allCases.count * EnrollmentSession.framesPerTarget) views")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if enrollment.currentTarget?.isSkippable == true {
                    Button("Skip, I don't wear glasses") { enrollment.skipCurrent() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(width: 196, alignment: .leading)
        }
    }
}

/// The nine targets on a 3x3 grid, mirrored like the preview: turning to your left fills the
/// ring on the left.
struct PoseMap: View {
    let session: EnrollmentSession

    static let layout: [[EnrollmentTarget]] = [
        [.closer, .up, .farther],
        [.left, .centre, .right],
        [.leaningBack, .down, .glasses],
    ]

    var body: some View {
        Grid(horizontalSpacing: Space.m, verticalSpacing: Space.m) {
            ForEach(Self.layout, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { target in
                        PoseCell(target: target, progress: session.progress(target), isCurrent: session.currentTarget == target,
                                 isSkipped: session.skipped.contains(target))
                    }
                }
            }
        }
    }
}

private struct PoseCell: View {
    let target: EnrollmentTarget
    let progress: Double
    let isCurrent: Bool
    let isSkipped: Bool

    var body: some View {
        VStack(spacing: Space.xs + 2) {
            ZStack {
                if isCurrent { Circle().fill(Theme.accent.opacity(0.12)) }
                ProgressRing(progress: progress, lineWidth: isCurrent ? 4 : 3, tint: progress >= 1 ? Theme.good : Theme.accent)
                Image(systemName: progress >= 1 ? "checkmark" : symbol)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(progress >= 1 ? Theme.good : isCurrent ? Theme.accent : .secondary)
            }
            .frame(width: 48, height: 48)
            Text(label)
                .font(Typeface.caption.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .frame(width: 56)
        .opacity(isSkipped ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(isSkipped ? "skipped" : "\(Int(progress * 100)) percent")\(isCurrent ? ", now" : "")")
    }

    private var label: String {
        switch target {
        case .centre: return "Centre"
        case .left: return "Left"
        case .right: return "Right"
        case .up: return "Up"
        case .down: return "Down"
        case .closer: return "Closer"
        case .farther: return "Back"
        case .leaningBack: return "Reading"
        case .glasses: return "Glasses"
        }
    }

    private var symbol: String {
        switch target {
        case .centre: return "viewfinder"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .closer: return "arrow.up.left.and.arrow.down.right"
        case .farther: return "arrow.down.right.and.arrow.up.left"
        case .leaningBack: return "book"
        case .glasses: return "eyeglasses"
        }
    }
}
