import FaceLockCore
import SwiftUI

/// The menu bar window: state first, then the actions.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowManager.self) private var windows
    @State private var showPauseChoices = false
    /// Fixed for snapshots; nil follows the clock.
    var now: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
                .padding(.horizontal, Space.s)
                .padding(.top, Space.xs)
            Divider().padding(.horizontal, Space.s)
            actions
            if model.options.isDemo { demoFooter }
        }
        .padding(Space.s)
        .frame(width: 304)
        .onAppear { model.refreshCameraAccess() }
    }

    @ViewBuilder private var header: some View {
        if let now {
            StatusHeader(state: model.state, now: now, engineReady: model.engine != .loading)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatusHeader(state: model.state, now: context.date, engineReady: model.engine != .loading)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fix = model.state.status(now: Date()).fix {
                Button(StatusText.fixTitle(fix)) { windows.performFix(fix) }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Space.s)
                    .padding(.bottom, Space.s)
            }
            Button("Check Now") { model.checkNow() }
                .buttonStyle(MenuRowStyle())
                .disabled(!model.canCheckNow)
            pauseRows
            if DayTwo.shouldOffer(model.payload, now: Date(), dismissed: model.prefs.lightPromptDismissed) {
                Button("Add Today's Light (20 s)…") { windows.openTeach(.light) }
                    .buttonStyle(MenuRowStyle())
            }
            Button("Teach a New Look…") { windows.openTeach(.look) }
                .buttonStyle(MenuRowStyle())
                .disabled(!model.isEnrolled)
            Button("Settings…") { windows.openSettings() }
                .buttonStyle(MenuRowStyle())
                .keyboardShortcut(",")
            Divider().padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            Button("Quit FaceLock") { NSApp.terminate(nil) }
                .buttonStyle(MenuRowStyle())
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder private var pauseRows: some View {
        if model.state.pause != nil {
            Button("Resume") { model.resume() }
                .buttonStyle(MenuRowStyle())
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showPauseChoices.toggle() }
            } label: {
                HStack {
                    Text("Pause")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showPauseChoices ? 90 : 0))
                }
            }
            .buttonStyle(MenuRowStyle())
            .disabled(model.state.blocked != nil)
            .accessibilityHint("Shows how long to pause")
            if showPauseChoices {
                ForEach(PauseChoice.allCases) { choice in
                    Button(choice.title) {
                        model.pause(choice)
                        showPauseChoices = false
                    }
                    .buttonStyle(MenuRowStyle())
                    .padding(.leading, Space.l)
                }
            }
        }
    }

    private var demoFooter: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Divider().padding(.bottom, Space.xs)
                Text("Demo camera. Locking is off.")
                    .font(Typeface.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let latest = model.notes.first {
                    Text(latest).font(Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.s)
            Button(model.demoPresent ? "Demo: Take the Photo Away" : "Demo: Bring the Photo Back") {
                model.setDemoPresent(!model.demoPresent)
            }
            .buttonStyle(MenuRowStyle())
        }
    }
}

struct StatusHeader: View {
    let state: WatcherState
    let now: Date
    let engineReady: Bool

    var body: some View {
        let line = state.status(now: now)
        let text = StatusText.make(state, line: line, now: now)
        VStack(alignment: .leading, spacing: Space.xs + 2) {
            HStack(alignment: .firstTextBaseline) {
                StatusPill(tone: engineReady ? line.tone : .neutral, label: engineReady ? text.pill : "Starting")
                Spacer()
                Text(state.cadence.name.title)
                    .font(Typeface.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(engineReady ? text.headline : "Starting up")
                .font(Typeface.state)
                .fixedSize(horizontal: false, vertical: true)
            if engineReady, let detail = text.detail {
                Text(detail)
                    .font(Typeface.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let line = model.state.status(now: Date())
        Image(nsImage: Glyphs.image(line.glyph, remaining: model.countdownRemaining))
            .accessibilityLabel(Glyphs.description(line.glyph))
    }
}
