import FaceLockCore
import Foundation

/// Command-line switches. `--demo-camera` swaps the camera for a stored image and always means a
/// dry run: the lock call is never reachable, and nothing touches the real enrollment, settings,
/// login item, keychain or notifications.
struct LaunchOptions: Sendable, Equatable {
    var demoCamera: URL?
    var dryRun = false
    /// With a demo camera: enroll the stored face at launch, so the watcher starts at once.
    var demoEnrolled = false
    /// With a demo camera: empty the scene after this many seconds to walk through the lock.
    var demoLeaveAfter: TimeInterval?
    var dataDirectory: URL?
    /// Renders the UI to PNGs in this folder and quits (needs a demo camera).
    var snapshotDirectory: URL?
    var showSetup = false

    var isDemo: Bool { demoCamera != nil }
    var neverLocks: Bool { dryRun || isDemo }

    static func parse(_ argv: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var it = argv.dropFirst().makeIterator()
        func path(_ s: String?) -> URL? { s.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } }
        while let a = it.next() {
            switch a {
            case "--demo-camera": o.demoCamera = path(it.next())
            case "--dry-run": o.dryRun = true
            case "--demo-enrolled": o.demoEnrolled = true
            case "--demo-leave-after": o.demoLeaveAfter = it.next().flatMap(Double.init)
            case "--data-dir": o.dataDirectory = path(it.next())
            case "--snapshot": o.snapshotDirectory = path(it.next())
            case "--setup": o.showSetup = true
            default: continue
            }
        }
        if o.snapshotDirectory != nil, o.demoCamera == nil { o.snapshotDirectory = nil }
        return o
    }
}

/// Where FaceLock keeps its files. A demo run uses a throwaway folder, never the real ones.
struct AppPaths: Sendable {
    let enrollment: URL
    let log: URL
    let demoKey: Bool

    static func resolve(_ o: LaunchOptions) -> AppPaths {
        guard o.isDemo || o.dataDirectory != nil else {
            return AppPaths(enrollment: EnrollmentStore.defaultURL, log: TelemetryLog.defaultURL, demoKey: false)
        }
        let dir = o.dataDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceLock-demo-\(ProcessInfo.processInfo.processIdentifier)")
        return AppPaths(enrollment: dir.appendingPathComponent("enrollment.v2"),
                        log: dir.appendingPathComponent("checks.jsonl"), demoKey: o.isDemo)
    }
}

/// Settings, the pause and one-time flags. UserDefaults for the real app, memory for a demo.
@MainActor
final class Preferences {
    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    init(persistent: Bool) {
        defaults = persistent ? .standard : nil
    }

    private func data(_ key: String) -> Data? { defaults?.data(forKey: key) ?? memory[key] as? Data }

    private func set(_ value: Any?, _ key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }

    private func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        data(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, key)
    }

    var watcher: WatcherSettings {
        get { decode("watcherSettings", WatcherSettings.self) ?? WatcherSettings() }
        set { encode(newValue, "watcherSettings") }
    }

    var pause: Pause? {
        get { decode("pause", Pause.self) }
        set { encode(newValue, "pause") }
    }

    var legacyHandled: Set<String> {
        get { Set(decode("legacyHandled", [String].self) ?? []) }
        set { encode(Array(newValue).sorted(), "legacyHandled") }
    }

    var lightPromptDismissed: Bool {
        get { defaults?.bool(forKey: "lightPromptDismissed") ?? (memory["lightPromptDismissed"] as? Bool ?? false) }
        set { set(newValue, "lightPromptDismissed") }
    }
}
