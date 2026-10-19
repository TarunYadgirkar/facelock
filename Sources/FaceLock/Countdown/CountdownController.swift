import AppKit
import FaceLockCore
import FaceLockSystem
import SwiftUI

/// A panel that never takes focus, floats over full-screen apps on every Space, and accepts the
/// one click on "I'm here".
final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The countdown before a lock: a dim over every screen that deepens from 15% to 35%, and a card
/// at the top of the main screen. Shown and hidden by the watcher through `CountdownPresenter`.
/// "Checking for you" replaces the countdown during the one more look, without the dim. With no
/// screen attached nothing is drawn; the watcher's countdown runs the same.
@MainActor
final class CountdownController: CountdownPresenter {
    static let startDim: CGFloat = 0.15
    static let endDim: CGFloat = 0.35

    private var card: CountdownPanel?
    private var dims: [NSWindow] = []
    var onHere: () -> Void = {}
    var soundOn: () -> Bool = { false }

    // The main queue runs these in the order the watcher sent them; a Task each would not promise that.
    nonisolated func show(endsAt: Date, reason: CountdownReason) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.present(endsAt: endsAt, reason: reason) } }
    }

    nonisolated func hide() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.dismiss() } }
    }

    private func present(endsAt: Date, reason: CountdownReason) {
        dismiss()
        let total = max(1, endsAt.timeIntervalSinceNow)
        if reason != .checking { dims = NSScreen.screens.map { dimWindow(on: $0, over: total) } }
        if let panel = cardPanel(endsAt: endsAt, total: total, reason: reason) {
            card = panel
            panel.orderFrontRegardless()
        }
        announce(reason, seconds: Int(total.rounded()))
        if soundOn(), reason != .checking { NSSound(named: "Tink")?.play() }
    }

    private func dismiss() {
        card?.orderOut(nil)
        card = nil
        dims.forEach { $0.orderOut(nil) }
        dims = []
    }

    private func dimWindow(on screen: NSScreen, over seconds: TimeInterval) -> NSWindow {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar
        w.backgroundColor = .black
        w.alphaValue = Self.startDim
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.orderFrontRegardless()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = seconds
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                w.animator().alphaValue = Self.endDim
            }
        }
        return w
    }

    private func cardPanel(endsAt: Date, total: TimeInterval, reason: CountdownReason) -> CountdownPanel? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let view = CountdownCard(endsAt: endsAt, total: total, reason: reason) { [weak self] in self?.onHere() }
            .padding(Space.xxl)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 48)
        let p = CountdownPanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.contentView = host
        p.setAccessibilityTitle("FaceLock countdown")
        return p
    }

    private func announce(_ reason: CountdownReason, seconds: Int) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: CountdownCopy.announcement(reason, seconds: seconds),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
