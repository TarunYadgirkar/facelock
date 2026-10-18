import FaceLockCore
import Foundation

/// The countdown panel (the app's non-activating NSPanel) as the watcher sees it.
public protocol CountdownPresenter: AnyObject, Sendable {
    func show(endsAt: Date, reason: CountdownReason)
    func hide()
}

/// The real WatchEnvironment: locks the screen, posts notifications, reads idle time and polls
/// input at 10 Hz only while the countdown is up. The app supplies the panel.
public final class SystemEnvironment: WatchEnvironment, @unchecked Sendable {
    private let locker = ScreenLocker()
    private let notifier: Notifier
    private let input = InputMonitor()
    private let stayAwake = StayAwake()
    private let presenter: CountdownPresenter?
    private let sound: @Sendable () -> Bool
    private var unlockObserver: NSObjectProtocol?

    public init(notifier: Notifier = Notifier(), presenter: CountdownPresenter?, sound: @escaping @Sendable () -> Bool) {
        self.notifier = notifier
        self.presenter = presenter
        self.sound = sound
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [stayAwake] _ in stayAwake.end() }
    }

    deinit {
        unlockObserver.map(DistributedNotificationCenter.default().removeObserver)
    }

    public func lock(completion: @escaping @Sendable (LockOutcome) -> Void) {
        locker.lock { [stayAwake] outcome in
            if outcome == .locked { stayAwake.begin() }
            completion(outcome)
        }
    }

    public func secondsSinceInput() -> TimeInterval? { IdleTime.secondsSinceInput() }

    public func notify(_ notice: Notice) {
        let t = Notifier.text(for: notice)
        notifier.post(title: t.title, body: t.body, sound: sound())
    }

    public func showCountdown(endsAt: Date, reason: CountdownReason) { presenter?.show(endsAt: endsAt, reason: reason) }
    public func hideCountdown() { presenter?.hide() }
    public func startInputMonitor(onInput: @escaping @Sendable () -> Void) { input.start(onInput: onInput) }
    public func stopInputMonitor() { input.stop() }
}
