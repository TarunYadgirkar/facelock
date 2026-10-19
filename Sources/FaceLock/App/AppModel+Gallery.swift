import AppKit
import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import FaceLockVision

/// Enrollment, calibration and the template pools. T, F and S live only in the enrollment store,
/// and every change of them is logged with the old and new values.
extension AppModel {
    @discardableResult
    func completeEnrollment(_ templates: [Template]) throws -> CalibrationReport {
        let report = Calibrator.calibrate(Gallery(templates))
        let p = EnrollmentPayload(templates: templates, thresholds: report.thresholds, calibration: report,
                                  thresholdLog: [Calibrator.change(from: nil, to: report, reason: "enrollment")])
        try persist(p)
        return report
    }

    func persist(_ p: EnrollmentPayload) throws {
        try store.save(p)
        payload = p
        storeLoad = .loaded(p)
        controller.update(recognition: p.recognition)
        refreshBlock()
    }

    /// Recomputes T from the anchors, keeping a "Check with someone else" raise if there was one.
    @discardableResult
    func recalibrate(reason: String, gallery: Gallery? = nil) throws -> CalibrationReport? {
        guard var p = payload else { return nil }
        let g = gallery ?? p.gallery
        var report = Calibrator.calibrate(g)
        if let other = p.calibration?.someoneElseMax { report = Calibrator.adjusting(report, someoneElseMax: other) }
        if report.thresholds != p.thresholds {
            p.thresholdLog.append(Calibrator.change(from: p.thresholds, to: report, reason: reason))
        }
        p.templates = g.templates
        p.thresholds = report.thresholds
        p.calibration = report
        try persist(p)
        return report
    }

    @discardableResult
    func applySomeoneElse(maxScore: Float) throws -> CalibrationReport? {
        guard var p = payload, let base = p.calibration else { return nil }
        let report = Calibrator.adjusting(base, someoneElseMax: maxScore)
        if report.thresholds != p.thresholds {
            p.thresholdLog.append(Calibrator.change(from: p.thresholds, to: report, reason: "check with someone else"))
        }
        p.thresholds = report.thresholds
        p.calibration = report
        try persist(p)
        return report
    }

    /// Teach a new look, or Add today's light: anchors change only through this explicit action.
    func finishTeach(_ session: TeachSession) throws -> TeachOutcome {
        guard let p = payload else { return .nothingCaptured }
        let (gallery, outcome) = session.finish(into: p.gallery, thresholds: p.thresholds)
        if case .added = outcome { try recalibrate(reason: session.target == "light" ? "added today's light" : "taught a new look",
                                                   gallery: gallery) }
        return outcome
    }

    func galleryAdapted(_ g: Gallery) {
        _ = try? recalibrate(reason: "adaptation", gallery: g)
    }

    func resetLearnedLooks() throws {
        guard let p = payload else { return }
        try recalibrate(reason: "reset learned looks", gallery: Adaptation.resetting(p.gallery))
    }

    var learnedLooks: Int { payload?.gallery.adaptive.count ?? 0 }

    /// Moves the enrollment and the log to the Trash and forgets the key.
    func deleteAllData() throws {
        let fm = FileManager.default
        for url in [paths.enrollment, paths.log] + telemetry.rotatedFiles() where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
        try store.delete()
        payload = nil
        storeLoad = .empty
        controller.update(recognition: RecognitionContext(gallery: Gallery(), thresholds: .uncalibrated))
        refreshBlock()
    }

    func deleteLog() throws {
        let fm = FileManager.default
        for url in [paths.log] + telemetry.rotatedFiles() where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func showLog() {
        guard FileManager.default.fileExists(atPath: paths.log.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.log])
    }

    // MARK: setup screens

    /// A camera for a setup screen, separate from the watcher's: the demo's jittering photo, or a
    /// new session on the real camera that is released when the screen closes.
    func makeSetupSource() throws -> FrameSource {
        if let url = options.demoCamera { return JitterCamera(renderer: try DemoRenderer(url: url), scene: demoScene) }
        return try CameraSession()
    }

    func makeSetupPipeline() async throws -> FacePipeline {
        try await Task.detached(priority: .userInitiated) { try FacePipeline() }.value
    }

    // MARK: demo

    /// `--demo-enrolled` enrolls the stored photo; `--demo-leave-after` empties the scene later.
    func prepareDemo() async {
        if options.demoEnrolled { await enrollDemoFace() }
        if let after = options.demoLeaveAfter {
            try? await Task.sleep(for: .seconds(after))
            setDemoPresent(false)
        }
    }

    /// Enrolls the demo photo the way onboarding would, from jittered views of it.
    func enrollDemoFace() async {
        guard payload == nil, let url = options.demoCamera else { return }
        let templates = await Task.detached(priority: .userInitiated) { () -> [Template] in
            guard let r = try? DemoRenderer(url: url), let p = try? FacePipeline() else { return [] }
            return DemoEnrollment.make(renderer: r, pipeline: p)
        }.value
        if !templates.isEmpty { _ = try? completeEnrollment(templates) }
    }

    func setDemoPresent(_ present: Bool) {
        demoScene.set(present: present)
        demoPresent = present
        note(present ? "Demo: the photo is back in front of the camera." : "Demo: the photo left the camera.")
    }
}
