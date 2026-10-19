import FaceLockCore
import Foundation

/// The menu header's wording: a short pill label, a headline and a detail line, split from the
/// engine's one-sentence status.
struct StatusText: Equatable {
    let pill: String
    let headline: String
    let detail: String?

    static func make(_ state: WatcherState, line: StatusLine, now: Date) -> StatusText {
        let (head, rest) = split(line.text)
        var detail = rest
        if state.watchState == .present || state.watchState == .checking, let next = state.nextCheckAt {
            let secs = max(0, Int(next.timeIntervalSince(now).rounded()))
            let tail = "Next check in \(secs) s."
            detail = detail.map { "\($0). \(tail)" } ?? tail
        }
        return StatusText(pill: pill(state.watchState), headline: head, detail: detail)
    }

    /// "Watching. You were here 12 s ago" and "Not protecting: camera access is off" each
    /// become a headline and a detail.
    static func split(_ text: String) -> (String, String?) {
        for separator in [": ", ". "] {
            if let r = text.range(of: separator) {
                let rest = String(text[r.upperBound...])
                return (String(text[..<r.lowerBound]), rest.prefix(1).uppercased() + rest.dropFirst())
            }
        }
        return (text, nil)
    }

    static func pill(_ s: WatchState) -> String {
        switch s {
        case .present: return "Watching"
        case .checking: return "Checking"
        case .looking: return "Looking"
        case .stranger: return "Not you"
        case .countdown: return "Locking"
        case .paused: return "Paused"
        case .notProtecting: return "Off"
        case .suspended: return "Resting"
        }
    }

    static func fixTitle(_ fix: StatusFix) -> String {
        switch fix {
        case .openCameraSettings: return "Turn On Camera Access"
        case .startEnrollment: return "Set Up FaceLock"
        case .reenroll: return "Set Up Again"
        case .downloadModel: return "Download the Face Model…"
        }
    }
}
