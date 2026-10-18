import FaceLockCore
import Foundation
import Testing

final class ScriptedChecks: CheckPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [WindowSummary]
    private(set) var started: [CheckKind] = []

    init(_ script: [WindowSummary]) {
        self.script = script
    }

    func startWindow(id: Int, kind: CheckKind, policy: WindowPolicy, recognition: RecognitionContext,
                     completion: @escaping @Sendable (Int, WindowSummary) -> Void) {
        let next: WindowSummary? = lock.withLock {
            started.append(kind)
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let next { DispatchQueue.global().async { completion(id, next) } }
    }

    func abortWindow() {}
}

final class RecordingEnvironment: WatchEnvironment, @unchecked Sendable {
    let idle: TimeInterval?
    init(idle: TimeInterval?) { self.idle = idle }
    func lock(completion: @escaping @Sendable (LockOutcome) -> Void) { completion(.locked) }
    func secondsSinceInput() -> TimeInterval? { idle }
    func notify(_ notice: Notice) {}
    func showCountdown(endsAt: Date, reason: CountdownReason) {}
    func hideCountdown() {}
    func startInputMonitor(onInput: @escaping @Sendable () -> Void) {}
    func stopInputMonitor() {}
}

final class Latest<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.withLock { v = x } }
    var value: T? { lock.withLock { v } }
}

@Suite("Watch controller")
struct ControllerTests {
    @Test("an owner check returns to Watching and, with recent input, adds a novel look to the adaptive pool")
    func ownerAndAdaptation() async throws {
        let base = unit(42)
        let anchors = (0..<5).map { template(vector(near: base, cosine: 0.9, seed: $0), at: Double($0)) }
        let sample = OwnerSample(landmarks: frontalFace().landmarks, boxWidth: 120, embedding: vector(near: base, cosine: 0.85, seed: 77),
                                 score: MatchScore(union: 0.8, anchor: 0.8), faceCount: 1, sharpness: 50)
        let checks = ScriptedChecks([summary(.owner, owner: sample)])
        let c = WatchController(settings: WatcherSettings(), recognition: RecognitionContext(gallery: Gallery(anchors), thresholds: Thresholds(accept: 0.6)),
                                checks: checks, environment: RecordingEnvironment(idle: 2))
        let state = Latest<WatcherState>(), gallery = Latest<Gallery>()
        c.onChange { state.set($0) }
        c.onGalleryChange { gallery.set($0) }
        c.send(.start)
        for _ in 0..<40 where gallery.value == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(state.value?.watchState == .present)
        #expect(state.value?.nextCheckAt != nil)
        #expect(gallery.value?.adaptive.count == 1)
        #expect(c.currentRecognition.gallery.adaptive.count == 1)
    }

    @Test("without recent input nothing is learned")
    func noInputNoAdaptation() async throws {
        let base = unit(43)
        let anchors = (0..<5).map { template(vector(near: base, cosine: 0.9, seed: $0), at: Double($0)) }
        let checks = ScriptedChecks([summary(.owner)])
        let c = WatchController(settings: WatcherSettings(), recognition: RecognitionContext(gallery: Gallery(anchors), thresholds: Thresholds(accept: 0.6)),
                                checks: checks, environment: RecordingEnvironment(idle: nil))
        c.send(.start)
        try await Task.sleep(for: .milliseconds(200))
        #expect(c.currentRecognition.gallery.adaptive.isEmpty)
        #expect(c.snapshot.watchState == .present)
    }
}
