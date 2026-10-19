import Foundation

public enum Pause: Equatable, Sendable, Codable {
    case until(Date)
    /// Clears on com.apple.screenIsUnlocked.
    case untilUnlock

    /// "Until tomorrow" ends at this hour of the next morning.
    public static let morningHour = 6

    public static func minutes(_ m: Double, from now: Date) -> Pause { .until(now.addingTimeInterval(m * 60)) }

    /// The next 6:00 AM: tomorrow morning when chosen during the day, this morning when chosen after midnight.
    public static func untilTomorrow(from now: Date, calendar: Calendar = .current) -> Pause {
        let next = calendar.nextDate(after: now, matching: DateComponents(hour: morningHour, minute: 0, second: 0),
                                     matchingPolicy: .nextTime)
        return .until(next ?? now.addingTimeInterval(86_400))
    }

    public func isExpired(at now: Date) -> Bool {
        if case let .until(end) = self { return now >= end }
        return false
    }

    /// A pause read back at launch; nil when it has already ended. "Until I unlock" only survives
    /// a relaunch while the screen is locked: launched at login or after a reboot, the unlock it
    /// waited for has already happened and FaceLock never saw it.
    public static func restored(_ p: Pause?, now: Date, screenLocked: Bool) -> Pause? {
        guard let p, !p.isExpired(at: now) else { return nil }
        if p == .untilUnlock, !screenLocked { return nil }
        return p
    }
}

public enum Suppression: String, Codable, Sendable, CaseIterable {
    case screenLocked, displayAsleep, systemAsleep, cameraUnavailable
    /// Enrollment, Teach, Check with someone else or Measure camera timing has the camera.
    case setup
}

public enum NotProtectingReason: String, Codable, Sendable {
    case cameraAccessOff, noCamera, noEnrollment, needsReenroll, modelsMissing
    /// The keychain refused to hand over the enrollment key for now; FaceLock retries at the next unlock.
    case keyUnavailable
    /// The models and camera are still loading; no check may start yet.
    case starting

    public var text: String {
        switch self {
        case .cameraAccessOff: return "camera access is off"
        case .noCamera: return "no camera found"
        case .noEnrollment: return "FaceLock doesn't know your face yet"
        case .needsReenroll: return "your saved face can't be read, set it up again"
        case .modelsMissing: return "the face model isn't downloaded yet"
        case .keyUnavailable: return "FaceLock can't read its key from the keychain yet"
        case .starting: return "starting up"
        }
    }
}

public enum CountdownReason: String, Codable, Sendable {
    /// "Locking in 10 s. Look at the camera to stay unlocked."
    case away
    /// "Turn your head" after a still-face flag.
    case headTurn
    /// The one more look after input or an unknown face stopped the countdown.
    case checking
}

public enum Notice: Equatable, Sendable {
    case someoneElseInView
    case lockFailed(LockOutcome)
    case stillFaceFlagged(observeOnly: Bool)

    /// Posted even with notifications turned off in Settings.
    public var isCritical: Bool {
        if case .lockFailed = self { return true }
        return false
    }
}

public enum Phase: Equatable, Sendable {
    case present
    case checking(CheckKind)
    case looking
    case stranger
    case countdown
    case confirming(CancelCause)
    case challenge
    case locking
}

/// The menu bar's state list. Paused and Not protecting override the phase.
public enum WatchState: String, Sendable {
    case present, checking, looking, countdown, stranger, paused, notProtecting, suspended
}

public struct ActiveWindow: Equatable, Sendable {
    public let id: Int
    public let kind: CheckKind
}

public struct WatcherState: Equatable, Sendable {
    public var phase: Phase = .present
    public var misses = 0
    public var suppressions: Set<Suppression> = []
    public var pause: Pause?
    public var blocked: NotProtectingReason?
    public var activeWindow: ActiveWindow?
    public var lastWindowID = 0
    public var nextCheckAt: Date?
    public var countdownEndsAt: Date?
    public var lastOwnerSeen: Date?
    public var secondFaceWindows = 0
    public var someoneElseInView = false
    public var strangerOrUnclearSinceUnlock = false
    public var stillFace = StillFaceDetector()
    public var settings: WatcherSettings
    public var onBattery = false
    /// Windows in a row that got no usable frame. Reset by the next window that does.
    public var cameraFailures = 0
    /// The last lock attempt did not lock; cleared when the owner is seen or a lock takes.
    public var lockFailed = false
    /// The countdown panel shows "Checking for you" during the confirm check.
    public var checkingShown = false

    /// From this many camera failures in a row the menu says FaceLock is not protecting.
    public static let cameraFailureLimit = 2

    public init(settings: WatcherSettings = WatcherSettings()) {
        self.settings = settings
    }

    public var cadence: Cadence { settings.effectiveCadence(onBattery: onBattery) }
    public var isActive: Bool { pause == nil && blocked == nil && suppressions.isEmpty }
    public var checksLeft: Int { max(0, cadence.confirmChecks - misses) }
    public var cameraNotResponding: Bool { cameraFailures >= Self.cameraFailureLimit }

    public var watchState: WatchState {
        if blocked != nil { return .notProtecting }
        if pause != nil { return .paused }
        if !suppressions.isEmpty { return .suspended }
        if cameraNotResponding { return .notProtecting }
        switch phase {
        case .present: return .present
        case .checking: return misses > 0 ? .looking : .checking
        case .looking: return .looking
        case .stranger: return .stranger
        case .countdown, .confirming, .challenge, .locking: return .countdown
        }
    }
}
