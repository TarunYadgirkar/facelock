import Foundation

/// Semantic tone for the menu's status pill; separate from the accent colour.
public enum StatusTone: String, Sendable {
    case good, warning, critical, neutral
}

/// Menu bar glyph states. Shape carries the state; the template image stays monochrome.
public enum MenuGlyph: Equatable, Sendable {
    case watching
    case checking
    case lookingForYou(checksLeft: Int)
    case countdown
    case someoneElse
    case paused
    case notProtecting
}

public enum StatusFix: String, Sendable {
    case openCameraSettings, startEnrollment, reenroll
}

public struct StatusLine: Equatable, Sendable {
    public let tone: StatusTone
    public let text: String
    public let glyph: MenuGlyph
    public let fix: StatusFix?
}

extension WatcherState {
    public func status(now: Date) -> StatusLine {
        if let reason = blocked {
            let fix: StatusFix? = switch reason {
            case .cameraAccessOff: .openCameraSettings
            case .noEnrollment: .startEnrollment
            case .needsReenroll: .reenroll
            case .noCamera, .modelsMissing: nil
            }
            return StatusLine(tone: .critical, text: "Not protecting: \(reason.text)", glyph: .notProtecting, fix: fix)
        }
        if let p = pause {
            let text: String = switch p {
            case let .until(end): "Paused until \(end.formatted(date: .omitted, time: .shortened))"
            case .untilUnlock: "Paused until you unlock"
            }
            return StatusLine(tone: .neutral, text: text, glyph: .paused, fix: nil)
        }
        if suppressions.contains(.setup) {
            return StatusLine(tone: .neutral, text: "Paused while setup uses the camera", glyph: .paused, fix: nil)
        }
        if suppressions.contains(.cameraUnavailable) {
            return StatusLine(tone: .warning, text: "Waiting for the camera", glyph: .notProtecting, fix: nil)
        }
        if !suppressions.isEmpty {
            return StatusLine(tone: .neutral, text: "Resting while the screen is off or locked", glyph: .paused, fix: nil)
        }
        return activeStatus(now: now)
    }

    private func activeStatus(now: Date) -> StatusLine {
        switch watchState {
        case .countdown:
            let left = max(0, Int((countdownEndsAt ?? now).timeIntervalSince(now).rounded(.up)))
            let text = phase == .challenge ? "Turn your head to stay unlocked" : "Locking in \(left) s"
            return StatusLine(tone: .critical, text: text, glyph: .countdown, fix: nil)
        case .looking, .stranger:
            let n = checksLeft
            let lead = watchState == .stranger ? "Someone else is at the camera" : "Looking for you"
            return StatusLine(tone: .warning, text: "\(lead). \(n) check\(n == 1 ? "" : "s") left",
                              glyph: .lookingForYou(checksLeft: n), fix: nil)
        default:
            if someoneElseInView {
                return StatusLine(tone: .warning, text: "Someone else is in view", glyph: .someoneElse, fix: nil)
            }
            let seen = lastOwnerSeen.map { " You were here \(Int(now.timeIntervalSince($0).rounded())) s ago" } ?? ""
            let glyph: MenuGlyph = watchState == .checking ? .checking : .watching
            return StatusLine(tone: .good, text: "Watching.\(seen)", glyph: glyph, fix: nil)
        }
    }
}
