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
    @ObservationIgnored private let checks = SwitchableChecks()
    @ObservationIgnored private var systemEvents: SystemEventMonitor?
    @ObservationIgnored private var cameraMonitor: CameraAvailabilityMonitor?
    @ObservationIgnored private var powerMonitor: PowerMonitor?
    @ObservationIgnored private(set) var pipeline: FacePipeline?
    @ObservationIgnored private var watchCamera: CameraSession?
    @ObservationIgnored private var storedCamera: StoredImageCamera?
    @ObservationIgnored private var countdownTicker: Timer?
    /// Read by notifications on the watcher's queue, so it can't live on the main actor.
    @ObservationIgnored private let soundFlag = LockedFlag()

    var state: WatcherState
    var settings: WatcherSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    var payload: EnrollmentPayload?
    var storeLoad: StoreLoad = .empty
    var loginItem: LoginItemState = .notRegistered
    var legacy = LegacyInstall()
    var engine: EngineState = .loading
    var cameraAccess: CameraAccess = .notDetermined
    var hasCamera = true
    var computePlans: [String: ComputePlanSummary] = [:]
    var countdownRemaining = 1.0
    var demoPresent = true
    /// Dry-run and demo events, newest first.
    var notes: [String] = []

    init(options: LaunchOptions) {
        self.options = options
        paths = AppPaths.resolve(options)
        prefs = Preferences(persistent: !options.isDemo)
        let keys: KeyStore = options.isDemo ? InMemoryKeyStore() : KeyStores.standard()
        store = EnrollmentStore(url: paths.enrollment, keys: keys)
        telemetry = TelemetryLog(url: paths.log)
        let s = prefs.watcher
        settings = s
        state = WatcherState(settings: s)
    }

    var isEnrolled: Bool { payload != nil }

    // MARK: launch

    func start() {
        soundFlag.value = settings.sound
        let environment: WatchEnvironment = options.neverLocks
            ? DryRunAppEnvironment(presenter: countdownUI) { [weak self] text in Task { @MainActor in self?.note(text) } }
            : SystemEnvironment(notifier: notifier, presenter: countdownUI) { [soundFlag] in soundFlag.value }
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
        hasCamera = options.isDemo || CameraSession.defaultDevice() != nil
        refreshBlock()
        // A demo never uses the camera, so it ignores screen lock and sleep: it keeps watching the
        // stored photo even while the screen is locked (snapshots and measurements run that way).
        if !options.isDemo, SessionState.current().screenIsLocked { controller.send(.screenLocked) }
        controller.send(.start)
        if let p = Pause.restored(prefs.pause, now: Date()) { controller.send(.pause(p)) }
        controller.send(.powerSourceChanged(onBattery: PowerSource.isOnBattery))
        if !options.isDemo {
            systemEvents = SystemEventMonitor { [weak self] e in Task { @MainActor in self?.controller.send(e) } }
        }
        powerMonitor = PowerMonitor { [weak self] battery in self?.controller.send(.powerSourceChanged(onBattery: battery)) }
        Task { await loadEngine() }
    }

    static func currentCameraAccess(demo: Bool) -> CameraAccess {
        if demo { return .authorized }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private func loadEngine() async {
        let locator = ModelLocator()
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

    /// The watcher's camera: configured once, stopped between checks. Only after access is
    /// granted, so creating it never raises the permission prompt.
    func configureWatchCamera() {
        guard let pipeline, !checks.isSet else { return }
        if let url = options.demoCamera {
            guard let cam = try? StoredImageCamera(image: url) else { return }
            storedCamera = cam
            demoScene.observe { present in try? cam.show(present ? url : nil) }
            checks.set(CheckRunner(source: cam, pipeline: pipeline))
            return
        }
        guard cameraAccess == .authorized else { return }
        do {
            let cam = try CameraSession()
            watchCamera = cam
            checks.set(CheckRunner(source: cam, pipeline: pipeline))
            cameraMonitor = CameraAvailabilityMonitor(device: cam.device) { [weak self] ok in
                Task { @MainActor in self?.controller.send(.cameraAvailable(ok)) }
            }
        } catch {
            hasCamera = false
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

    /// Camera access can be turned on in System Settings while FaceLock runs; read it again
    /// whenever the menu or setup opens instead of polling.
    func refreshCameraAccess() {
        let now = Self.currentCameraAccess(demo: options.isDemo)
        guard now != cameraAccess else { return }
        cameraAccess = now
        configureWatchCamera()
        refreshBlock()
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
        state = s
        if pauseChanged { prefs.pause = s.pause }
        updateCountdownTicker()
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
    func beginSetup() { controller.send(.setupStarted) }
    func endSetup() { controller.send(.setupEnded) }

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
        loginItem = LoginItem().set(on)
    }
}
