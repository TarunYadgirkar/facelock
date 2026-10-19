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
        #expect(h.has(.stopInputMonitor))
        #expect(h.effects.contains { if case .showCountdown(_, .checking) = $0 { return true } else { return false } })
        #expect(h.state.status(now: h.now).text == "Checking for you")
        #expect(h.startedKind == .confirm)
        #expect(h.records.contains { $0.cancel == .input })
        h.finish(summary(.away), after: 1.5)
        #expect(h.locked)
        #expect(h.has(.hideCountdown))
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

    @Test("a failed lock notifies and keeps looking, never shows Watching while the owner is away")
    func lockFailure() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.finish(summary(.away), after: 10)
        h.send(.lockResult(.failed), after: 2)
        #expect(h.has(.notify(.lockFailed(.failed))))
        #expect(h.records.contains { $0.event == .lock && $0.outcome == .failed })
        #expect(h.state.watchState == .looking)
        #expect(h.state.status(now: h.now).text == "Lock failed. Looking for you. 3 checks left")
        #expect(h.scheduledDelay == 10)
        h.send(.timerFired, after: 10)
        h.finish(summary(.owner))
        #expect(!h.state.lockFailed)
        #expect(h.state.watchState == .present)
    }

    @Test("a dry run's pretend lock keeps looking without a failure notice")
    func dryRunLock() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.finish(summary(.away), after: 10)
        h.send(.lockResult(.dryRun))
        #expect(!h.effects.contains { if case .notify = $0 { return true } else { return false } })
        #expect(h.state.status(now: h.now).text == "Looking for you. 3 checks left")
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
        #expect(h.effects == [.schedule(at: h.now.addingTimeInterval(300))])
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

    @Test("a restored pause that already ended is dropped, and Until I unlock never outlives a login")
    func pauseRestore() {
        #expect(Pause.restored(.until(t0), now: t0.addingTimeInterval(1), screenLocked: false) == nil)
        #expect(Pause.restored(.until(t0.addingTimeInterval(60)), now: t0, screenLocked: false) == .until(t0.addingTimeInterval(60)))
        #expect(Pause.restored(.untilUnlock, now: t0, screenLocked: false) == nil)
        #expect(Pause.restored(.untilUnlock, now: t0, screenLocked: true) == .untilUnlock)
    }

    @Test("until tomorrow ends at the next 6:00 AM", arguments: [
        (23, 50, 1, 6), (9, 0, 1, 6), (1, 0, 0, 6),
    ])
    func untilTomorrow(_ hour: Int, _ minute: Int, _ dayOffset: Int, _ endHour: Int) throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: hour, minute: minute)))
        guard case let .until(end) = Pause.untilTomorrow(from: start, calendar: cal) else { return #expect(Bool(false)) }
        let c = cal.dateComponents([.day, .hour, .minute], from: end)
        #expect(c.day == 18 + dayOffset && c.hour == endHour && c.minute == 0)
    }

    @Test("a timed pause that ends while the Mac sleeps ends at wake, and checks at once")
    func pauseOverSleep() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        h.send(.pause(.minutes(15, from: h.now)))
        h.send(.systemWillSleep, after: 60)
        h.send(.displaySlept)
        h.send(.systemDidWake, after: 7200)
        #expect(h.state.pause == nil)
        h.send(.displayWoke)
        #expect(h.state.pause == nil)
        #expect(h.state.isActive)
        #expect(h.startedKind == .regular)
    }

    @Test("a pause timer that fires early waits for the pause's end again")
    func pauseTimerEarly() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.owner))
        h.send(.pause(.minutes(15, from: h.now)))
        h.send(.timerFired, after: 60)
        #expect(h.state.pause != nil)
        #expect(h.scheduledDelay == 840)
    }

    @Test("an expired pause also ends on unlock")
    func pauseExpiredAtUnlock() {
        var h = Harness()
        h.send(.start)
        h.send(.screenLocked)
        h.send(.pause(.minutes(15, from: h.now)))
        h.send(.screenUnlocked, after: 3600)
        #expect(h.state.pause == nil)
        #expect(h.state.isActive)
    }

    @Test("nothing runs while locked, asleep, display off or camera unavailable", arguments: [
        (WatcherEvent.screenLocked, WatcherEvent.screenUnlocked, false),
        (.displaySlept, .displayWoke, true),
        (.systemWillSleep, .systemDidWake, true),
        (.cameraAvailable(false), .cameraAvailable(true), true),
    ])
    func suppression(_ off: WatcherEvent, _ on: WatcherEvent, _ checksAtOnce: Bool) {
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
        if checksAtOnce {
            #expect(h.startedKind == .regular)
        } else {
            #expect(h.state.watchState == .present)
            #expect(h.scheduledDelay == 30)
        }
    }

    @Test("waking the display mid-sequence starts the miss sequence again at once, not after a full interval")
    func displayWakeChecksAtOnce() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away])
        h.send(.displaySlept, after: 1)
        h.send(.displayWoke, after: 5)
        #expect(h.startedKind == .regular)
        h.finish(summary(.away))
        #expect(h.scheduledDelay == 10)
    }

    @Test("a window without frames is no miss: retried with backoff, and two in a row say not protecting")
    func cameraFailure() {
        var h = Harness()
        h.send(.start)
        h.finish(summary(.cameraFailed))
        #expect(h.state.misses == 0)
        #expect(h.state.watchState == .present)
        #expect(h.scheduledDelay == 2.5)
        #expect(h.records.first?.verdict == .cameraFailed)
        h.send(.timerFired, after: 2.5)
        h.finish(summary(.cameraFailed))
        #expect(h.state.misses == 0)
        #expect(h.state.watchState == .notProtecting)
        #expect(h.state.status(now: h.now).text.hasPrefix("Not protecting: the camera isn't responding"))
        #expect(h.scheduledDelay == 5)
        for _ in 0..<6 {
            h.send(.timerFired, after: h.scheduledDelay ?? 0)
            h.finish(summary(.cameraFailed))
        }
        #expect(h.scheduledDelay == 60)
        #expect(!h.locked)
        h.send(.timerFired, after: 60)
        h.finish(summary(.owner))
        #expect(h.state.cameraFailures == 0)
        #expect(h.state.watchState == .present)
    }

    @Test("endless camera failures never reach the countdown or a lock")
    func cameraFailureNeverLocks() {
        var h = Harness()
        h.send(.start)
        for _ in 0..<20 {
            h.finish(summary(.cameraFailed))
            #expect(!h.locked)
            #expect(h.state.countdownEndsAt == nil)
            h.send(.timerFired, after: h.scheduledDelay ?? 0)
        }
    }

    @Test("a camera failure during the countdown stands it down without locking; misses carry over")
    func cameraFailureInCountdown() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        #expect(h.state.watchState == .countdown)
        h.finish(summary(.cameraFailed), after: 10)
        #expect(!h.locked)
        #expect(h.has(.hideCountdown))
        #expect(h.has(.stopInputMonitor))
        #expect(h.state.watchState == .looking)
        h.send(.timerFired, after: h.scheduledDelay ?? 0)
        #expect(h.startedKind == .recheck)
        h.finish(summary(.away))
        #expect(h.state.watchState == .countdown)
    }

    @Test("a camera failure in the confirm check does not lock")
    func cameraFailureInConfirm() {
        var h = Harness()
        h.send(.start)
        h.run([.away, .away, .away])
        h.send(.userInput, after: 2)
        h.finish(summary(.cameraFailed), after: 3)
        #expect(!h.locked)
        #expect(h.has(.hideCountdown))
        #expect(!h.state.checkingShown)
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

    @Test("starting up blocks the first check until the app unblocks")
    func startingUp() {
        var h = Harness()
        h.send(.block(.starting))
        h.send(.start)
        #expect(h.effects.isEmpty)
        #expect(h.state.status(now: h.now).text == "Not protecting: starting up")
        h.send(.unblock)
        #expect(h.startedKind == .regular)
    }

    @Test("a setup screen takes the camera: checks stop, then one runs at once when it ends")
    func setup() {
        var h = Harness()
        h.send(.start)
        h.send(.setupStarted)
        #expect(h.has(.abortWindow))
        #expect(h.state.status(now: h.now).text == "Paused while setup uses the camera")
        h.send(.checkNow)
        #expect(h.effects.isEmpty)
        h.send(.setupEnded, after: 20)
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
        #expect(Cadence.named(name).graceText(countdownSeconds: 10) == "Locks within \(seconds) s after you leave")
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

@Suite("Check windows")
struct WindowTests {
    @Test("a slow camera open never eats the settle cap or the window: both count from the first frame")
    func slowOpen() {
        var g = WindowGate(policy: .regular, startedAt: 0)
        var action: WindowGate.Action
        (g, action) = g.next(frameAt: 2.4, exposureSettled: false, luma: 100)
        #expect(action == .discard)
        (g, action) = g.next(frameAt: 2.8, exposureSettled: false, luma: 100)
        #expect(action == .discard)
        (g, action) = g.next(frameAt: 3.0, exposureSettled: false, luma: 100)
        #expect(action == .process)
        #expect(g.deadline == 4.5)
        #expect(g.timing(endedAt: 3.1).firstFrame == 2.4)
    }

    @Test("no frame, or only frames that failed analysis, is a camera failure; one good frame is not")
    func cameraFailedVerdict() {
        let t = Thresholds(accept: 0.5)
        let empty = WindowAccumulator(policy: .regular, thresholds: t)
        #expect(empty.summary(timing: WindowTiming(cameraOn: 3.25, firstFrame: nil, settled: nil)).verdict == .cameraFailed)
        let opened = WindowTiming(cameraOn: 1, firstFrame: 0.2, settled: 0.3)
        let failing = empty.addingFailure().addingFailure()
        #expect(failing.summary(timing: opened).verdict == .cameraFailed)
        #expect(failing.summary(timing: opened).failedFrames == 2)
        let mixed = failing.adding(FrameObservation(faces: []))
        #expect(mixed.summary(timing: opened).verdict == .away)
        let sized = empty.noting(frameSize: FrameSize(width: 1280, height: 720)).noting(frameSize: FrameSize(width: 640, height: 480))
        #expect(sized.summary(timing: opened).frameSize == FrameSize(width: 1280, height: 720))
        #expect(CheckRecord.check(sized.summary(timing: opened), kind: .regular, at: t0).frameSize == "1280x720")
    }
}
