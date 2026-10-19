import CryptoKit
import FaceLockCore
import FaceLockSystem
import Foundation
import Testing
@testable import FaceLock

@Suite("App logic")
struct AppLogicTests {
    @Test("the most basic reason to not protect wins")
    func blockReason() {
        let loaded = StoreLoad.loaded(EnrollmentPayload(templates: [], thresholds: .uncalibrated, calibration: nil))
        func reason(models: Bool = true, camera: Bool = true, access: CameraAccess = .authorized, store: StoreLoad = loaded) -> NotProtectingReason? {
            Protection.blockReason(modelsAvailable: models, hasCamera: camera, camera: access, store: store)
        }
        #expect(reason() == nil)
        #expect(reason(models: false, camera: false, access: .denied, store: .empty) == .modelsMissing)
        #expect(reason(camera: false, access: .denied) == .noCamera)
        #expect(reason(access: .denied, store: .empty) == .cameraAccessOff)
        #expect(reason(access: .notDetermined, store: .empty) == .noEnrollment)
        #expect(reason(store: .needsReenroll(.keyMissing)) == .needsReenroll)
        #expect(reason(access: .notDetermined) == .cameraAccessOff)
    }

    @Test("a demo camera always means a dry run, and snapshots need one")
    func options() {
        let demo = LaunchOptions.parse(["FaceLock", "--demo-camera", "/tmp/a.jpg", "--snapshot", "/tmp/out"])
        #expect(demo.isDemo && demo.neverLocks)
        #expect(demo.snapshotDirectory?.path == "/tmp/out")
        let plain = LaunchOptions.parse(["FaceLock", "--snapshot", "/tmp/out", "-NSDocumentRevisionsDebugMode", "YES"])
        #expect(!plain.neverLocks)
        #expect(plain.snapshotDirectory == nil)
        #expect(LaunchOptions.parse(["FaceLock", "--dry-run"]).neverLocks)
    }

    @Test("a demo run never touches the real enrollment, log or key")
    func demoPaths() {
        let p = AppPaths.resolve(LaunchOptions.parse(["FaceLock", "--demo-camera", "/tmp/a.jpg"]))
        #expect(p.enrollment != EnrollmentStore.defaultURL)
        #expect(p.log != TelemetryLog.defaultURL)
        #expect(p.key == .memory)
        let real = AppPaths.resolve(LaunchOptions.parse(["FaceLock"]))
        #expect(real == AppPaths.standard)
        let dry = AppPaths.resolve(LaunchOptions.parse(["FaceLock", "--dry-run"]))
        #expect(dry.enrollment == AppPaths.standard.enrollment)
        #expect(dry.log != AppPaths.standard.log)
        #expect(AppPaths.release.enrollment == EnrollmentStore.defaultURL)
        #expect(AppPaths.release.key == .keychain(account: KeychainKeyStore.defaultAccount))
    }

    @Test("a DEBUG build keeps its enrollment and its file key out of the release folder")
    func debugPaths() {
        #expect(AppPaths.debug.enrollment.deletingLastPathComponent() != EnrollmentStore.defaultURL.deletingLastPathComponent())
        #expect(AppPaths.debug.log.deletingLastPathComponent() != TelemetryLog.defaultURL.deletingLastPathComponent())
        guard case let .file(key) = AppPaths.debug.key else { return #expect(Bool(false)) }
        #expect(key.deletingLastPathComponent() == AppPaths.debug.enrollment.deletingLastPathComponent())
        #expect(AppPaths.isDebugBuild ? AppPaths.standard == AppPaths.debug : AppPaths.standard == AppPaths.release)
    }

    @Test("a --data-dir run has a key of its own: deleting its data leaves the default key in place")
    func dataDirKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fl-datadir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = AppPaths.resolve(LaunchOptions.parse(["FaceLock", "--data-dir", root.appendingPathComponent("run").path]))
        #expect(p.key != AppPaths.standard.key)
        #expect(p.key != AppPaths.release.key)
        #expect(KeychainKeyStore.account(forDataDirectory: root) != KeychainKeyStore.defaultAccount)
        // The same check end to end with file keys: the run's delete removes only its own key.
        let standardKey = FileKeyStore(url: root.appendingPathComponent("standard/dev.key"))
        try standardKey.saveKey(SymmetricKey(size: .bits256))
        let run = EnrollmentStore(url: p.enrollment, keys: AppPaths.isDebugBuild ? p.makeKeyStore()
                                    : FileKeyStore(url: root.appendingPathComponent("run/dev.key")))
        try run.save(EnrollmentPayload(templates: [], thresholds: .uncalibrated, calibration: nil))
        try run.delete()
        #expect(try standardKey.loadKey() != nil)
    }

    @Test("status splits into a headline and a detail, with the next check while watching")
    func statusText() {
        #expect(StatusText.split("Not protecting: camera access is off") == ("Not protecting", "Camera access is off"))
        #expect(StatusText.split("Watching. You were here 12 s ago") == ("Watching", "You were here 12 s ago"))
        #expect(StatusText.split("Locking in 7 s") == ("Locking in 7 s", nil))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var s = WatcherState()
        s.lastOwnerSeen = now.addingTimeInterval(-4)
        s.nextCheckAt = now.addingTimeInterval(26)
        let t = StatusText.make(s, line: s.status(now: now), now: now)
        #expect(t.pill == "Watching")
        #expect(t.headline == "Watching")
        #expect(t.detail == "You were here 4 s ago. Next check in 26 s.")
    }

    @Test("pause choices map to the engine's pauses")
    func pauses() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PauseChoice.fifteenMinutes.pause(from: now) == .until(now.addingTimeInterval(900)))
        #expect(PauseChoice.oneHour.pause(from: now) == .until(now.addingTimeInterval(3600)))
        #expect(PauseChoice.untilUnlock.pause(from: now) == .untilUnlock)
        guard case let .until(end) = PauseChoice.untilTomorrow.pause(from: now) else { return #expect(Bool(false)) }
        #expect(end > now && end <= now.addingTimeInterval(86_400))
        #expect(Calendar.current.component(.hour, from: end) == Pause.morningHour)
    }

    @Test("a pause into tomorrow says so")
    func pauseText() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 6))!
        var s = WatcherState()
        s.pause = .until(morning)
        #expect(s.status(now: now).text.hasPrefix("Paused until tomorrow, "))
        s.pause = .until(now.addingTimeInterval(3600))
        #expect(!s.status(now: now).text.contains("tomorrow"))
    }

    @Test("countdown copy never promises that moving the mouse keeps the Mac unlocked")
    func countdownCopy() {
        #expect(CountdownCopy.detail(.away) == "Look at the camera to stay unlocked. Moving the mouse gives FaceLock one more look.")
        #expect(CountdownCopy.announcement(.away, seconds: 10) == "FaceLock is locking your Mac in 10 seconds. Look at the camera to stay unlocked.")
        #expect(!CountdownCopy.announcement(.away, seconds: 10).contains("mouse"))
    }

    @Test("pose labels use one name per look, and the glasses hint says what to do")
    func poseLabels() {
        #expect(EnrollmentTarget.farther.label == "Farther")
        #expect(EnrollmentTarget.leaningBack.label == "Lean back")
        #expect(EnrollmentTarget.label(forStored: "leaning_back") == "Lean back")
        #expect(EnrollmentTarget.label(forStored: "teach") == "Taught look")
        #expect(EnrollmentTarget.glasses.title.hasPrefix("Take your glasses off"))
        #expect(EnrollmentModel.announcement(done: .centre, next: .left) == "Centre done. Next: turn a little to your left.")
        #expect(EnrollmentModel.announcement(done: .glasses, next: nil) == "All looks captured. Save My Face is ready.")
    }

    @Test("Add today's light shows half a day after a single-session enrollment, until done")
    func dayTwo() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let e = [Float](repeating: 0, count: 511) + [1]
        let one = EnrollmentPayload(templates: [Template(embedding: e, pool: .anchor, capturedAt: start, session: 0, target: "centre",
                                                         sharpness: 1)],
                                    thresholds: .uncalibrated, calibration: nil, createdAt: start)
        #expect(!DayTwo.shouldOffer(one, now: start.addingTimeInterval(3600), dismissed: false))
        #expect(DayTwo.shouldOffer(one, now: start.addingTimeInterval(13 * 3600), dismissed: false))
        #expect(!DayTwo.shouldOffer(one, now: start.addingTimeInterval(13 * 3600), dismissed: true))
        #expect(DayTwo.nextSession(one.gallery) == 1)
    }

    @Test("only a script launcher counts as the old app, never a real one or the running app")
    func legacyLauncher() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fl-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, _ bytes: Data) throws -> URL {
            let a = dir.appendingPathComponent("\(name).app")
            let macOS = a.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try bytes.write(to: macOS.appendingPathComponent("FaceLock"))
            return a
        }
        let old = try app("Old", Data("#!/bin/zsh\nexec python -m facelock\n".utf8))
        let new = try app("New", Data([0xCF, 0xFA, 0xED, 0xFE]))
        #expect(LegacyCheck.isOldLauncher(old, running: new))
        #expect(!LegacyCheck.isOldLauncher(new, running: old))
        #expect(!LegacyCheck.isOldLauncher(old, running: old))
    }

    @Test("a reused pid only counts as the old watcher when its arguments name facelock")
    func oldWatcher() {
        #expect(LegacyCheck.namesFaceLock(["/opt/homebrew/bin/python3", "/opt/homebrew/bin/python3", "-m", "facelock", "watch"]))
        #expect(!LegacyCheck.namesFaceLock(["/usr/bin/python3", "/usr/bin/python3", "train.py", "--epochs", "3"]))
        #expect(!LegacyCheck.isOldWatcher(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(!LegacyCheck.arguments(ProcessInfo.processInfo.processIdentifier).isEmpty)
    }

    @Test("quality chips read the runtime gate, and hints say what to change")
    func chips() {
        func frame(_ q: QualityFlags, faces: Int = 1, capture: Float? = 0.6) -> LiveFrame {
            let face = DetectedFace(box: FaceBox(x: 200, y: 120, width: 120, height: 150),
                                    landmarks: Landmarks([Point2D(240, 170), Point2D(300, 170), Point2D(270, 200),
                                                          Point2D(248, 230), Point2D(292, 230)]), score: 0.95)
            let o = FaceObservation(face: face, metrics: QualityGate.metrics(face, frameWidth: 640, frameHeight: 480), quality: q,
                                    score: nil, embedding: nil, faceLuma: q.contains(.dark) ? 20 : 120, sharpness: 50)
            return LiveFrame(observation: FrameObservation(faces: Array(repeating: o, count: faces)), captureQuality: capture,
                             frameLuma: 100, preview: nil, at: Date())
        }
        #expect(EnrollmentFeedback.chips(frame([])).allPass)
        #expect(EnrollmentFeedback.chips(frame([.tooSmall])).distance == false)
        #expect(EnrollmentFeedback.chips(frame([.dark])).light == false)
        #expect(EnrollmentFeedback.chips(frame([], capture: 0.1)).sharp == false)
        #expect(EnrollmentFeedback.chips(frame([.turned])).facing == false)
        #expect(EnrollmentFeedback.chips(frame([], faces: 2)) == Chips())
        #expect(EnrollmentFeedback.hint(faces: 0, chips: Chips(), rejection: nil, target: .centre) == "Move into the frame")
        let ok = EnrollmentFeedback.chips(frame([]))
        #expect(EnrollmentFeedback.hint(faces: 1, chips: ok, rejection: .wrongPose, target: .left) == EnrollmentTarget.left.title)
    }

    @Test("histogram bins are 0.02 wide")
    func bins() {
        let b = ScoreBin.bins([0.71, 0.715, 0.73, 0.95])
        #expect(b.map(\.count) == [2, 1, 1])
        #expect(abs(b[0].lower - 0.70) < 1e-9)
    }

    @Test("menu glyphs are 18 pt template images with a spoken description")
    @MainActor func glyphs() {
        for g in [MenuGlyph.watching, .checking, .lookingForYou(checksLeft: 2), .countdown, .someoneElse, .paused, .notProtecting] {
            let img = Glyphs.image(g)
            #expect(img.isTemplate)
            #expect(img.size == Glyphs.size)
            #expect(img.accessibilityDescription?.hasPrefix("FaceLock") == true)
        }
        #expect(Glyphs.description(.lookingForYou(checksLeft: 1)) == "FaceLock: looking for you, 1 check left")
        #expect(Glyphs.description(.lookingForYou(checksLeft: 2)) == "FaceLock: looking for you, 2 checks left")
    }

    @Test("Settings states the worst case as a ceiling, like the README")
    func graceWording() {
        #expect(CadenceCopy.summary(.balanced, countdownSeconds: 10) == "Checks every 30 s. Locks within 62 s after you leave.")
    }

    @Test("legacy config import maps cadence, sound and notify only")
    func legacyConfig() {
        let c = LegacyConfigImport.parse("interval = 15\nrecheck_interval = 6\nstranger_interval = 2\nconfirm_checks = 2\nsound = true\nthreshold = 0.42\n")
        let s = LegacyConfigImport.settings(from: c)
        #expect(s.cadence == .strict)
        #expect(s.sound)
    }
}
