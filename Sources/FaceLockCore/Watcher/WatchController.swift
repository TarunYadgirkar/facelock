import Foundation

/// What a check needs to score faces.
public struct RecognitionContext: Equatable, Sendable {
    public var gallery: Gallery
    public var thresholds: Thresholds
    public var sharpnessFloor: Double?

    public init(gallery: Gallery, thresholds: Thresholds, sharpnessFloor: Double? = nil) {
        self.gallery = gallery
        self.thresholds = thresholds
        self.sharpnessFloor = sharpnessFloor
    }
}

/// Runs one camera window. Implemented by FaceLockCapture over a real or stored-image camera.
public protocol CheckPerforming: AnyObject, Sendable {
    /// Calls `completion` once with the window's summary, unless `abortWindow` comes first.
    func startWindow(id: Int, kind: CheckKind, policy: WindowPolicy, recognition: RecognitionContext,
                     completion: @escaping @Sendable (Int, WindowSummary) -> Void)
    func abortWindow()
}

/// Everything the watcher asks of the system and the UI. The app implements it with
/// FaceLockSystem and its panels; `DryRunEnvironment` stands in for benchmarks and demos.
public protocol WatchEnvironment: AnyObject, Sendable {
    func lock(completion: @escaping @Sendable (LockOutcome) -> Void)
    func secondsSinceInput() -> TimeInterval?
    func notify(_ notice: Notice)
    func showCountdown(endsAt: Date, reason: CountdownReason)
    func hideCountdown()
    func startInputMonitor(onInput: @escaping @Sendable () -> Void)
    func stopInputMonitor()
}

public protocol TelemetrySink: AnyObject, Sendable {
    func record(_ r: CheckRecord)
}

/// Drives `Watcher.reduce` on one serial queue with one timer. Nothing polls: the timer is the
/// only wake-up source, and it is idle (never fires) while suspended.
public final class WatchController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.watch", qos: .utility)
    private let timer: DispatchSourceTimer
    private let checks: CheckPerforming
    private let environment: WatchEnvironment
    private let telemetry: TelemetrySink?
    private let clock: @Sendable () -> Date
    private let adaptationPolicy: AdaptationPolicy
    private var state: WatcherState
    private var recognition: RecognitionContext
    private var changeHandler: (@Sendable (WatcherState) -> Void)?
    private var galleryHandler: (@Sendable (Gallery) -> Void)?

    public init(settings: WatcherSettings, recognition: RecognitionContext, checks: CheckPerforming,
                environment: WatchEnvironment, telemetry: TelemetrySink? = nil,
                adaptationPolicy: AdaptationPolicy = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.state = WatcherState(settings: settings)
        self.recognition = recognition
        self.checks = checks
        self.environment = environment
        self.telemetry = telemetry
        self.adaptationPolicy = adaptationPolicy
        self.clock = clock
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.apply(.timerFired) }
        timer.activate()
    }

    deinit {
        timer.cancel()
    }

    /// Called on the controller queue after every state change (the menu bar redraws then, never on a timer).
    public func onChange(_ handler: @escaping @Sendable (WatcherState) -> Void) {
        queue.async { self.changeHandler = handler }
    }

    /// Called when adaptation adds a template, so the app can persist the gallery and recalibrate.
    public func onGalleryChange(_ handler: @escaping @Sendable (Gallery) -> Void) {
        queue.async { self.galleryHandler = handler }
    }

    public func send(_ event: WatcherEvent) {
        queue.async { self.apply(event) }
    }

    public func update(recognition r: RecognitionContext) {
        queue.async { self.recognition = r }
    }

    public var snapshot: WatcherState { queue.sync { state } }
    public var currentRecognition: RecognitionContext { queue.sync { recognition } }

    private func apply(_ event: WatcherEvent) {
        let t = Watcher.reduce(state, event, now: clock())
        let changed = t.state != state
        state = t.state
        t.effects.forEach(perform)
        if changed { changeHandler?(state) }
    }

    private func perform(_ effect: WatcherEffect) {
        switch effect {
        case let .startWindow(id, kind, policy):
            checks.startWindow(id: id, kind: kind, policy: policy, recognition: recognition) { [weak self] id, summary in
                self?.send(.windowFinished(id: id, summary: summary))
            }
        case .abortWindow: checks.abortWindow()
        case let .schedule(at):
            // Wall time keeps counting while the Mac sleeps, so a pause still ends on time after a nap.
            let delay = max(0, at.timeIntervalSince(clock()))
            let leeway = DispatchTimeInterval.milliseconds(Int(min(1000, max(50, delay * 50))))
            timer.schedule(wallDeadline: .now() + delay, repeating: .never, leeway: leeway)
        case .cancelSchedule: timer.schedule(deadline: .distantFuture)
        case let .showCountdown(endsAt, reason): environment.showCountdown(endsAt: endsAt, reason: reason)
        case .hideCountdown: environment.hideCountdown()
        case .startInputMonitor: environment.startInputMonitor { [weak self] in self?.send(.userInput) }
        case .stopInputMonitor: environment.stopInputMonitor()
        case .lock: environment.lock { [weak self] outcome in self?.send(.lockResult(outcome)) }
        case let .notify(n): if state.settings.notify || n.isCritical { environment.notify(n) }
        case let .record(r): telemetry?.record(r)
        case let .considerAdaptation(c): adapt(c)
        }
    }

    private func adapt(_ c: AdaptationCandidate) {
        let now = clock()
        let gallery = Adaptation.expiring(recognition.gallery, now: now, policy: adaptationPolicy)
        let context = AdaptationContext(threshold: recognition.thresholds.accept,
                                        strangerOrUnclearSinceUnlock: state.strangerOrUnclearSinceUnlock,
                                        secondsSinceInput: environment.secondsSinceInput(), now: now)
        let rejected = Adaptation.evaluate(c, in: gallery, context: context, policy: adaptationPolicy)
        let next = rejected == nil
            ? Adaptation.adding(Adaptation.template(for: c, at: now, session: 0), to: gallery, policy: adaptationPolicy)
            : gallery
        guard next != recognition.gallery else { return }
        recognition.gallery = next
        galleryHandler?(next)
    }
}

/// Logs instead of locking or showing UI; input never arrives. For benchmarks and `--dry-run`.
public final class DryRunEnvironment: WatchEnvironment, @unchecked Sendable {
    private let lockLock = NSLock()
    private var log: [String] = []
    private let echo: Bool

    public init(echo: Bool = false) {
        self.echo = echo
    }

    public var events: [String] { lockLock.withLock { log } }

    private func note(_ s: String) {
        lockLock.withLock { log.append(s) }
        if echo { print("[dry-run] \(s)") }
    }

    public func lock(completion: @escaping @Sendable (LockOutcome) -> Void) {
        note("would lock the screen")
        completion(.dryRun)
    }

    public func secondsSinceInput() -> TimeInterval? { nil }
    public func notify(_ notice: Notice) { note("notify \(notice)") }
    public func showCountdown(endsAt: Date, reason: CountdownReason) { note("countdown \(reason.rawValue)") }
    public func hideCountdown() { note("countdown hidden") }
    public func startInputMonitor(onInput: @escaping @Sendable () -> Void) {}
    public func stopInputMonitor() {}
}
