import Foundation

public enum WatcherEvent: Equatable, Sendable {
    case start
    case timerFired
    case windowFinished(id: Int, summary: WindowSummary)
    /// Input during the countdown (CGEventSource poll) or the "I'm here" button.
    case userInput
    case lockResult(LockOutcome)
    case screenLocked, screenUnlocked
    case displaySlept, displayWoke
    case systemWillSleep, systemDidWake
    case cameraAvailable(Bool)
    /// A setup screen takes the camera; checks resume with one at once when it hands it back.
    case setupStarted, setupEnded
    case pause(Pause)
    case resume
    case checkNow
    case block(NotProtectingReason)
    case unblock
    case settingsChanged(WatcherSettings)
    case powerSourceChanged(onBattery: Bool)
}

public enum WatcherEffect: Equatable, Sendable {
    case startWindow(id: Int, kind: CheckKind, policy: WindowPolicy)
    case abortWindow
    case schedule(at: Date)
    case cancelSchedule
    case showCountdown(endsAt: Date, reason: CountdownReason)
    case hideCountdown
    case startInputMonitor
    case stopInputMonitor
    case lock
    case notify(Notice)
    case record(CheckRecord)
    /// An owner frame the controller may add to the adaptive pool after the safeguards.
    case considerAdaptation(AdaptationCandidate)
}

public struct Transition: Equatable, Sendable {
    public let state: WatcherState
    public let effects: [WatcherEffect]
}

/// The pure presence state machine: no camera, no clock, no timers. The controller feeds it
/// events with the current time and performs the effects it returns.
public enum Watcher {
    public static func reduce(_ state: WatcherState, _ event: WatcherEvent, now: Date) -> Transition {
        var step = Step(s: state, now: now)
        step.handle(event)
        return Transition(state: step.s, effects: step.effects)
    }
}

private struct Step {
    var s: WatcherState
    let now: Date
    var effects: [WatcherEffect] = []

    init(s: WatcherState, now: Date) {
        self.s = s
        self.now = now
    }

    mutating func handle(_ event: WatcherEvent) {
        switch event {
        case .start: if s.isActive { begin(.regular) }
        case .timerFired: timerFired()
        case let .windowFinished(id, summary): windowFinished(id, summary)
        case .userInput: userInput()
        case let .lockResult(outcome): lockResult(outcome)
        case .screenLocked: changeAvailability { $0.suppressions.insert(.screenLocked) }
        case .screenUnlocked: screenUnlocked()
        case .displaySlept: changeAvailability { $0.suppressions.insert(.displayAsleep) }
        case .displayWoke: changeAvailability { $0.suppressions.remove(.displayAsleep) }
        case .systemWillSleep: changeAvailability { $0.suppressions.insert(.systemAsleep) }
        case .systemDidWake: changeAvailability { $0.suppressions.remove(.systemAsleep) }
        case let .cameraAvailable(ok):
            changeAvailability { s in
                if ok { s.suppressions.remove(.cameraUnavailable) } else { s.suppressions.insert(.cameraUnavailable) }
            }
        case .setupStarted: changeAvailability { $0.suppressions.insert(.setup) }
        case .setupEnded: changeAvailability(immediate: true) { $0.suppressions.remove(.setup) }
        case let .pause(p): pause(p)
        case .resume: changeAvailability(immediate: true) { $0.pause = nil }
        case .checkNow: checkNow()
        case let .block(reason): changeAvailability { $0.blocked = reason }
        case .unblock: changeAvailability(immediate: true) { $0.blocked = nil }
        case let .settingsChanged(settings): s.settings = settings
        case let .powerSourceChanged(onBattery): s.onBattery = onBattery
        }
    }

    // MARK: scheduling

    mutating func schedule(after delay: TimeInterval) {
        let at = now.addingTimeInterval(delay)
        s.nextCheckAt = at
        effects.append(.schedule(at: at))
    }

    mutating func begin(_ kind: CheckKind) {
        s.lastWindowID += 1
        s.activeWindow = ActiveWindow(id: s.lastWindowID, kind: kind)
        s.nextCheckAt = nil
        let policy = WindowPolicy.forKind(kind, countdownSeconds: TimeInterval(s.settings.countdownSeconds))
        switch kind {
        case .countdown:
            s.phase = .countdown
            let ends = now.addingTimeInterval(policy.duration)
            s.countdownEndsAt = ends
            effects += [.showCountdown(endsAt: ends, reason: .away), .startInputMonitor]
        case .challenge:
            s.phase = .challenge
            let ends = now.addingTimeInterval(policy.duration)
            s.countdownEndsAt = ends
            effects.append(.showCountdown(endsAt: ends, reason: .headTurn))
        case .confirm:
            break
        case .regular, .recheck, .manual:
            s.phase = .checking(kind)
        }
        effects.append(.startWindow(id: s.lastWindowID, kind: kind, policy: policy))
    }

    mutating func endCountdownUI() {
        s.countdownEndsAt = nil
        effects += [.hideCountdown, .stopInputMonitor]
    }

    mutating func lock() {
        s.phase = .locking
        s.misses = 0
        s.nextCheckAt = nil
        effects.append(.lock)
    }

    mutating func backToWatching() {
        s.phase = .present
        s.misses = 0
        s.lastOwnerSeen = now
        schedule(after: s.cadence.interval)
    }

    // MARK: events

    mutating func timerFired() {
        s.nextCheckAt = nil
        if let p = s.pause {
            if p.isExpired(at: now.addingTimeInterval(0.5)) { changeAvailability(immediate: true) { $0.pause = nil } }
            return
        }
        guard s.isActive, s.activeWindow == nil else { return }
        switch s.phase {
        case .present: begin(.regular)
        case .looking, .stranger: begin(.recheck)
        default: break
        }
    }

    mutating func checkNow() {
        guard s.isActive, s.activeWindow == nil else { return }
        switch s.phase {
        case .present, .looking, .stranger:
            effects.append(.cancelSchedule)
            begin(.manual)
        default: break
        }
    }

    mutating func windowFinished(_ id: Int, _ summary: WindowSummary) {
        guard let w = s.activeWindow, w.id == id else { return }
        s.activeWindow = nil
        effects.append(.record(.check(summary, kind: w.kind, at: now)))
        switch w.kind {
        case .regular, .recheck, .manual: afterCheck(summary)
        case .countdown: afterCountdown(summary)
        case .confirm: summary.verdict == .owner ? backToWatching() : lock()
        case .challenge: afterChallenge(summary)
        }
    }

    mutating func afterCheck(_ summary: WindowSummary) {
        guard summary.verdict != .owner else { return ownerSeen(summary) }
        s.misses += 1
        s.secondFaceWindows = 0
        s.someoneElseInView = false
        s.stillFace = s.stillFace.reset()
        if summary.verdict != .away { s.strangerOrUnclearSinceUnlock = true }
        if s.misses >= s.cadence.confirmChecks { return begin(.countdown) }
        s.phase = summary.verdict == .stranger ? .stranger : .looking
        schedule(after: s.cadence.delay(after: summary.verdict, misses: s.misses))
    }

    mutating func ownerSeen(_ summary: WindowSummary) {
        s.phase = .present
        s.misses = 0
        s.lastOwnerSeen = now
        s.secondFaceWindows = summary.secondFace ? s.secondFaceWindows + 1 : 0
        if !summary.secondFace { s.someoneElseInView = false }
        if s.secondFaceWindows == 2 {
            s.someoneElseInView = true
            effects += [.notify(.someoneElseInView), .record(CheckRecord(at: now, event: .someoneElse))]
            if s.settings.lockWhenSomeoneElseLooks { return lock() }
        }
        if let o = summary.owner {
            if s.settings.adaptation, !summary.secondFace {
                effects.append(.considerAdaptation(AdaptationCandidate(
                    embedding: o.embedding, qualityPassed: true, faceCount: o.faceCount, anchorScore: o.score.anchor,
                    sharpness: Float(o.sharpness))))
            }
            if stillFaceFlagged(o) { return }
        }
        schedule(after: s.cadence.interval)
    }

    /// True when the flag started the head-turn challenge.
    mutating func stillFaceFlagged(_ o: OwnerSample) -> Bool {
        guard s.settings.stillFace != .off else { return false }
        s.stillFace = s.stillFace.adding(StillFaceSample(at: now, landmarks: o.landmarks, boxWidth: o.boxWidth))
        guard s.stillFace.isFlagged else { return false }
        s.stillFace = s.stillFace.reset()
        let observeOnly = s.settings.stillFace == .observe
        var r = CheckRecord(at: now, event: .stillFace)
        r.note = observeOnly ? "observe" : "challenge"
        effects += [.record(r), .notify(.stillFaceFlagged(observeOnly: observeOnly))]
        guard !observeOnly else { return false }
        begin(.challenge)
        return true
    }

    mutating func afterCountdown(_ summary: WindowSummary) {
        endCountdownUI()
        if summary.verdict == .owner {
            effects.append(.record(.cancel(.owner, at: now)))
            return backToWatching()
        }
        guard summary.sawFace else { return lock() }
        effects.append(.record(.cancel(.face, at: now)))
        s.phase = .confirming(.face)
        begin(.confirm)
    }

    mutating func afterChallenge(_ summary: WindowSummary) {
        endCountdownUI()
        summary.verdict == .owner && HeadTurnChallenge.passed(yawRange: summary.yawRange) ? backToWatching() : lock()
    }

    /// Input cancels the countdown once: the forced check that follows locks unless it sees the owner.
    mutating func userInput() {
        guard s.phase == .countdown, s.activeWindow != nil else { return }
        s.activeWindow = nil
        effects.append(.abortWindow)
        endCountdownUI()
        effects.append(.record(.cancel(.input, at: now)))
        s.phase = .confirming(.input)
        begin(.confirm)
    }

    mutating func lockResult(_ outcome: LockOutcome) {
        effects.append(.record(.lock(outcome, at: now)))
        if outcome != .locked { effects.append(.notify(.lockFailed(outcome))) }
        guard s.phase == .locking else { return }
        s.phase = .present
        s.misses = 0
        if s.isActive { schedule(after: outcome == .locked ? s.cadence.interval : s.cadence.recheckInterval) }
    }

    mutating func screenUnlocked() {
        changeAvailability {
            $0.suppressions.remove(.screenLocked)
            $0.strangerOrUnclearSinceUnlock = false
            if $0.pause == .untilUnlock { $0.pause = nil }
        }
        s.lastOwnerSeen = now
    }

    mutating func pause(_ p: Pause) {
        changeAvailability { $0.pause = p }
        if case let .until(end) = p {
            s.nextCheckAt = end
            effects.append(.schedule(at: end))
        }
    }

    /// Applies a change to pause, block or suppression state, stopping everything when watching
    /// becomes impossible and starting again when it becomes possible.
    mutating func changeAvailability(immediate: Bool = false, _ change: (inout WatcherState) -> Void) {
        let was = s.isActive
        change(&s)
        if was && !s.isActive { stopEverything() }
        if !was && s.isActive {
            s.phase = .present
            s.misses = 0
            immediate ? begin(.regular) : schedule(after: s.cadence.interval)
        }
    }

    mutating func stopEverything() {
        if s.activeWindow != nil { effects.append(.abortWindow) }
        if s.countdownEndsAt != nil { endCountdownUI() }
        s.activeWindow = nil
        s.nextCheckAt = nil
        s.phase = .present
        s.misses = 0
        s.secondFaceWindows = 0
        s.someoneElseInView = false
        effects.append(.cancelSchedule)
    }
}
