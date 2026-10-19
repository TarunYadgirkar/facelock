import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import Foundation
import IOKit.ps

/// A Bool any queue may read.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The watcher's check runner, set once the camera and models are ready. Until then the watcher
/// is blocked and never starts a window; a stray one ends at once as an empty room.
final class SwitchableChecks: CheckPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var runner: CheckRunner?

    func set(_ r: CheckRunner?) {
        lock.withLock { runner = r }
    }

    var isSet: Bool { lock.withLock { runner != nil } }

    func startWindow(id: Int, kind: CheckKind, policy: WindowPolicy, recognition: RecognitionContext,
                     completion: @escaping @Sendable (Int, WindowSummary) -> Void) {
        guard let r = lock.withLock({ runner }) else {
            let empty = WindowAccumulator(policy: policy, thresholds: recognition.thresholds).summary(timing: .zero)
            return completion(id, empty)
        }
        r.startWindow(id: id, kind: kind, policy: policy, recognition: recognition, completion: completion)
    }

    func abortWindow() {
        lock.withLock { runner }?.abortWindow()
    }
}

/// `--dry-run` and every demo: the real countdown panel and input watch, but the lock is a log
/// line. This type has no path to the lock API.
final class DryRunAppEnvironment: WatchEnvironment, @unchecked Sendable {
    private let presenter: CountdownPresenter
    private let input = InputMonitor()
    private let note: @Sendable (String) -> Void

    init(presenter: CountdownPresenter, note: @escaping @Sendable (String) -> Void) {
        self.presenter = presenter
        self.note = note
    }

    func lock(completion: @escaping @Sendable (LockOutcome) -> Void) {
        note("Dry run: FaceLock would have locked the screen at \(Date().formatted(date: .omitted, time: .standard)).")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { completion(.locked) }
    }

    func secondsSinceInput() -> TimeInterval? { IdleTime.secondsSinceInput() }
    func notify(_ notice: Notice) { note("Notice: \(Notifier.text(for: notice).title)") }
    func showCountdown(endsAt: Date, reason: CountdownReason) { presenter.show(endsAt: endsAt, reason: reason) }
    func hideCountdown() { presenter.hide() }
    func startInputMonitor(onInput: @escaping @Sendable () -> Void) { input.start(onInput: onInput) }
    func stopInputMonitor() { input.stop() }
}

/// Power source changes from IOKit's notification, never polled.
final class PowerMonitor {
    private final class Box {
        let onChange: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onChange = f }
    }

    private let box: Box
    private var source: CFRunLoopSource?

    init(onChange: @escaping (Bool) -> Void) {
        box = Box(onChange)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().onChange(PowerSource.isOnBattery)
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
