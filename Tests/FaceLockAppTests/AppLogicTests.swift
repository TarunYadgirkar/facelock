import FaceLockCore
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

    @Test("a demo run never touches the real enrollment or log")
    func demoPaths() {
        let p = AppPaths.resolve(LaunchOptions.parse(["FaceLock", "--demo-camera", "/tmp/a.jpg"]))
        #expect(p.enrollment != EnrollmentStore.defaultURL)
        #expect(p.log != TelemetryLog.defaultURL)
        let real = AppPaths.resolve(LaunchOptions.parse(["FaceLock"]))
        #expect(real.enrollment == EnrollmentStore.defaultURL)
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
        #expect(t.pill == "Protected")
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
    }

    @Test("legacy config import maps cadence, sound and notify only")
    func legacyConfig() {
        let c = LegacyConfigImport.parse("interval = 15\nrecheck_interval = 6\nstranger_interval = 2\nconfirm_checks = 2\nsound = true\nthreshold = 0.42\n")
        let s = LegacyConfigImport.settings(from: c)
        #expect(s.cadence == .strict)
        #expect(s.sound)
    }
}
