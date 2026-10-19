import FaceLockCapture
import FaceLockCore
import SwiftUI

/// A small preview with the capture ring over its corner, shared by Teach and Someone else.
private struct TimedPreview: View {
    let session: CameraSession?
    let image: CGImage?
    let progress: Double
    let active: Bool

    var body: some View {
        CameraWell(session: active ? session : nil, image: active ? image : nil) {
            if active {
                VStack {
                    HStack {
                        Spacer()
                        ProgressRing(progress: progress, lineWidth: 4, tint: .white)
                            .frame(width: 30, height: 30)
                            .padding(Space.l)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: 320)
    }
}

struct SomeoneElseView: View {
    @Bindable var check: SomeoneElseModel
    let standalone: Bool
    var onDone: () -> Void

    var body: some View {
        StepPage(title: "Check with someone else",
                 lead: "Optional. Ask a person who sits near your Mac to look at the camera for 10 seconds while you step out of "
                    + "view. FaceLock compares their face with yours and keeps only their best score, never their face.") {
            HStack(alignment: .top, spacing: Space.xl) {
                TimedPreview(session: check.cameraSession, image: check.preview, progress: check.progress,
                             active: check.phase == .capturing)
                VStack(alignment: .leading, spacing: Space.s) {
                    switch check.phase {
                    case .intro:
                        Text("Ask them first.").font(Typeface.bodyEmphasis)
                        Text("Their face is used for these 10 seconds only and is gone when the check ends.")
                            .font(Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .capturing:
                        Text("Looking at them").font(Typeface.bodyEmphasis)
                        Text(check.faces == 0 ? "No face in view yet" : "Face in view")
                            .font(Typeface.body).foregroundStyle(.secondary)
                    case .done:
                        Text(check.resultText).font(Typeface.body).fixedSize(horizontal: false, vertical: true)
                    case let .failed(message):
                        Text(message).font(Typeface.body).foregroundStyle(Theme.critical)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
        } actions: {
            switch check.phase {
            case .intro, .failed:
                Button(standalone ? "Cancel" : "Skip") { onDone() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start (10 s)") { Task { await check.start() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .capturing:
                Button("Stop") { check.stop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            case .done:
                Button(standalone ? "Done" : "Continue") { onDone() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct TeachView: View {
    @Bindable var teach: TeachModel
    var onDone: () -> Void

    var body: some View {
        StepPage(title: teach.mode == .look ? "Teach a new look" : "Add today's light",
                 lead: teach.mode == .look
                    ? "After a haircut, new glasses or a new desk light. FaceLock asks for Touch ID or your password, then "
                        + "watches for 5 seconds. Looks it would not recognise yet are what it learns."
                    : "A second sitting in today's light, so your threshold isn't tuned to one afternoon. "
                        + "FaceLock asks for Touch ID or your password, then watches for 20 seconds.") {
            HStack(alignment: .top, spacing: Space.xl) {
                TimedPreview(session: teach.cameraSession, image: teach.preview, progress: teach.progress,
                             active: teach.phase == .capturing)
                VStack(alignment: .leading, spacing: Space.s) {
                    switch teach.phase {
                    case .intro:
                        Text("Sit as you usually do, with only you in view.")
                            .font(Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .authenticating:
                        Text("Waiting for Touch ID or your password").font(Typeface.body).foregroundStyle(.secondary)
                    case .capturing:
                        Text("\(teach.captured) views so far").font(Typeface.bodyEmphasis).monospacedDigit()
                        Text("Move your head a little.").font(Typeface.body).foregroundStyle(.secondary)
                    case .done:
                        Text(teach.resultText).font(Typeface.body).fixedSize(horizontal: false, vertical: true)
                    case let .failed(message):
                        Text(message).font(Typeface.body).foregroundStyle(Theme.critical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
        } actions: {
            switch teach.phase {
            case .intro, .failed:
                if teach.mode == .light {
                    Button("Don't Remind Me") {
                        teach.dismissLightPrompt()
                        onDone()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Cancel") { onDone() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start") { Task { await teach.start() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .authenticating:
                EmptyView()
            case .capturing:
                Button("Stop") { teach.stop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            case .done:
                Button("Done") { onDone() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 640, height: 420)
    }
}
