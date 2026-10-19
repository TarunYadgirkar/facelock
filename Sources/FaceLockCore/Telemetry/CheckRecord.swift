import Foundation

public enum CancelCause: String, Codable, Sendable {
    /// The owner's face cancelled the countdown.
    case owner
    /// Mouse, keyboard or "I'm here".
    case input
    /// Some face, not yet known to be the owner.
    case face
}

public enum LockOutcome: String, Codable, Sendable {
    case locked
    /// The lock call did not take; the display slept instead (locks only with "require password immediately").
    case displaySleptOnly = "display_slept_only"
    case failed
    /// `--dry-run` and demos: logged instead of locking.
    case dryRun = "dry_run"

    /// The Mac should have locked and did not.
    public var isFailure: Bool { self == .failed || self == .displaySleptOnly }
}

/// One line of ~/Library/Logs/FaceLock/checks.jsonl. No images, no embeddings.
public struct CheckRecord: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case check, cancel, lock, stillFace = "still_face", someoneElse = "someone_else"
    }

    public var at: Date
    public var event: Event
    public var kind: CheckKind?
    public var onTime: Double?
    public var firstFrame: Double?
    public var settled: Double?
    public var frames: Int?
    public var faceCount: Int?
    public var bestScore: Float?
    public var anchorScore: Float?
    public var quality: [String]?
    public var verdict: WindowVerdict?
    public var cancel: CancelCause?
    public var outcome: LockOutcome?
    public var note: String?
    /// The camera's frame size, so a stream that isn't 640x480 shows up in the log.
    public var frameSize: String?
    public var failedFrames: Int?

    public init(at: Date, event: Event, kind: CheckKind? = nil) {
        self.at = at
        self.event = event
        self.kind = kind
    }

    public static func check(_ s: WindowSummary, kind: CheckKind, at: Date) -> CheckRecord {
        var r = CheckRecord(at: at, event: .check, kind: kind)
        r.onTime = s.timing.cameraOn
        r.firstFrame = s.timing.firstFrame
        r.settled = s.timing.settled
        r.frames = s.frames
        r.faceCount = s.maxFaceCount
        r.bestScore = s.bestScore
        r.anchorScore = s.bestAnchorScore
        r.quality = s.qualityFlags.names
        r.verdict = s.verdict
        r.frameSize = s.frameSize?.text
        r.failedFrames = s.failedFrames > 0 ? s.failedFrames : nil
        return r
    }

    public static func cancel(_ cause: CancelCause, at: Date) -> CheckRecord {
        var r = CheckRecord(at: at, event: .cancel, kind: .countdown)
        r.cancel = cause
        return r
    }

    public static func lock(_ outcome: LockOutcome, at: Date, note: String? = nil) -> CheckRecord {
        var r = CheckRecord(at: at, event: .lock)
        r.outcome = outcome
        r.note = note
        return r
    }
}
