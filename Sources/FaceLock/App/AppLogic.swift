import Darwin
import FaceLockCore
import Foundation

enum CameraAccess: Equatable, Sendable {
    case authorized, notDetermined, denied
}

enum Protection {
    /// Why FaceLock cannot watch right now, most fundamental first; nil when it can.
    static func blockReason(modelsAvailable: Bool, hasCamera: Bool, camera: CameraAccess,
                            store: StoreLoad) -> NotProtectingReason? {
        if !modelsAvailable { return .modelsMissing }
        if !hasCamera { return .noCamera }
        if camera == .denied { return .cameraAccessOff }
        switch store {
        case .empty: return .noEnrollment
        case .needsReenroll: return .needsReenroll
        case .keyUnavailable: return .keyUnavailable
        case .loaded: break
        }
        return camera == .notDetermined ? .cameraAccessOff : nil
    }
}

enum PauseChoice: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes, oneHour, untilUnlock, untilTomorrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .untilUnlock: return "Until I unlock"
        case .untilTomorrow: return "Until tomorrow morning"
        }
    }

    func pause(from now: Date) -> Pause {
        switch self {
        case .fifteenMinutes: return .minutes(15, from: now)
        case .oneHour: return .minutes(60, from: now)
        case .untilUnlock: return .untilUnlock
        case .untilTomorrow: return .untilTomorrow(from: now)
        }
    }
}

/// The countdown panel's words. Moving the mouse only buys one more look, so the card never
/// promises that it keeps the Mac unlocked.
enum CountdownCopy {
    static func title(_ reason: CountdownReason, secondsLeft: Int) -> String {
        switch reason {
        case .away: return "Locking in \(secondsLeft) s"
        case .headTurn: return "Turn your head"
        case .checking: return "Checking for you…"
        }
    }

    static func detail(_ reason: CountdownReason) -> String {
        switch reason {
        case .away: return "Look at the camera to stay unlocked. Moving the mouse gives FaceLock one more look."
        case .headTurn: return "A face has stayed perfectly still for minutes. Turn your head left or right to stay unlocked."
        case .checking: return "Look at the camera. If FaceLock doesn't see you, it locks without another countdown."
        }
    }

    static func announcement(_ reason: CountdownReason, seconds: Int) -> String {
        switch reason {
        case .away: return "FaceLock is locking your Mac in \(seconds) seconds. Look at the camera to stay unlocked."
        case .headTurn: return "FaceLock needs you to turn your head within \(seconds) seconds to stay unlocked."
        case .checking: return "FaceLock is checking for you. Look at the camera to stay unlocked."
        }
    }

    /// What "I'm here" does, for VoiceOver.
    static let hereHint = "FaceLock takes one more look. If it doesn't see you, it locks."
}

enum CadenceCopy {
    static func summary(_ name: CadenceName, countdownSeconds: Int) -> String {
        let c = Cadence.named(name)
        return "Checks every \(Int(c.interval)) s. \(c.graceText(countdownSeconds: TimeInterval(countdownSeconds)))."
    }
}

enum DayTwo {
    static let after: TimeInterval = 12 * 3600

    /// "Add today's light" shows once the enrollment is half a day old and still a single session.
    static func shouldOffer(_ p: EnrollmentPayload?, now: Date, dismissed: Bool) -> Bool {
        guard let p, !dismissed else { return false }
        return p.gallery.sessionCount <= 1 && now.timeIntervalSince(p.createdAt) >= after
    }

    static func nextSession(_ g: Gallery) -> Int { (g.anchors.map(\.session).max() ?? -1) + 1 }
}

enum LegacyCheck {
    /// The 0.4 launcher is an 8 KB zsh script in an app folder. Never the app that is running,
    /// and never a real executable, so a new FaceLock installed in ~/Applications is safe.
    static func isOldLauncher(_ app: URL, running: URL) -> Bool {
        guard app.resolvingSymlinksInPath().standardizedFileURL != running.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let files = (try? FileManager.default.contentsOfDirectory(at: macOS, includingPropertiesForKeys: nil)) ?? []
        return files.contains { f in
            guard let h = try? FileHandle(forReadingFrom: f) else { return false }
            defer { try? h.close() }
            return (try? h.read(upToCount: 2)) == Data("#!".utf8)
        }
    }

    /// The pid file can outlive the watcher and the number can be reused, even by another Python
    /// job: only a process whose own path or arguments name facelock counts. Never this app.
    static func isOldWatcher(pid: Int32) -> Bool {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return namesFaceLock(arguments(pid))
    }

    static func namesFaceLock(_ args: [String]) -> Bool {
        args.contains { $0.lowercased().contains("facelock") }
    }

    /// The executable path and argv of a process (KERN_PROCARGS2), empty when unreadable.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        let parts = buf[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        return parts.prefix(argc + 1).map { String(decoding: $0, as: UTF8.self) }
    }
}
