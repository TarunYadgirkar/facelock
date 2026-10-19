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
                NotificationAccessRow()
                Toggle("Play a sound when the countdown starts", isOn: $model.settings.sound)
            }
            Section {
                LoginItemToggle()
            }
        }
        .task { await model.refreshNotificationAccess() }
    }
}

/// What macOS allows, under the Notifications toggle: a lock failure can only reach you when
/// FaceLock may post.
struct NotificationAccessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.notificationAccess {
        case .denied:
            HStack(spacing: Space.s) {
                Text("Notifications are off for FaceLock, so a failed lock can't reach you.")
                    .font(Typeface.caption).foregroundStyle(Theme.warning)
                Button("Open Notification Settings") { Notifier.openSettings() }
                    .buttonStyle(.link).font(Typeface.caption)
            }
        case .notDetermined:
            HStack(spacing: Space.s) {
                Text("FaceLock hasn't asked to post notifications yet.").font(Typeface.caption).foregroundStyle(.secondary)
                Button("Allow Notifications") { Task { await model.requestNotifications() } }
                    .buttonStyle(.link).font(Typeface.caption)
            }
        case .allowed, .unavailable:
            EmptyView()
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
            row("Your threshold", thresholds.accept, "A match at or above this is you")
            row("Lowest allowed", thresholds.floor, "Your threshold never goes below this, from the benchmark")
            row("Clearly someone else", thresholds.stranger, "A clear face at or below this is a stranger")
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
                StoredRow(title: "Face templates", detail: keyText, path: model.paths.enrollment.path)
                StoredRow(title: "Check log", detail: "One line per check: camera time, scores and the verdict. No images. Kept 30 days.",
                          path: model.paths.log.path)
                Text(model.paths.isRelease
                     ? "No camera frame is ever saved, and nothing leaves this Mac."
                     : "This run keeps its files in its own folder, shown above, and no camera frame is ever saved.")
                    .font(Typeface.caption).foregroundStyle(.secondary)
            }
            Section("Last 7 days") {
                if let summary {
                    LabeledContent("Locks", value: "\(summary.locks)")
                    LabeledContent("Countdowns you stopped", value: "\(summary.countdownsStopped)")
                    if summary.failedLocks > 0 {
                        LabeledContent {
                            Text("\(summary.failedLocks)").foregroundStyle(Theme.warning)
                        } label: {
                            Text("Locks that failed").foregroundStyle(Theme.warning)
                        }
                    }
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

    private var keyText: String {
        switch model.paths.key {
        case .memory: return "Encrypted with a key that lives only in memory for this run. Numbers, not pictures."
        case .file: return "Encrypted with a key in a file in the same folder (a development or test run). Numbers, not pictures."
        case .keychain: return "Encrypted with a key in your login keychain, which FaceLock reads without a prompt while you're "
            + "logged in. Numbers, not pictures. Time Machine skips this file."
        }
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            message = "Moved to the Trash. Empty the Trash to remove it for good."
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
