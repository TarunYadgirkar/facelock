import AppKit
import CoreGraphics
import FaceLockCore
import Foundation

public enum IdleTime {
    /// Seconds since the last keyboard, mouse or trackpad event. Needs no permission.
    public static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

/// Polls idle time at 10 Hz, only while the countdown panel is visible, and reports the first
/// input after it started.
public final class InputMonitor: @unchecked Sendable {
    public static let hz = 10.0
    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.input", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let idle: @Sendable () -> TimeInterval

    public init(idle: @escaping @Sendable () -> TimeInterval = { IdleTime.secondsSinceInput() }) {
        self.idle = idle
    }

    public func start(onInput: @escaping @Sendable () -> Void) {
        queue.async {
            self.timer?.cancel()
            let started = Date()
            let idle = self.idle
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1 / Self.hz, repeating: 1 / Self.hz, leeway: .milliseconds(10))
            t.setEventHandler {
                guard idle() < Date().timeIntervalSince(started) else { return }
                t.cancel()
                onInput()
            }
            self.timer = t
            t.activate()
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }
}

/// Screen lock, display sleep and system sleep, from notifications only. Nothing polls.
public final class SystemEventMonitor: @unchecked Sendable {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(send: @escaping @Sendable (WatcherEvent) -> Void) {
        let dnc = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(NotificationCenter, Notification.Name, WatcherEvent)] = [
            (dnc, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (dnc, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
            (ws, NSWorkspace.screensDidSleepNotification, .displaySlept),
            (ws, NSWorkspace.screensDidWakeNotification, .displayWoke),
            (ws, NSWorkspace.willSleepNotification, .systemWillSleep),
            (ws, NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        for (center, name, event) in pairs {
            tokens.append((center, center.addObserver(forName: name, object: nil, queue: nil) { _ in send(event) }))
        }
    }

    deinit {
        tokens.forEach { $0.0.removeObserver($0.1) }
    }
}
