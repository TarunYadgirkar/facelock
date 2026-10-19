import FaceLockCapture
import FaceLockCore
import FaceLockVision
import Foundation

/// The watcher's camera and what FaceLock knows about it.
@MainActor
final class WatchCameraState {
    var session: CameraSession?
    var stored: StoredImageCamera?
    var monitor: CameraAvailabilityMonitor?
    var arrivals: CameraArrivalMonitor?
    /// The session's camera disconnected: its input stays dead even if the same camera comes back.
    var lost = false
    var rebuilding = false
    var rebuildAgain = false
    var failedProbes = 0
    var retry: Task<Void, Never>?
}

/// Camera availability comes from the watcher's own camera only: connected and not suspended.
/// When that camera goes away, fails at runtime or stops sending frames, FaceLock builds a new
/// session on the preferred camera and reports it available only after it delivered a frame.
extension AppModel {
    static let probeTimeout: TimeInterval = 5
    static let rebuildRetryBase: TimeInterval = 30
    static let rebuildRetryCap: TimeInterval = 600
    /// After the first rebuild, the watcher's camera failures trigger another one every this many.
    static let rebuildEvery = 3

    /// The watcher's camera: configured once, stopped between checks. Only after access is
    /// granted, so creating it never raises the permission prompt.
    func configureWatchCamera() {
        guard let pipeline, !checks.isSet else { return }
        if let url = options.demoCamera {
            guard let cam = try? StoredImageCamera(image: url) else { return }
            camera.stored = cam
            demoScene.observe { present in try? cam.show(present ? url : nil) }
            checks.set(CheckRunner(source: cam, pipeline: pipeline))
            return
        }
        guard cameraAccess == .authorized, !camera.rebuilding else { return }
        guard let device = CameraSession.preferredDevice(), let cam = try? CameraSession(device: device) else {
            hasCamera = false
            return
        }
        hasCamera = true
        install(cam, pipeline: pipeline)
    }

    func watchForCameraArrivals() {
        camera.arrivals = CameraArrivalMonitor { [weak self] in Task { @MainActor in self?.cameraArrived() } }
    }

    /// The watcher had windows in a row with no usable frame: the session may be dead although
    /// macOS still lists the camera.
    func cameraKeepsFailing(_ failures: Int) {
        let limit = WatcherState.cameraFailureLimit
        guard !options.isDemo, failures >= limit, (failures - limit) % Self.rebuildEvery == 0 else { return }
        rebuildWatchCamera()
    }

    /// Replaces the watcher's camera with the preferred one. The watcher waits ("Waiting for the
    /// camera") until the new session has delivered a frame.
    func rebuildWatchCamera() {
        guard !options.isDemo, let pipeline, cameraAccess == .authorized else { return }
        guard !camera.rebuilding else {
            camera.rebuildAgain = true
            return
        }
        camera.rebuilding = true
        camera.retry?.cancel()
        controller.send(.cameraAvailable(false))
        checks.set(nil)
        camera.monitor = nil
        camera.session?.onRuntimeError = nil
        camera.session = nil
        Task { await finishRebuild(pipeline) }
    }

    private func install(_ cam: CameraSession, pipeline: FacePipeline) {
        camera.session = cam
        camera.lost = false
        checks.set(CheckRunner(source: cam, pipeline: pipeline))
        cam.onRuntimeError = { [weak self] in Task { @MainActor in self?.cameraBroke() } }
        camera.monitor = CameraAvailabilityMonitor(device: cam.device) { [weak self] state in
            Task { @MainActor in self?.cameraDeviceChanged(state) }
        }
    }

    private func cameraDeviceChanged(_ st: CameraAvailabilityMonitor.DeviceState) {
        guard !camera.rebuilding, let session = camera.session, session.device.uniqueID == st.deviceID else { return }
        if !st.connected {
            camera.lost = true
            controller.send(.cameraAvailable(false))
            return rebuildWatchCamera()
        }
        if camera.lost { return rebuildWatchCamera() }
        if st.suspended {
            controller.send(.cameraAvailable(false))
            if otherUsableCamera() { rebuildWatchCamera() }
            return
        }
        controller.send(.cameraAvailable(true))
    }

    private func cameraArrived() {
        guard !options.isDemo else { return }
        guard let session = camera.session else { return rebuildWatchCamera() }
        if camera.lost || !CameraSession.isUsable(session.device) { rebuildWatchCamera() }
    }

    private func cameraBroke() {
        guard camera.session != nil else { return }
        camera.lost = true
        controller.send(.cameraAvailable(false))
        rebuildWatchCamera()
    }

    private func otherUsableCamera() -> Bool {
        guard let d = CameraSession.preferredDevice() else { return false }
        return CameraSession.isUsable(d) && d.uniqueID != camera.session?.device.uniqueID
    }

    private func finishRebuild(_ pipeline: FacePipeline) async {
        let available = await rebuildSession(pipeline)
        camera.rebuilding = false
        refreshBlock()
        if available { controller.send(.cameraAvailable(true)) }
        if camera.rebuildAgain {
            camera.rebuildAgain = false
            rebuildWatchCamera()
        }
    }

    /// True once the new session has delivered a frame. A suspended camera is installed without a
    /// probe: its monitor reports when the lid opens.
    private func rebuildSession(_ pipeline: FacePipeline) async -> Bool {
        guard let device = CameraSession.preferredDevice() else {
            hasCamera = false
            return false
        }
        hasCamera = true
        guard let cam = try? CameraSession(device: device) else {
            scheduleRebuildRetry()
            return false
        }
        install(cam, pipeline: pipeline)
        guard CameraSession.isUsable(device) else { return false }
        guard await cam.probe(timeout: Self.probeTimeout) else {
            scheduleRebuildRetry()
            return false
        }
        camera.failedProbes = 0
        return true
    }

    private func scheduleRebuildRetry() {
        camera.failedProbes += 1
        let delay = min(Self.rebuildRetryCap, Self.rebuildRetryBase * pow(2, Double(camera.failedProbes - 1)))
        camera.retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.rebuildWatchCamera()
        }
    }
}
