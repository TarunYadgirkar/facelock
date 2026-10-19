import FaceLockVision
import SwiftUI

/// The licence notice, the one-time download of InsightFace's r50 weights, and its progress or
/// error. Setup shows it as a step; an owner who updated from a build that bundled the weights
/// gets it in its own window.
struct ModelDownloadView: View {
    @Environment(AppModel.self) private var model
    @State private var accepted = false

    static let licenceURL = URL(string: "https://github.com/deepinsight/insightface#license")!

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Card {
                Text("Licence").font(Typeface.bodyEmphasis)
                Text("InsightFace makes these weights available for non-commercial research purposes only. "
                    + "FaceLock is free and doesn't include them, so you download them yourself, from InsightFace.")
                    .font(Typeface.body)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Read InsightFace's licence", destination: Self.licenceURL)
                    .font(Typeface.caption)
            }
            Card {
                Text("What happens").font(Typeface.bodyEmphasis)
                Text("FaceLock downloads buffalo_l.zip (289 MB) from InsightFace's GitHub release and checks its SHA-256. "
                    + "It keeps only the recognizer, w600k_r50.onnx (174 MB), in Application Support, deletes the rest, "
                    + "and builds its Core ML model from it. Nothing about you is sent.")
                    .font(Typeface.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
        }
        .readableWidth()
    }

    @ViewBuilder private var status: some View {
        switch model.recognizer {
        case .needed:
            Toggle("I accept InsightFace's non-commercial research licence", isOn: $accepted)
                .toggleStyle(.checkbox)
            Button("Download 289 MB") { model.installRecognizer() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!accepted)
        case let .working(phase):
            VStack(alignment: .leading, spacing: Space.s) {
                progress(phase)
                if case .downloading = phase {
                    Button("Cancel Download") { model.cancelRecognizerInstall() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: Space.s) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.body)
                    .foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.installRecognizer() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .installed where model.engine == .failed:
            VStack(alignment: .leading, spacing: Space.s) {
                Label("FaceLock couldn't load the face model. Building it again usually fixes this.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.body)
                    .foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Build Again") { model.installRecognizer() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .installed:
            Label(model.engine == .ready ? "The face model is ready." : "Loading the face model…",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
        }
    }

    @ViewBuilder private func progress(_ phase: RecognizerInstaller.Phase) -> some View {
        switch phase {
        case let .downloading(received, total):
            VStack(alignment: .leading, spacing: Space.xs) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("Downloading: \(received / AppModel.megabyte) of \(total / AppModel.megabyte) MB")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .verifying: busy("Checking the download")
        case .extracting: busy("Unpacking the recognizer")
        case .building: busy("Building the Core ML model")
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(text).font(Typeface.body)
        }
    }
}

/// The download on its own, for an owner who is already enrolled.
struct ModelDownloadWindow: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    var body: some View {
        StepPage(title: "Download the face model",
                 lead: "FaceLock recognizes you with ArcFace r50, a model trained by InsightFace. It needs to be downloaded once "
                    + "before FaceLock can watch.") {
            ModelDownloadView()
        } actions: {
            if model.recognizer == .installed {
                Button("Done") { onClose() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Later") { onClose() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 620, height: 560)
    }
}
