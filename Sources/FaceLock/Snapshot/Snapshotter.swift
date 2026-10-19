import AppKit
import FaceLockCore
import SwiftUI

/// A window that draws as the key window, so controls render active in an offscreen capture.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// `FaceLock --demo-camera <public-domain photo> --snapshot <dir>`: drives the real app through
/// setup, watching, leaving and the countdown on the stored-image camera, and renders each
/// screen from its own view hierarchy to PNG. No screen capture and no real camera: the owner's
/// camera can never appear in a committed image. Quits when done.
@MainActor
final class Snapshotter {
    private let model: AppModel
    private let windows: WindowManager
    private let directory: URL
    private var written: [String] = []

    init(model: AppModel, windows: WindowManager, directory: URL) {
        self.model = model
        self.windows = windows
        self.directory = directory
    }

    func run() async {
        // App Nap would stretch the waits below and the snapshots would show later states than named.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Rendering snapshots")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await render(GlyphSheet(), "ui-menu-glyphs")
        guard await wait(20, { self.model.engine != .loading }), model.engine == .ready else { return finish("models did not load") }

        let flow = SetupFlow(model: model, start: .welcome)
        await render(SetupView(flow: flow) {}, "ui-setup-welcome")
        flow.step = .face
        let setup = SetupView(flow: flow) {}
        let host = await open(setup, dark: false)
        _ = await wait(25) { flow.enrollment.acceptedCount >= 9 }
        await capture(host, "ui-setup-face")
        host.window?.orderOut(nil)
        flow.enrollment.stop()

        await model.enrollDemoFace()
        guard let report = model.payload?.calibration else { return finish("demo enrollment failed") }
        flow.report = report
        flow.step = .result
        await render(SetupView(flow: flow) {}, "ui-setup-result")

        guard await wait(20, { self.model.state.watchState == .present && self.model.state.lastOwnerSeen != nil }) else {
            return finish("the watcher never saw the photo")
        }
        try? await Task.sleep(for: .seconds(3))
        await render(menu(), "ui-menu-watching")

        model.setDemoPresent(false)
        guard await wait(45, { self.model.state.watchState == .looking }) else { return finish("never reached Looking") }
        await render(menu(), "ui-menu-looking-dark", dark: true)
        guard await wait(60, { self.model.state.countdownEndsAt != nil }) else { return finish("never reached the countdown") }
        if let ends = model.state.countdownEndsAt {
            try? await Task.sleep(for: .seconds(2))
            if model.state.watchState == .countdown { await render(menu(), "ui-menu-countdown") }
            await render(CountdownCard(endsAt: ends, total: Double(model.settings.countdownSeconds), reason: .away)
                .padding(Space.xxl), "ui-countdown", background: Color(white: 0.32))
        }
        if await wait(20, { self.model.notes.contains { $0.hasPrefix("Dry run") } }) {
            try? await Task.sleep(for: .milliseconds(500))
            await render(menu(), "ui-menu-after-dry-run-lock")
        }
        model.setDemoPresent(true)

        for tab in SettingsTab.allCases {
            await render(SettingsPane(tab: tab), "ui-settings-\(tab.rawValue)")
        }
        await render(TeachView(teach: TeachModel(app: model, mode: .look)) {}, "ui-teach")
        finish(nil)
    }

    private func menu() -> some View {
        MenuPanel(now: Date())
    }

    private func finish(_ problem: String?) {
        let line = problem.map { "snapshot stopped: \($0)" } ?? "snapshot wrote \(written.count) images"
        print(line)
        print(written.joined(separator: "\n"))
        print("notes:", model.notes.joined(separator: " | "))
        exit(problem == nil ? 0 : 1)
    }

    private func wait(_ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func open(_ view: some View, dark: Bool, background: Color? = nil) async -> NSView {
        let root = view
            .fixedSize()
            .environment(model)
            .environment(windows)
            .background(background ?? Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let w = SnapshotWindow(contentRect: NSRect(x: -12000, y: -12000, width: size.width, height: size.height),
                               styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        return host
    }

    private func capture(_ host: NSView, _ name: String) async {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = directory.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        written.append(url.path)
    }

    private func render(_ view: some View, _ name: String, dark: Bool = false, background: Color? = nil) async {
        let host = await open(view, dark: dark, background: background)
        await capture(host, name)
        host.window?.orderOut(nil)
    }
}

/// Every menu bar state at 4x, for the README.
private struct GlyphSheet: View {
    private let glyphs: [(MenuGlyph, String)] = [
        (.watching, "Watching"), (.checking, "Checking"), (.lookingForYou(checksLeft: 2), "Looking, 2 left"),
        (.countdown, "Countdown"), (.someoneElse, "Someone else"), (.paused, "Paused"), (.notProtecting, "Not protecting"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, g in
                VStack(spacing: Space.s) {
                    Image(nsImage: Glyphs.image(g.0, remaining: 0.6))
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 54, height: 54)
                        .foregroundStyle(.primary)
                    Text(g.1).font(Typeface.caption).foregroundStyle(.secondary)
                }
                .frame(width: 84)
            }
        }
        .padding(Space.xl)
    }
}
