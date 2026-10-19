import FaceLockCore
import FaceLockSystem
import SwiftUI

struct SetupView: View {
    @Bindable var flow: SetupFlow
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SetupRail(flow: flow)
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(Space.xxl)
        }
        .frame(width: 880, height: 600)
        .onAppear { flow.model.refreshCameraAccess() }
        .onDisappear { flow.close() }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .welcome: WelcomeStep(flow: flow)
        case .before: BeforeStep(flow: flow)
        case .camera: CameraStep(flow: flow)
        case .face: FaceStep(flow: flow)
        case .result: ResultStep(flow: flow)
        case .someoneElse: SomeoneElseStep(flow: flow)
        case .finish: FinishStep(flow: flow, onClose: onClose)
        }
    }
}

/// The real sequence, numbered, with where you are.
private struct SetupRail: View {
    let flow: SetupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.s) {
                FaceLockMark().frame(width: 22, height: 22)
                Text("FaceLock").font(Typeface.title)
            }
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(Array(flow.steps.enumerated()), id: \.element) { i, s in
                    HStack(spacing: Space.s) {
                        ZStack {
                            Circle().fill(s == flow.step ? Theme.accent : flow.isDone(s) ? Theme.good.opacity(0.18) : Theme.track)
                            if flow.isDone(s) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.good)
                            } else {
                                Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(s == flow.step ? Theme.onAccent : .secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(s.title)
                            .font(s == flow.step ? Typeface.bodyEmphasis : Typeface.body)
                            .foregroundStyle(s == flow.step ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(i + 1), \(s.title)\(s == flow.step ? ", current" : flow.isDone(s) ? ", done" : "")")
                }
            }
            Spacer()
        }
        .padding(Space.xl)
        .frame(width: 196, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
    }
}

/// The FaceLock mark: viewfinder corners around a filled centre, as in the menu bar.
struct FaceLockMark: View {
    var body: some View {
        ZStack {
            ViewfinderCorners(arm: 6)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }
}

/// Headline, body and the step's buttons, in one layout for every step.
struct StepPage<Body: View, Actions: View>: View {
    let title: String
    var lead: String?
    @ViewBuilder var content: Body
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(title)
                    .font(Typeface.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let lead {
                    Text(lead)
                        .font(Typeface.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .readableWidth()
                }
            }
            content
            Spacer(minLength: 0)
            HStack(spacing: Space.m) {
                Spacer()
                actions
            }
        }
    }
}

private struct WelcomeStep: View {
    let flow: SetupFlow

    var body: some View {
        StepPage(title: "Lock your Mac when you walk away",
                 lead: "FaceLock checks for your face with the webcam every 30 seconds. When it can't find you, it looks again, "
                    + "shows a 10 second countdown, and then locks the screen.") {
            VStack(alignment: .leading, spacing: Space.m) {
                Card {
                    Text("What it is not").font(Typeface.bodyEmphasis)
                    Text("FaceLock is not a login and cannot tell a video of you from you. It notices a face that stays "
                        + "perfectly still for minutes, such as a propped-up photo, and asks you to turn your head before staying unlocked.")
                        .font(Typeface.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Card {
                    Text("What stays on this Mac").font(Typeface.bodyEmphasis)
                    Text("Everything. FaceLock never saves a camera frame. It keeps your face as encrypted templates, which are "
                        + "lists of numbers rather than pictures, and a log of check results.")
                        .font(Typeface.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .readableWidth()
        } actions: {
            Button("Get Started") { flow.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct BeforeStep: View {
    let flow: SetupFlow
    @State private var error: String?

    var body: some View {
        StepPage(title: "The old FaceLock is still here",
                 lead: "The earlier Python version left these behind. Each button does one thing, and anything it removes "
                    + "goes to the Trash, so you can put it back.") {
            VStack(alignment: .leading, spacing: Space.s) {
                let items = flow.model.setupLegacyItems
                if items.isEmpty {
                    Label("All clear.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Typeface.bodyEmphasis)
                            Text(item.detail).font(Typeface.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(item.action) {
                            Task {
                                do { try await flow.model.perform(item) } catch { self.error = error.localizedDescription }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                }
                Text("The old version's .venv and models folders in its source checkout are safe to delete by hand.")
                    .font(Typeface.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(Typeface.caption).foregroundStyle(Theme.critical) }
            }
            .readableWidth()
        } actions: {
            Button("Back") { flow.back() }.buttonStyle(SecondaryButtonStyle())
            Button("Continue") { flow.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(flow.model.legacy.runningPID != nil)
        }
    }
}

private struct CameraStep: View {
    let flow: SetupFlow
    @State private var asking = false

    var body: some View {
        let access = flow.model.cameraAccess
        StepPage(title: "FaceLock needs the camera",
                 lead: "The camera turns on for about half a second at each check and the green light shows when it does. "
                    + "Frames stay in memory and are never saved.") {
            VStack(alignment: .leading, spacing: Space.m) {
                if flow.model.options.isDemo {
                    Label("Demo camera in use. No access needed.", systemImage: "photo").foregroundStyle(.secondary)
                } else if access == .authorized {
                    Label("Camera access is on.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else if access == .denied {
                    Card {
                        Text("FaceLock can't see you").font(Typeface.bodyEmphasis)
                        Text("Open System Settings > Privacy & Security > Camera and turn on FaceLock.")
                            .font(Typeface.body)
                        Button("Open Camera Settings") { flow.model.openCameraSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.top, Space.xs)
                    }
                    .readableWidth()
                }
            }
        } actions: {
            Button("Back") { flow.back() }.buttonStyle(SecondaryButtonStyle())
            if access == .notDetermined && !flow.model.options.isDemo {
                Button("Allow Camera Access") {
                    asking = true
                    Task {
                        if await flow.model.requestCameraAccess() { flow.next() }
                        asking = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(asking)
            } else {
                Button("Continue") { flow.next() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(access != .authorized && !flow.model.options.isDemo)
            }
        }
    }
}

private struct FaceStep: View {
    let flow: SetupFlow

    var body: some View {
        StepPage(title: flow.enrollment.phase == .complete ? "That's all nine looks" : "Show FaceLock your face",
                 lead: "Follow the ring that's lit. Each look fills after six clear views, so take your time.") {
            VStack(alignment: .leading, spacing: Space.m) {
                EnrollmentView(enrollment: flow.enrollment)
                if case let .failed(message) = flow.enrollment.phase {
                    Text(message).font(Typeface.caption).foregroundStyle(Theme.critical)
                }
                if let e = flow.saveError { Text(e).font(Typeface.caption).foregroundStyle(Theme.critical) }
            }
        } actions: {
            Button("Back") { flow.back() }.buttonStyle(SecondaryButtonStyle())
            Button("Save My Face") { flow.saveEnrollment() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(flow.enrollment.phase != .complete)
        }
        .task { await flow.enrollment.start(app: flow.model) }
    }
}

private struct ResultStep: View {
    let flow: SetupFlow

    var body: some View {
        StepPage(title: "Your threshold") {
            if let report = flow.report { CalibrationView(report: report) }
        } actions: {
            Button("Continue") { flow.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SomeoneElseStep: View {
    let flow: SetupFlow

    var body: some View {
        SomeoneElseView(check: flow.someoneElse, standalone: false) { flow.next() }
    }
}

private struct FinishStep: View {
    let flow: SetupFlow
    let onClose: () -> Void
    @State private var error: String?

    var body: some View {
        let model = flow.model
        StepPage(title: "FaceLock is watching",
                 lead: "It lives in the menu bar. Pause it there before a video call in another room, or teach it a new look "
                    + "after a haircut or new glasses.") {
            VStack(alignment: .leading, spacing: Space.m) {
                LoginItemToggle()
                if model.legacyItems.contains(.enrollment) {
                    HStack(alignment: .top, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LegacyItem.enrollment.title).font(Typeface.bodyEmphasis)
                            Text(LegacyItem.enrollment.detail).font(Typeface.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(LegacyItem.enrollment.action) {
                            Task { do { try await model.perform(.enrollment) } catch { self.error = error.localizedDescription } }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                }
                if let error { Text(error).font(Typeface.caption).foregroundStyle(Theme.critical) }
            }
            .readableWidth()
        } actions: {
            Button("Done") {
                if !model.options.isDemo { Task { _ = await model.notifier.requestAuthorization() } }
                onClose()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// "Start at login", showing what macOS reports rather than what was asked for.
struct LoginItemToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Toggle("Start at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.setLoginItem($0) }))
                .disabled(model.options.isDemo)
            if model.options.isDemo {
                Text("Off in a demo run.").font(Typeface.caption).foregroundStyle(.secondary)
            } else if let detail = model.loginItem.detail {
                HStack(spacing: Space.s) {
                    Text(detail).font(Typeface.caption).foregroundStyle(Theme.warning)
                    if model.loginItem == .requiresApproval {
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                            .buttonStyle(.link)
                            .font(Typeface.caption)
                    }
                }
            }
        }
        .onAppear { model.refreshLoginItem() }
    }
}
