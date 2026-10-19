import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import FaceLockVision
import SwiftUI

/// "Measure camera timing": 20 checks run inside the app, so the camera permission is FaceLock's.
/// Only medians and p95 are kept.
@MainActor @Observable
final class CameraTimingModel {
    static let checks = 20
    var done = 0
    var running = false
    var report: CameraTimingReport?
    var open: (median: Double, p95: Double)?
    var error: String?

    func measure(app: AppModel) async {
        guard !running else { return }
        running = true
        done = 0
        error = nil
        let hold = app.beginSetup()
        defer {
            running = false
            hold.end()
        }
        do {
            let source: FrameSource = try app.options.demoCamera.map { try StoredImageCamera(image: $0) } ?? CameraSession()
            let runner = CheckRunner(source: source, pipeline: try await app.makeSetupPipeline())
            let recognition = app.payload?.recognition ?? RecognitionContext(gallery: Gallery(), thresholds: .uncalibrated)
            var timings: [WindowTiming] = []
            var opens: [Double] = []
            for i in 0..<Self.checks {
                let summary = await withCheckedContinuation { (c: CheckedContinuation<WindowSummary, Never>) in
                    runner.startWindow(id: i, kind: .manual, policy: .regular, recognition: recognition) { _, s in c.resume(returning: s) }
                }
                timings.append(summary.timing)
                if let o = (source as? CameraSession)?.lastOpenSeconds { opens.append(o) }
                done = i + 1
                try await Task.sleep(for: .seconds(1))
            }
            report = CameraTimingReport(timings)
            open = opens.isEmpty ? nil : (Stats.median(opens), Stats.quantile(opens, 0.95))
        } catch {
            self.error = "The camera could not start. \(error.localizedDescription)"
        }
    }
}

struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model
    @State private var timing = CameraTimingModel()

    var body: some View {
        Form {
            Section("Where the models run") {
                LabeledContent("Face detector (YuNet)", value: planLabel(.detector))
                LabeledContent("Recognizer (ArcFace r50)", value: planLabel(.recognizer))
            }
            Section("Locking") {
                LabeledContent("Lock call", value: LockAPI.symbolResolves ? "Found" : "Missing")
                Text(LockAPI.symbolResolves
                     ? "Checked without calling it. If a lock ever fails, FaceLock puts the display to sleep, which locks only when "
                        + "a password is required immediately after sleep."
                     : "FaceLock will put the display to sleep instead, which locks only when a password is required immediately after sleep.")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                if model.options.neverLocks {
                    Text("This is a dry run: FaceLock logs the lock instead of locking.")
                        .font(Typeface.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            Section("Camera timing") {
                Text("Runs \(CameraTimingModel.checks) checks, one a second, and shows how long the camera stayed on.")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(timing.running ? "Measuring…" : "Measure Camera Timing") { Task { await timing.measure(app: model) } }
                        .disabled(timing.running || model.engine != .ready)
                    if timing.running {
                        ProgressView(value: Double(timing.done), total: Double(CameraTimingModel.checks)).frame(width: 120)
                        Text("\(timing.done) of \(CameraTimingModel.checks)").font(Typeface.caption).monospacedDigit()
                    }
                }
                if let r = timing.report { TimingTable(report: r, open: timing.open) }
                if let e = timing.error { Text(e).font(Typeface.caption).foregroundStyle(Theme.critical) }
            }
        }
    }

    private func planLabel(_ m: ModelName) -> String {
        model.computePlans[m.rawValue]?.label ?? (model.engine == .failed ? "Not loaded" : "Checking…")
    }
}

private struct TimingTable: View {
    let report: CameraTimingReport
    let open: (median: Double, p95: Double)?

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: Space.xl, verticalSpacing: Space.xs) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Median").font(Typeface.caption).foregroundStyle(.secondary)
                Text("p95").font(Typeface.caption).foregroundStyle(.secondary)
            }
            row("Camera start", open)
            row("First frame", report.firstFrame)
            row("Exposure settled", report.settled)
            row("Camera on", report.onTime)
        }
        .font(Typeface.body)
    }

    private func row(_ name: String, _ v: (median: Double, p95: Double)?) -> some View {
        GridRow {
            Text(name).gridColumnAlignment(.leading)
            Text(v.map { String(format: "%.2f s", $0.median) } ?? "n/a").font(Typeface.data)
            Text(v.map { String(format: "%.2f s", $0.p95) } ?? "n/a").font(Typeface.data)
        }
    }
}
