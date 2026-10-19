import CoreGraphics
import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import Foundation

/// A fixed-length capture on a setup screen: the camera runs for `seconds`, every analysed frame
/// goes to `onFrame`, and the progress ring follows the clock.
@MainActor
final class TimedCapture {
    private var capture: LiveCapture?
    private(set) var cameraSession: CameraSession?

    func run(app: AppModel, seconds: TimeInterval, recognition: RecognitionContext?,
             progress: @escaping @MainActor (Double) -> Void,
             onFrame: @escaping @MainActor @Sendable (LiveFrame) -> Void) async throws {
        app.beginSetup()
        defer {
            capture?.stop()
            capture = nil
            cameraSession = nil
            app.endSetup()
        }
        let source = try app.makeSetupSource()
        cameraSession = source as? CameraSession
        let pipeline = try await app.makeSetupPipeline()
        let c = LiveCapture(source: source, pipeline: pipeline, recognition: recognition, measureCaptureQuality: false)
        capture = c
        c.start { frame in Task { @MainActor in onFrame(frame) } }
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            progress(Date().timeIntervalSince(start) / seconds)
            try await Task.sleep(for: .milliseconds(100))
        }
        progress(1)
    }
}

/// "Check with someone else": a second person in front of the camera for 10 s. Only their best
/// score is kept, in memory.
@MainActor @Observable
final class SomeoneElseModel {
    enum Phase: Equatable { case intro, capturing, done(raised: Bool, best: Float?), failed(String) }

    var phase: Phase = .intro
    var progress = 0.0
    var preview: CGImage?
    var faces = 0
    @ObservationIgnored private let runner = TimedCapture()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var check = SomeoneElseCheck()

    init(app: AppModel) {
        self.app = app
    }

    var cameraSession: CameraSession? { runner.cameraSession }

    func start() async {
        guard let app, let recognition = app.payload?.recognition else { return }
        check = SomeoneElseCheck()
        phase = .capturing
        do {
            try await runner.run(app: app, seconds: SomeoneElseCheck.seconds, recognition: recognition,
                                 progress: { [weak self] in self?.progress = $0 },
                                 onFrame: { [weak self] f in self?.offer(f) })
            let best = check.maxScore
            let report = try best.flatMap { try app.applySomeoneElse(maxScore: $0) }
            phase = .done(raised: report?.raisedForSomeoneElse ?? false, best: best)
        } catch {
            phase = .failed("The camera could not start. \(error.localizedDescription)")
        }
    }

    private func offer(_ f: LiveFrame) {
        check = check.offering(f.observation)
        faces = f.observation.faces.count
        if let img = f.preview { preview = img }
    }

    var resultText: String {
        guard case let .done(raised, best) = phase else { return "" }
        guard let best else { return "FaceLock didn't see anyone. Try again with them in front of the camera." }
        let t = String(format: "%.2f", app?.payload?.thresholds.accept ?? 0)
        let b = String(format: "%.2f", best)
        return raised
            ? "Their best score was \(b), close to yours, so FaceLock raised your threshold to \(t)."
            : "Their best score was \(b), well below your threshold of \(t). Nothing changed."
    }
}

/// Teach a new look, or Add today's light: Touch ID or the password first, then a short capture
/// that may include looks scoring below T. A look that scores like a different person is refused.
@MainActor @Observable
final class TeachModel {
    enum Phase: Equatable { case intro, authenticating, capturing, done(TeachOutcome), failed(String) }

    let mode: TeachMode
    var phase: Phase = .intro
    var progress = 0.0
    var preview: CGImage?
    var captured = 0
    @ObservationIgnored private let runner = TimedCapture()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var session: TeachSession?
    @ObservationIgnored private var sessionNumber = 0

    init(app: AppModel, mode: TeachMode) {
        self.app = app
        self.mode = mode
    }

    var cameraSession: CameraSession? { runner.cameraSession }
    var seconds: TimeInterval { mode == .look ? TeachSession.seconds : TeachSession.lightSeconds }

    func start() async {
        guard let app, let p = app.payload else { return }
        phase = .authenticating
        if !app.options.isDemo {
            let reason = mode == .look ? "teach FaceLock a new look" : "add today's light to FaceLock"
            guard await OwnerAuthentication.confirm(reason: reason) else {
                phase = .failed("FaceLock needs your Touch ID or password before it learns a look.")
                return
            }
        }
        session = TeachSession(startedAt: Date(), duration: seconds, target: mode == .look ? "teach" : "light")
        sessionNumber = DayTwo.nextSession(p.gallery)
        phase = .capturing
        do {
            try await runner.run(app: app, seconds: seconds, recognition: p.recognition,
                                 progress: { [weak self] in self?.progress = $0 },
                                 onFrame: { [weak self] f in self?.offer(f) })
            guard let session else { return }
            phase = .done(try app.finishTeach(session))
            if mode == .light { app.prefs.lightPromptDismissed = true }
        } catch {
            phase = .failed("The camera could not start. \(error.localizedDescription)")
        }
    }

    private func offer(_ f: LiveFrame) {
        session = session?.offering(f.observation, at: f.at, session: sessionNumber)
        captured = session?.captured.count ?? 0
        if let img = f.preview { preview = img }
    }

    var resultText: String {
        guard case let .done(outcome) = phase else { return "" }
        switch outcome {
        case let .added(n): return "Added \(n) views. FaceLock recalibrated with them."
        case .differentPerson: return "That looked like a different person, so FaceLock kept your looks as they were."
        case .nothingCaptured: return "FaceLock didn't get a clear view. Sit in front of the camera with good light and try again."
        }
    }
}
