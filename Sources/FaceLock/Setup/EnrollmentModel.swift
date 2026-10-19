import AppKit
import CoreGraphics
import FaceLockCapture
import FaceLockCore
import FaceLockVision
import Foundation

/// The four live checks under the preview. nil means there is no single face to judge yet.
struct Chips: Equatable, Sendable {
    var distance: Bool?
    var light: Bool?
    var sharp: Bool?
    var facing: Bool?

    var allPass: Bool { [distance, light, sharp, facing].allSatisfy { $0 == true } }
}

enum EnrollmentFeedback {
    /// Vision's capture quality below this reads as "not sharp" (provisional, enrollment only).
    static let minCaptureQuality: Float = 0.3

    static func chips(_ f: LiveFrame) -> Chips {
        guard f.observation.faces.count == 1, let face = f.observation.faces.first else { return Chips() }
        let q = face.quality
        let light = face.faceLuma.map { $0 >= QualityThresholds.standard.minFaceLuma } ?? (f.frameLuma >= 40)
        let sharp = f.captureQuality.map { $0 >= minCaptureQuality } ?? !q.contains(.blurry)
        return Chips(distance: !q.contains(.tooSmall) && !q.contains(.cutOff), light: light, sharp: sharp,
                     facing: !q.contains(.turned) && !q.contains(.tilted))
    }

    static func hint(faces: Int, chips: Chips, rejection: EnrollmentRejection?, target: EnrollmentTarget) -> String {
        if faces == 0 { return "Move into the frame" }
        if faces > 1 { return "Only you in the frame, please" }
        if chips.distance == false { return "Sit about an arm's length away, all of your face in view" }
        if chips.light == false { return "Find more light on your face" }
        if chips.sharp == false { return "Hold still for a moment" }
        if chips.facing == false, target == .centre { return "Face the camera" }
        switch rejection {
        case .wrongPose?: return target.title
        case .notNovel?: return "Move a little so FaceLock sees a new angle"
        case nil, .tooSoon?: return "Hold that"
        default: return target.title
        }
    }
}

/// Onboarding capture: drives `EnrollmentSession` from the live camera at the user's pace.
@MainActor @Observable
final class EnrollmentModel {
    enum Phase: Equatable { case idle, starting, capturing, complete, failed(String) }

    var phase: Phase = .idle
    var session = EnrollmentSession(session: 0)
    var chips = Chips()
    var hint = EnrollmentTarget.centre.title
    var preview: CGImage?
    /// The real camera's session, for the mirrored preview layer.
    @ObservationIgnored private(set) var cameraSession: CameraSession?
    @ObservationIgnored private var capture: LiveCapture?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var hold: SetupHold?

    var currentTarget: EnrollmentTarget? { session.currentTarget }
    var acceptedCount: Int { session.templates.count }

    func start(app: AppModel) async {
        guard phase == .idle || phase.isFailure else { return }
        self.app = app
        phase = .starting
        hold = app.beginSetup()
        do {
            let source = try app.makeSetupSource()
            cameraSession = source as? CameraSession
            let pipeline = try await app.makeSetupPipeline()
            let c = LiveCapture(source: source, pipeline: pipeline, recognition: nil, measureCaptureQuality: true)
            capture = c
            phase = .capturing
            c.start { [weak self] frame in Task { @MainActor in self?.handle(frame) } }
        } catch {
            phase = .failed("The camera could not start. \(error.localizedDescription)")
            releaseCamera()
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        cameraSession = nil
        if phase == .capturing || phase == .starting { phase = .idle }
        releaseCamera()
    }

    private func releaseCamera() {
        hold?.end()
        hold = nil
    }

    func skipCurrent() {
        guard let t = currentTarget, t.isSkippable else { return }
        session = session.skipping(t)
        if session.isComplete { finish() }
    }

    /// VoiceOver hears each look complete and what comes next, since the ring is only drawn.
    nonisolated static func announcement(done: EnrollmentTarget, next: EnrollmentTarget?) -> String {
        guard let next else { return "All looks captured. Save My Face is ready." }
        return "\(done.label) done. Next: \(next.title.prefix(1).lowercased() + next.title.dropFirst())."
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func handle(_ frame: LiveFrame) {
        guard phase == .capturing, let target = currentTarget else { return }
        if let img = frame.preview { preview = img }
        let c = EnrollmentFeedback.chips(frame)
        chips = c
        var rejection: EnrollmentRejection?
        if c.allPass {
            let (next, r) = session.offering(frame.observation, for: target, at: frame.at)
            session = next
            rejection = r
        }
        let now = currentTarget ?? target
        hint = now != target ? now.title
            : EnrollmentFeedback.hint(faces: frame.observation.faces.count, chips: c, rejection: rejection, target: now)
        if currentTarget != target { announce(Self.announcement(done: target, next: currentTarget)) }
        if session.isComplete { finish() }
    }

    private func finish() {
        capture?.stop()
        capture = nil
        phase = .complete
    }
}

extension EnrollmentModel.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
