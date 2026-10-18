import FaceLockCore
import Foundation
import Testing

@Suite("Watcher state machine")
struct WatcherTests {
    @Test("present: an owner window returns to Watching and schedules the next check after the interval")
    func present() {
        var h = Harness()
        h.send(.start)
        #expect(h.startedKind == .regular)
        #expect(h.state.watchState == .checking)
        h.finish(summary(.owner))
        #expect(h.state.watchState == .present)
        #expect(h.scheduledDelay == 30)
        #expect(h.records.first?.verdict == .owner)
        h.send(.timerFired, after: 30)
        #expect(h.startedKind == .regular)
    }

    @Test("away: rechecks at 10 s then 5 s, then the countdown with the camera on")
    func away() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.away))
        #expect(h.state.watchState == .looking)
        #expect(h.state.checksLeft == 2)
        #expect(h.scheduledDelay == 10)
        h.send(.timerFired, after: 10)
        #expect(h.startedKind == .recheck)
        h.finish(summary(.away))
        #expect(h.scheduledDelay == 5)
        h.send(.timerFired, after: 5)
        h.finish(summary(.away))
        #expect(h.state.watchState == .countdown)
        #expect(h.startedKind == .countdown)
        #expect(h.has(.startInputMonitor))
        #expect(h.has(.showCountdown(endsAt: h.now.addingTimeInterval(10), reason: .away)))
    }

    @Test("unclear follows the away cadence, never the stranger one (A4)")
    func unclear() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.unclear))
        #expect(h.state.watchState == .looking)
        #expect(h.scheduledDelay == 10)
        #expect(h.state.strangerOrUnclearSinceUnlock)
    }

    @Test("stranger fast path only for a window with at least 2 stranger frames")
    func strangerFastPath() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.stranger))
        #expect(h.state.watchState == .stranger)
        #expect(h.scheduledDelay == 5)

        let t = Thresholds(accept: 0.5)
        let stranger = FrameObservation(faces: [observation(score: MatchScore(union: 0.1, anchor: 0.1))])
        let empty = FrameObservation(faces: [])
        let one = WindowAccumulator(policy: .regular, thresholds: t).adding(stranger).adding(empty)
        #expect(one.verdict == .unclear)
        let two = one.adding(stranger)
        #expect(two.verdict == .stranger)
    }

    @Test("countdown cancelled by the owner's face goes back to Watching")
    func countdownOwnerCancel() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        #expect(h.state.watchState == .countdown)
        h.finish(summary(.owner), after: 3)
        #expect(h.state.watchState == .present)
        #expect(h.has(.hideCountdown))
        #expect(h.has(.stopInputMonitor))
        #expect(h.records.contains { $0.event == .cancel && $0.cancel == .owner })
        #expect(h.scheduledDelay == 30)
    }

    @Test("input cancels the countdown once: the forced check locks without a second countdown")
    func inputCancelThenLock() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.send(.userInput, after: 2)
        #expect(h.has(.abortWindow))
        #expect(h.has(.hideCountdown))
        #expect(h.startedKind == .confirm)
        #expect(h.records.contains { $0.cancel == .input })
        h.finish(summary(.away), after: 1.5)
        #expect(h.locked)
        #expect(!h.effects.contains { if case .showCountdown = $0 { return true } else { return false } })
        h.send(.userInput)
        #expect(h.effects.isEmpty)
    }

    @Test("input cancel followed by the owner returns to Watching")
    func inputCancelThenOwner() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.send(.userInput, after: 2)
        h.finish(summary(.owner), after: 0.3)
        #expect(h.state.watchState == .present)
        #expect(!h.locked)
    }

    @Test("a stale window result is ignored")
    func staleWindow() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        let countdownID = h.state.activeWindow!.id
        h.send(.userInput)
        h.send(.windowFinished(id: countdownID, summary: summary(.away)))
        #expect(!h.locked)
        #expect(h.state.phase == .confirming(.input))
    }

    @Test("countdown with no face locks; with a stranger it runs one confirm check, then locks")
    func countdownOutcomes() {
        var a = Harness()
        a.send(.start)
        a.run([.away, .away, .away])
        a.finish(summary(.away), after: 10)
        #expect(a.locked)
        #expect(a.state.phase == .locking)

        var b = Harness()
        b.send(.start)
        b.run([.away, .away, .away])
        b.finish(summary(.unclear), after: 4)
        #expect(b.startedKind == .confirm)
        #expect(b.records.contains { $0.cancel == .face })
        b.finish(summary(.stranger), after: 2)
        #expect(b.locked)
    }

    @Test("a failed lock notifies and goes back to checking")
    func lockFailure() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.finish(summary(.away), after: 10)
        h.send(.lockResult(.failed), after: 2)
        #expect(h.has(.notify(.lockFailed(.failed))))
        #expect(h.records.contains { $0.event == .lock && $0.outcome == .failed })
        #expect(h.state.watchState == .present)
        #expect(h.scheduledDelay == 10)
    }

    @Test("pause 15 minutes stops checks, and the timer at its end resumes with a check")
    func pauseExpiry() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        h.send(.pause(.minutes(15, from: h.now)))
        #expect(h.state.watchState == .paused)
        #expect(h.has(.cancelSchedule))
        #expect(h.scheduledDelay == 900)
        h.send(.timerFired, after: 600)
        #expect(h.effects.isEmpty)
        h.send(.checkNow)
        #expect(h.effects.isEmpty)
        h.send(.timerFired, after: 300)
        #expect(h.state.pause == nil)
        #expect(h.startedKind == .regular)
    }

    @Test("pause until I unlock clears on com.apple.screenIsUnlocked")
    func pauseUntilUnlock() {
        var h = Harness()
        h.send(.start)
        h.send(.pause(.untilUnlock))
        #expect(h.has(.abortWindow))
        h.send(.screenLocked, after: 60)
        h.send(.screenUnlocked, after: 600)
        #expect(h.state.pause == nil)
        #expect(h.state.watchState == .present)
        #expect(h.scheduledDelay == 30)
    }

    @Test("a restored pause that already ended is dropped")
    func pauseRestore() {
        #expect(Pause.restored(.until(t0), now: t0.addingTimeInterval(1)) == nil)
        #expect(Pause.restored(.until(t0.addingTimeInterval(60)), now: t0) == .until(t0.addingTimeInterval(60)))
        #expect(Pause.restored(.untilUnlock, now: t0) == .untilUnlock)
        let tomorrow = Pause.untilTomorrow(from: t0, calendar: Calendar(identifier: .gregorian))
        if case let .until(d) = tomorrow { #expect(d > t0 && d.timeIntervalSince(t0) <= 86_400) }
    }

    @Test("nothing runs while locked, asleep, display off or camera unavailable", arguments: [
        (WatcherEvent.screenLocked, WatcherEvent.screenUnlocked),
        (.displaySlept, .displayWoke),
        (.systemWillSleep, .systemDidWake),
        (.cameraAvailable(false), .cameraAvailable(true)),
    ])
    func suppression(_ off: WatcherEvent, _ on: WatcherEvent) {
        var h = Harness()
        h.send(.start)
        h.send(off)
        #expect(h.has(.abortWindow))
        #expect(h.has(.cancelSchedule))
        #expect(h.state.watchState == .suspended)
        h.send(.timerFired, after: 30)
        #expect(h.effects.isEmpty)
        h.send(.checkNow)
        #expect(h.effects.isEmpty)
        h.send(on, after: 300)
        #expect(h.state.watchState == .present)
        #expect(h.scheduledDelay == 30)
    }

    @Test("suppression during the countdown hides it and stops the input poll")
    func suppressionDuringCountdown() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.send(.systemWillSleep)
        #expect(h.has(.hideCountdown))
        #expect(h.has(.stopInputMonitor))
        #expect(h.state.countdownEndsAt == nil)
    }

    @Test("not protecting blocks checks until unblocked, which checks at once")
    func blocked() {
        var h = Harness()
        h.send(.block(.cameraAccessOff))
        h.send(.start)
        #expect(h.effects.isEmpty)
        #expect(h.state.status(now: h.now).fix == .openCameraSettings)
        #expect(h.state.status(now: h.now).text == "Not protecting: camera access is off")
        h.send(.unblock)
        #expect(h.startedKind == .regular)
    }

    @Test("check now runs a manual window from Watching")
    func checkNow() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        h.send(.checkNow, after: 5)
        #expect(h.has(.cancelSchedule))
        #expect(h.startedKind == .manual)
        h.send(.checkNow)
        #expect(h.effects.isEmpty)
    }

    @Test("someone else in view after 2 consecutive windows; locks only when that setting is on")
    func shoulderSurfing() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner, secondFace: true))
        #expect(!h.state.someoneElseInView)
        #expect(!h.effects.contains { if case .considerAdaptation = $0 { return true } else { return false } })
        h.send(.timerFired, after: 30)
        h.finish(summary(.owner, secondFace: true))
        #expect(h.state.someoneElseInView)
        #expect(h.has(.notify(.someoneElseInView)))
        #expect(!h.locked)
        #expect(h.state.status(now: h.now).glyph == .someoneElse)

        var s = WatcherSettings()
        s.lockWhenSomeoneElseLooks = true
        var l = Harness(settings: s)
        l.send(.start)
        l.finish(summary(.owner, secondFace: true))
        l.send(.timerFired, after: 30)
        l.finish(summary(.owner, secondFace: true))
        #expect(l.locked)
    }

    @Test("owner windows offer adaptation candidates unless another face is present")
    func adaptationCandidate() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        #expect(h.effects.contains { if case .considerAdaptation = $0 { return true } else { return false } })
    }

    @Test("still face in observe mode logs and never locks; in on mode it starts the head-turn challenge")
    func stillFace() {
        for mode in [StillFaceMode.observe, .on] {
            var s = WatcherSettings()
            s.stillFace = mode
            var h = Harness(settings: s)
            h.send(.start)
            for i in 0..<6 {
                if i > 0 { h.send(.timerFired, after: 36) }
                h.finish(summary(.owner))
            }
            #expect(h.records.contains { $0.event == .stillFace })
            #expect(h.has(.notify(.stillFaceFlagged(observeOnly: mode == .observe))))
            if mode == .observe {
                #expect(h.state.watchState == .present)
                continue
            }
            #expect(h.startedKind == .challenge)
            #expect(h.has(.showCountdown(endsAt: h.now.addingTimeInterval(8), reason: .headTurn)))
            var pass = h
            pass.finish(summary(.owner, yawRange: 0.2), after: 3)
            #expect(pass.state.watchState == .present)
            #expect(!pass.locked)
            h.finish(summary(.owner, yawRange: 0.05), after: 8)
            #expect(h.locked)
        }
    }

    @Test("grace text states the worst case for each preset", arguments: [
        (CadenceName.relaxed, 85), (.balanced, 62), (.strict, 36),
    ])
    func grace(_ name: CadenceName, _ seconds: Int) {
        #expect(Cadence.named(name).graceText(countdownSeconds: 10) == "Locks about \(seconds) s after you leave")
    }

    @Test("slower checks on battery switches to Relaxed only on battery")
    func battery() {
        var s = WatcherSettings()
        s.slowerOnBattery = true
        #expect(s.effectiveCadence(onBattery: true) == .relaxed)
        #expect(s.effectiveCadence(onBattery: false) == .balanced)
    }

    @Test("status line wording")
    func status() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        #expect(h.state.status(now: h.now.addingTimeInterval(12)).text == "Watching. You were here 12 s ago")
        #expect(h.state.status(now: h.now).tone == .good)
        h.send(.timerFired, after: 30)
        h.finish(summary(.away))
        let s = h.state.status(now: h.now)
        #expect(s.text == "Looking for you. 2 checks left")
        #expect(s.glyph == .lookingForYou(checksLeft: 2))
        #expect(s.tone == .warning)
    }
}
