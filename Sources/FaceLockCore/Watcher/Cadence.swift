import Foundation

public enum CadenceName: String, Codable, Sendable, CaseIterable {
    case relaxed, balanced, strict

    public var title: String { rawValue.capitalized }
}

public struct Cadence: Equatable, Sendable, Codable {
    public let name: CadenceName
    /// Seconds between checks while the owner is here.
    public let interval: TimeInterval
    /// First recheck after a miss; each further miss waits `recheckDecay` of the last.
    public let recheckInterval: TimeInterval
    public let recheckDecay: Double
    /// After a window with at least 2 stranger frames.
    public let strangerInterval: TimeInterval
    /// Consecutive windows without the owner before the countdown.
    public let confirmChecks: Int

    public static let minRecheck: TimeInterval = 2
    /// After a window with no frames: retry quickly once, then back off to one a minute.
    public static let cameraRetryBase: TimeInterval = 2.5
    public static let cameraRetryCap: TimeInterval = 60

    public static let relaxed = Cadence(name: .relaxed, interval: 45, recheckInterval: 15, recheckDecay: 0.5,
                                        strangerInterval: 8, confirmChecks: 3)
    public static let balanced = Cadence(name: .balanced, interval: 30, recheckInterval: 10, recheckDecay: 0.5,
                                         strangerInterval: 5, confirmChecks: 3)
    public static let strict = Cadence(name: .strict, interval: 15, recheckInterval: 6, recheckDecay: 0.5,
                                       strangerInterval: 2, confirmChecks: 2)

    public static func named(_ n: CadenceName) -> Cadence {
        switch n {
        case .relaxed: return .relaxed
        case .balanced: return .balanced
        case .strict: return .strict
        }
    }

    public func recheckDelay(misses: Int) -> TimeInterval {
        max(Self.minRecheck, recheckInterval * pow(recheckDecay, Double(max(0, misses - 1))))
    }

    public func delay(after verdict: WindowVerdict, misses: Int) -> TimeInterval {
        switch verdict {
        case .owner: return interval
        case .stranger: return strangerInterval
        case .unclear, .away: return recheckDelay(misses: misses)
        case .cameraFailed: return Self.cameraRetryDelay(failures: 1)
        }
    }

    public static func cameraRetryDelay(failures: Int) -> TimeInterval {
        min(cameraRetryCap, cameraRetryBase * pow(2, Double(max(0, failures - 1))))
    }

    /// Longest time from leaving to the lock: a full interval, every recheck delay, every window
    /// at its cap, and the countdown.
    public func worstCaseGrace(countdownSeconds: TimeInterval) -> TimeInterval {
        let rechecks = (1..<max(1, confirmChecks)).map { recheckDelay(misses: $0) }.reduce(0, +)
        let windows = WindowPolicy.regular.maxOnTime + Double(confirmChecks - 1) * WindowPolicy.recheck.maxOnTime
        return interval + rechecks + windows + countdownSeconds
    }

    public func graceText(countdownSeconds: TimeInterval) -> String {
        "Locks within \(Int(worstCaseGrace(countdownSeconds: countdownSeconds).rounded())) s after you leave"
    }
}

public struct WatcherSettings: Equatable, Sendable, Codable {
    public static let countdownChoices = [5, 10, 15]

    public var cadence: CadenceName = .balanced
    public var countdownSeconds = 10
    /// "Slower checks on battery" switches to Relaxed.
    public var slowerOnBattery = false
    public var lockWhenSomeoneElseLooks = false
    public var stillFace: StillFaceMode = .observe
    public var sound = false
    public var notify = true
    public var adaptation = true

    public init() {}

    public func effectiveCadence(onBattery: Bool) -> Cadence {
        slowerOnBattery && onBattery ? .relaxed : .named(cadence)
    }
}
