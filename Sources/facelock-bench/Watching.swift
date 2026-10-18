import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import FaceLockVision
import Foundation

/// Telemetry counter for runs whose log nobody keeps.
final class CountingSink: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CheckRecord] = []
    private let echo: Bool

    init(echo: Bool = false) {
        self.echo = echo
    }

    func record(_ r: CheckRecord) {
        lock.withLock { records.append(r) }
        guard echo else { return }
        let parts = [r.event.rawValue, r.kind?.rawValue, r.verdict?.rawValue, r.cancel.map { "cancel=\($0.rawValue)" },
                     r.outcome?.rawValue, r.onTime.map { String(format: "on %.3f s", $0) },
                     r.bestScore.map { String(format: "score %.3f", $0) }, r.frames.map { "frames \($0)" }]
        print("[check] " + parts.compactMap { $0 }.joined(separator: " "))
    }

    var all: [CheckRecord] { lock.withLock { records } }
}

struct WatchRig {
    let controller: WatchController
    let sink: CountingSink
    let environment: DryRunEnvironment
    let camera: StoredImageCamera

    /// The real FaceLockCore watcher and FaceLockCapture runner, in dry run, on the stored-image camera.
    init(image: URL, models: ModelLocator, settings: WatcherSettings = WatcherSettings(), echo: Bool = false) throws {
        let pipeline = try FacePipeline(models: models)
        let owner = try StandInOwner(pipeline: pipeline, frame: try cameraFrame(image))
        camera = try StoredImageCamera(image: image)
        let runner = CheckRunner(source: camera, pipeline: pipeline)
        sink = CountingSink(echo: echo)
        environment = DryRunEnvironment(echo: echo)
        controller = WatchController(settings: settings, recognition: owner.recognition, checks: runner,
                                     environment: environment, telemetry: sink)
    }
}

enum Idle {
    static let warmup: Double = 20

    static func run(image: URL, models: ModelLocator, seconds: Double, state: String) async throws -> [String: Any] {
        guard ["present", "locked"].contains(state) else { throw BenchError("--state is present or locked") }
        let rig = try WatchRig(image: image, models: models)
        if state == "locked" { rig.controller.send(.screenLocked) }
        rig.controller.send(.start)
        try await Task.sleep(for: .seconds(warmup))
        let before = rig.sink.all.count
        let u0 = Usage.now()
        try await Task.sleep(for: .seconds(seconds))
        let d = Usage.now().since(u0)
        let checks = rig.sink.all.dropFirst(before).filter { $0.event == .check }
        let on = checks.compactMap(\.onTime)
        return ["state": state, "seconds": seconds, "cadence": rig.controller.snapshot.cadence.name.rawValue,
                "cpu_percent_of_core": rounded(100 * d.cpuMs / (seconds * 1000), 4),
                "cpu_j_per_hour": rounded(d.energyMJ / 1000 * 3600 / seconds, 2),
                "checks": checks.count, "verdicts": Dictionary(grouping: checks.compactMap { $0.verdict?.rawValue }) { $0 }.mapValues(\.count),
                "camera_on_s": summary(on).mapValues { rounded($0, 3) },
                "footprint_mb": rounded(Usage.now().footprintMB, 1), "peak_footprint_mb": rounded(Usage.now().peakFootprintMB, 1)]
    }
}

/// Watches the stored image in dry run and prints every check and state change. With
/// `leaveAfter`, the scene empties after that many seconds and the run walks through rechecks,
/// the countdown and a would-be lock.
enum DryRun {
    static func run(image: URL, models: ModelLocator, seconds: Double, leaveAfter: Double?) async throws {
        let rig = try WatchRig(image: image, models: models, echo: true)
        let start = Date()
        rig.controller.onChange { s in
            print(String(format: "[state %6.1f s] ", Date().timeIntervalSince(start)) + "\(s.watchState.rawValue): \(s.status(now: Date()).text)")
        }
        rig.controller.send(.start)
        if let leaveAfter {
            try await Task.sleep(for: .seconds(leaveAfter))
            try rig.camera.show(nil)
            print(String(format: "[scene  %6.1f s] the owner leaves", Date().timeIntervalSince(start)))
            try await Task.sleep(for: .seconds(max(0, seconds - leaveAfter)))
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
    }
}
