import AppKit
import FaceLockCore
import SwiftUI

enum TeachMode: String, Sendable {
    /// Teach a new look: 5 s.
    case look
    /// Add today's light: a 20 s second session.
    case light
}

/// Opens Setup, Settings and Teach as ordinary windows and lets each go when it closes, so none
/// of them stays resident.
@MainActor @Observable
final class WindowManager: NSObject, NSWindowDelegate {
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var open: [String: NSWindow] = [:]
    @ObservationIgnored private var settingsTabs: SettingsTabController?

    func openSetup(at step: SetupStep? = nil) {
        guard let model else { return }
        let flow = SetupFlow(model: model, start: step)
        show(id: "setup", title: "Set Up FaceLock", content: SetupView(flow: flow) { [weak self] in self?.close("setup") })
    }

    func openSettings(_ tab: SettingsTab = .general) {
        guard let model else { return }
        if let w = open["settings"] {
            settingsTabs?.select(tab)
            activate(w)
            return
        }
        let tabs = SettingsTabController(model: model, windows: self)
        settingsTabs = tabs
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        tabs.select(tab)
        register(w, id: "settings")
    }

    func openTeach(_ mode: TeachMode) {
        guard let model else { return }
        let teach = TeachModel(app: model, mode: mode)
        let title = mode == .look ? "Teach a New Look" : "Add Today's Light"
        show(id: "teach", title: title, content: TeachView(teach: teach) { [weak self] in self?.close("teach") })
    }

    func openSomeoneElse() {
        guard let model else { return }
        let check = SomeoneElseModel(app: model)
        show(id: "someone-else", title: "Check with Someone Else",
             content: SomeoneElseView(check: check, standalone: true) { [weak self] in self?.close("someone-else") }
                .padding(Space.xl).frame(width: 520))
    }

    func performFix(_ fix: StatusFix) {
        guard let model else { return }
        switch fix {
        case .openCameraSettings:
            if model.cameraAccess == .notDetermined { openSetup(at: .camera) } else { model.openCameraSettings() }
        case .startEnrollment: openSetup()
        case .reenroll: openSetup(at: .face)
        }
    }

    func close(_ id: String) {
        open[id]?.close()
    }

    private func show(id: String, title: String, content: some View) {
        guard let model else { return }
        if let w = open[id] {
            activate(w)
            return
        }
        let host = NSHostingController(rootView: content.environment(model).environment(self))
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        register(w, id: id)
    }

    private func register(_ w: NSWindow, id: String) {
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.center()
        open[id] = w
        activate(w)
    }

    private func activate(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        open[id] = nil
        if id == "settings" { settingsTabs = nil }
        w.contentViewController = nil
    }
}
