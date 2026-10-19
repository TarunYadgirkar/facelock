import AppKit
import AVFoundation
import FaceLockCapture
import FaceLockCore
import FaceLockSystem
import FaceLockVision
import Observation

/// The menu bar app's one source of truth. The watcher runs on its own queue inside
/// `WatchController`; this model mirrors its state on the main actor and redraws only when it
/// changes.
@MainActor @Observable
final class AppModel {
    enum EngineState: Equatable { case loading, ready, failed }

    let options: LaunchOptions
    let paths: AppPaths
    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored let store: EnrollmentStore
    @ObservationIgnored let telemetry: TelemetryLog
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let countdownUI = CountdownController()
    @ObservationIgnored let demoScene = DemoScene()
    @ObservationIgnored private(set) var controller: WatchController!
    @ObservationIgnored let checks = SwitchableChecks()
    @ObservationIgnored private var systemEvents: SystemEventMonitor?
    @ObservationIgnored private var powerMonitor: PowerMonitor?
    @ObservationIgnored private var systemEnvironment: SystemEnvironment?
    @ObservationIgnored var pipeline: FacePipeline?
    @ObservationIgnored let camera = WatchCameraState()
    @ObservationIgnored private var countdownTicker: Timer?
    @ObservationIgnored private var pendingGlyph: Task<Void, Never>?
    /// Setup screens holding the camera; the watcher pauses while any does.
    @ObservationIgnored private var setupHolders = 0
    /// Read by notifications on the watcher's queue, so it can't live on the main actor.
    @ObservationIgnored private let soundFlag = LockedFlag()

    var state: WatcherState
    var settings: WatcherSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    var payload: EnrollmentPayload?
    var storeLoad: StoreLoad = .empty
    var loginItem: LoginItemState = .notRegistered
    var loginItemError: String?
    var notificationAccess: NotificationAccess = .unavailable
    var legacy = LegacyInstall()
    var engine: EngineState = .loading
    var recognizer: RecognizerState = .needed
    @ObservationIgnored var recognizerInstaller: RecognizerInstaller?
    var cameraAccess: CameraAccess = .notDetermined
    var hasCamera = true
    var computePlans: [String: ComputePlanSummary] = [:]
    var countdownRemaining = 1.0
    /// The menu bar icon. Kept apart from `state` so the status item redraws only when the shape
    /// changes: every redraw costs about 9 ms of main-thread CPU (measured with Time Profiler).
    private(set) var menuGlyph: MenuGlyph = .watching
    var demoPresent = true
    /// Dry-run and demo events, newest first.
    var notes: [String] = []

    init(options: LaunchOptions) {
        self.options = options
        paths = AppPaths.resolve(options)
        prefs = Preferences(persistent: !options.isDemo)
        store = EnrollmentStore(url: paths.enrollment, keys: paths.makeKeyStore())
        telemetry = TelemetryLog(url: paths.log)
        let s = prefs.watcher
        settings = s
        state = WatcherState(settings: s)
    }

    var isEnrolled: Bool { payload != nil }

    // MARK: launch

    func start() {
        soundFlag.value = settings.sound
        let environment: WatchEnvironment
        if options.neverLocks {
            environment = DryRunAppEnvironment(presenter: countdownUI) { [weak self] text in Task { @MainActor in self?.note(text) } }
        } else {
            let system = SystemEnvironment(notifier: notifier, presenter: countdownUI) { [soundFlag] in soundFlag.value }
            systemEnvironment = system
            environment = system
        }
        telemetry.pruneInBackground(now: Date())
        controller = WatchController(settings: settings, recognition: RecognitionContext(gallery: Gallery(), thresholds: .uncalibrated),
                                     checks: checks, environment: environment, telemetry: telemetry)
        countdownUI.onHere = { [weak self] in self?.controller.send(.userInput) }
        countdownUI.soundOn = { [weak self] in self?.settings.sound ?? false }
        // DispatchQueue.main keeps the snapshots in order; a Task per change would not promise that.
        controller.onChange { [weak self] s in DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(s) } } }
        controller.onGalleryChange { [weak self] g in Task { @MainActor in self?.galleryAdapted(g) } }
        loadStore()
        detectLegacy()
        refreshLoginItem()
        cameraAccess = Self.currentCameraAccess(demo: options.isDemo)
        hasCamera = options.isDemo || CameraSession.preferredDevice() != nil
        refreshBlock()
        // A demo never uses the camera, so it ignores screen lock and sleep: it keeps watching the
        // stored photo even while the screen is locked (snapshots and measurements run that way).
        let locked = !options.isDemo && SessionState.current().screenIsLocked
        if locked { controller.send(.screenLocked) }
        controller.send(.start)
        if let p = Pause.restored(prefs.pause, now: Date(), screenLocked: locked) {
            controller.send(.pause(p))
        } else {
            prefs.pause = nil
        }
        controller.send(.powerSourceChanged(onBattery: PowerSource.isOnBattery))
        if !options.isDemo {
            systemEvents = SystemEventMonitor { [weak self] e in Task { @MainActor in self?.systemEvent(e) } }
            watchForCameraArrivals()
            Task { await askForNotificationsAtLaunch() }
        }
        recognizer = modelLocator.hasRecognizer ? .installed : .needed
        powerMonitor = PowerMonitor { [weak self] battery in
            self?.controller.send(.powerSourceChanged(onBattery: battery))
            self?.systemEnvironment?.powerSourceChanged(onBattery: battery)
        }
        Task { await loadEngine() }
    }

    private func systemEvent(_ e: WatcherEvent) {
        controller.send(e)
        if e == .screenUnlocked { retryKeyIfNeeded() }
    }

    /// A keychain that refused the key (locked, a prompt dismissed) gets another try at each unlock
    /// and whenever the menu opens.
    func retryKeyIfNeeded() {
        guard storeLoad == .keyUnavailable else { return }
        loadStore()
        refreshBlock()
    }

    static func currentCameraAccess(demo: Bool) -> CameraAccess {
        if demo { return .authorized }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    var modelLocator: ModelLocator { ModelLocator(installed: paths.models) }

    func loadEngine() async {
        let locator = modelLocator
        guard locator.hasRecognizer else {
            // Nothing to load until the owner accepts the licence and downloads the recognizer.
            engine = .failed
            refreshBlock()
            return
        }
        engine = .loading
        refreshBlock()
        let loaded = await Task.detached(priority: .userInitiated) { () -> FacePipeline? in
            locator.isAvailable ? try? FacePipeline(models: locator) : nil
        }.value
        pipeline = loaded
        engine = loaded == nil ? .failed : .ready
        configureWatchCamera()
        refreshBlock()
        Task { await loadComputePlans(locator) }
        if options.isDemo { await prepareDemo() }
    }

    private func loadComputePlans(_ locator: ModelLocator) async {
        for m in ModelName.allCases {
            guard let url = try? locator.url(m), let plan = try? await computePlan(url) else { continue }
            computePlans[m.rawValue] = plan
        }
    }

    /// Blocks the watcher with the most basic reason it cannot run, or lets it run. Until the
    /// models and the camera are ready it stays blocked, so no check can start against nothing.
    func refreshBlock() {
        let reason = Protection.blockReason(modelsAvailable: engine != .failed, hasCamera: hasCamera, camera: cameraAccess,
                                            store: storeLoad)
        if let reason {
            controller.send(.block(reason))
        } else if engine == .ready, checks.isSet {
            controller.send(.unblock)
        } else {
            controller.send(.block(.starting))
        }
    }

    /// Camera access can be turned on in System Settings, and a camera plugged in, while FaceLock
    /// runs; read both again whenever the menu or setup opens instead of polling.
    func refreshCameraAccess() {
        cameraAccess = Self.currentCameraAccess(demo: options.isDemo)
        if !checks.isSet { configureWatchCamera() }
        retryKeyIfNeeded()
        refreshBlock()
        Task { await refreshNotificationAccess() }
    }

    func loadStore() {
        storeLoad = store.load()
        if case let .loaded(p) = storeLoad {
            payload = p
            controller.update(recognition: p.recognition)
        } else {
            payload = nil
        }
    }

    // MARK: state

    private func apply(_ s: WatcherState) {
        guard s != state else { return }
        let pauseChanged = s.pause != state.pause
        let newCameraFailure = s.cameraFailures > state.cameraFailures
        state = s
        if pauseChanged { prefs.pause = s.pause }
        updateCountdownTicker()
        updateGlyph()
        if newCameraFailure { cameraKeepsFailing(s.cameraFailures) }
    }

    /// A check that finds you within half a second never shows the Checking icon, so a present
    /// check leaves the menu bar untouched; a longer one shows it.
    static let checkingGlyphDelay: Duration = .milliseconds(500)

    private func updateGlyph() {
        let next = state.status(now: Date()).glyph
        pendingGlyph?.cancel()
        pendingGlyph = nil
        guard next != menuGlyph else { return }
        guard next == .checking else {
            menuGlyph = next
            return
        }
        pendingGlyph = Task { [weak self] in
            try? await Task.sleep(for: Self.checkingGlyphDelay)
            guard !Task.isCancelled, let self, self.state.status(now: Date()).glyph == .checking else { return }
            self.menuGlyph = .checking
        }
    }

    /// The menu glyph's ring drains only while a countdown is up: the one timer besides the watcher's.
    private func updateCountdownTicker() {
        guard state.countdownEndsAt != nil else {
            countdownTicker?.invalidate()
            countdownTicker = nil
            if countdownRemaining != 1 { countdownRemaining = 1 }
            return
        }
        tickCountdown()
        guard countdownTicker == nil else { return }
        countdownTicker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCountdown() }
        }
    }

    private func tickCountdown() {
        guard let ends = state.countdownEndsAt else { return }
        let total = state.phase == .challenge ? WindowPolicy.challengeSeconds : Double(settings.countdownSeconds)
        countdownRemaining = max(0, ends.timeIntervalSinceNow / total)
    }

    private func settingsChanged() {
        soundFlag.value = settings.sound
        prefs.watcher = settings
        controller?.send(.settingsChanged(settings))
    }

    func note(_ text: String) {
        notes = Array(([text] + notes).prefix(5))
    }

    // MARK: menu actions

    func pause(_ choice: PauseChoice) { controller.send(.pause(choice.pause(from: Date()))) }
    func resume() { controller.send(.resume) }
    func checkNow() { controller.send(.checkNow) }

    /// A setup screen takes the camera. Each screen holds its own token, so two overlapping screens
    /// keep the watcher paused until the last one lets go.
    func beginSetup() -> SetupHold {
        setupHolders += 1
        if setupHolders == 1 { controller.send(.setupStarted) }
        return SetupHold { [weak self] in self?.endSetup() }
    }

    private func endSetup() {
        guard setupHolders > 0 else { return }
        setupHolders -= 1
        if setupHolders == 0 { controller.send(.setupEnded) }
    }

    var canCheckNow: Bool {
        state.isActive && state.activeWindow == nil && [.present, .looking, .stranger].contains(state.watchState)
    }

    // MARK: camera access

    func requestCameraAccess() async -> Bool {
        if options.isDemo { return true }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAccess = granted ? .authorized : .denied
        configureWatchCamera()
        refreshBlock()
        return granted
    }

    func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: login item

    func refreshLoginItem() {
        loginItem = options.isDemo ? .notRegistered : LoginItem().state
    }

    func setLoginItem(_ on: Bool) {
        guard !options.isDemo else { return }
        let result = LoginItem().set(on)
        loginItem = result.state
        loginItemError = result.error == nil ? nil : LoginItemState.registerFailed
    }

    // MARK: notifications

    func refreshNotificationAccess() async {
        guard !options.isDemo else { return }
        notificationAccess = await notifier.access()
    }

    func requestNotifications() async {
        guard !options.isDemo else { return }
        _ = await notifier.requestAuthorization()
        await refreshNotificationAccess()
    }

    /// Someone who finished setup but never saw the prompt (closed the window early) gets it once.
    private func askForNotificationsAtLaunch() async {
        await refreshNotificationAccess()
        guard isEnrolled, notificationAccess == .notDetermined else { return }
        await requestNotifications()
    }
}

/// One setup screen's hold on the camera. `end()` is safe to call more than once.
@MainActor
final class SetupHold {
    private var release: (() -> Void)?

    init(_ release: @escaping () -> Void) {
        self.release = release
    }

    func end() {
        release?()
        release = nil
    }
}
