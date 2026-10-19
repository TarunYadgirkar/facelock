import FaceLockCore
import FaceLockSystem
import SwiftUI

struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Checks") {
                Picker("How often", selection: $model.settings.cadence) {
                    ForEach(CadenceName.allCases, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.title)
                            Text(CadenceCopy.summary(name, countdownSeconds: model.settings.countdownSeconds))
                                .font(Typeface.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(name)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Countdown before locking", selection: $model.settings.countdownSeconds) {
                    ForEach(WatcherSettings.countdownChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $model.settings.slowerOnBattery) {
                    Text("Slower checks on battery")
                    Text("Switches to Relaxed while the Mac runs on battery.")
                }
            }
            Section("Alerts") {
                Toggle(isOn: $model.settings.notify) {
                    Text("Notifications")
                    Text("When someone else is in view or a face stays still. A lock that fails always notifies.")
                }
                Toggle("Play a sound when the countdown starts", isOn: $model.settings.sound)
            }
            Section {
                LoginItemToggle()
            }
        }
    }
}

struct DetectionPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowManager.self) private var windows
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Threshold") {
                if let report = model.payload?.calibration {
                    CalibrationView(report: report, compact: true)
                    ThresholdValues(thresholds: report.thresholds)
                    if let last = model.payload?.thresholdLog.last { Text(changeText(last)).font(Typeface.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Set up FaceLock to see your threshold.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Recalibrate") { run { _ = try model.recalibrate(reason: "recalibrated from Settings") } }
                    Button("Check with Someone Else…") { windows.openSomeoneElse() }
                    Spacer()
                }
                .disabled(!model.isEnrolled)
                if let message { Text(message).font(Typeface.caption).foregroundStyle(.secondary) }
            }
            Section("Your looks") {
                LabeledContent("Taught and enrolled", value: "\(model.payload?.gallery.anchors.count ?? 0) views")
                LabeledContent("Learned while watching", value: "\(model.learnedLooks) of 120")
                Toggle(isOn: $model.settings.adaptation) {
                    Text("Learn small changes in how you look")
                    Text("Only from clear views of you alone, at most 12 a day, and never after a stranger since your last unlock.")
                }
                HStack {
                    Button("Teach a New Look…") { windows.openTeach(.look) }
                    Button("Reset Learned Looks") { run { try model.resetLearnedLooks() } }
                        .disabled(model.learnedLooks == 0)
                    Spacer()
                }
                .disabled(!model.isEnrolled)
            }
            Section("Extra checks") {
                Toggle(isOn: $model.settings.lockWhenSomeoneElseLooks) {
                    Text("Lock when someone else is looking")
                    Text("After another face shows up next to yours in two checks in a row.")
                }
                Picker(selection: $model.settings.stillFace) {
                    Text("Off").tag(StillFaceMode.off)
                    Text("Observe").tag(StillFaceMode.observe)
                    Text("On").tag(StillFaceMode.on)
                } label: {
                    Text("Still-face check")
                    Text("A face that doesn't move for 3 minutes, like a propped-up photo. Observe only logs it; On asks you to turn your head.")
                }
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            message = "Done."
        } catch {
            message = "That didn't work: \(error.localizedDescription)"
        }
    }

    private func changeText(_ c: ThresholdChange) -> String {
        let old = c.old.map { String(format: "%.2f", $0.accept) } ?? "none"
        return "Last change \(c.at.formatted(date: .abbreviated, time: .shortened)): \(old) to "
            + "\(String(format: "%.2f", c.new.accept)), \(c.reason)."
    }
}

struct ThresholdValues: View {
    let thresholds: Thresholds

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
            row("Accept at (T)", thresholds.accept, "Your calibrated threshold")
            row("Floor (F)", thresholds.floor, "Never below this, from the benchmark")
            row("Stranger (S)", thresholds.stranger, "At or below this, a clear face is a stranger")
        }
        .font(Typeface.body)
    }

    private func row(_ name: String, _ value: Float, _ note: String) -> some View {
        GridRow {
            Text(name)
            Text(String(format: "%.2f", value)).font(Typeface.data).monospacedDigit()
            Text(note).font(Typeface.caption).foregroundStyle(.secondary)
        }
    }
}

struct PrivacyPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmLog = false
    @State private var confirmAll = false
    @State private var message: String?
    @State private var summary: TelemetrySummary?

    var body: some View {
        Form {
            Section("What FaceLock stores") {
                StoredRow(title: "Face templates", detail: "Encrypted with a key in your login keychain. Numbers, not pictures.",
                          path: EnrollmentStore.defaultURL.path)
                StoredRow(title: "Check log", detail: "One line per check: camera time, scores and the verdict. No images.",
                          path: TelemetryLog.defaultURL.path)
                Text(model.options.isDemo || model.options.dataDirectory != nil
                     ? "This run keeps its files in a separate folder instead, and no camera frame is ever saved."
                     : "No camera frame is ever saved, and nothing leaves this Mac.")
                    .font(Typeface.caption).foregroundStyle(.secondary)
            }
            Section("Last 7 days") {
                if let summary {
                    LabeledContent("Locks", value: summary.text.replacingOccurrences(of: "Locks: ", with: ""))
                    LabeledContent("Checks", value: "\(summary.checks)")
                    LabeledContent("Camera on per check while you're here",
                                   value: summary.medianPresentOnTime.map { String(format: "%.2f s median", $0) } ?? "No checks yet")
                }
            }
            Section {
                HStack {
                    Button("Show Log in Finder") { model.showLog() }
                    Button("Delete Log…", role: .destructive) { confirmLog = true }
                    Spacer()
                    Button("Delete All FaceLock Data…", role: .destructive) { confirmAll = true }
                }
                if let message { Text(message).font(Typeface.caption).foregroundStyle(.secondary) }
            }
        }
        .task { summary = model.telemetry.weeklySummary() }
        .confirmationDialog("Move the check log to the Trash?", isPresented: $confirmLog) {
            Button("Move to Trash", role: .destructive) { act { try model.deleteLog() } }
        }
        .confirmationDialog("Delete all FaceLock data?", isPresented: $confirmAll) {
            Button("Delete and Stop Watching", role: .destructive) { act { try model.deleteAllData() } }
        } message: {
            Text("Your face templates and the log go to the Trash and the key leaves the keychain. FaceLock stops protecting until you set it up again.")
        }
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            message = "Moved to the Trash."
            summary = model.telemetry.weeklySummary()
        } catch {
            message = "That didn't work: \(error.localizedDescription)"
        }
    }
}

private struct StoredRow: View {
    let title: String
    let detail: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(Typeface.caption).foregroundStyle(.secondary)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(Typeface.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}
