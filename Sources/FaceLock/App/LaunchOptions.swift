import FaceLockCore
import FaceLockSystem
import FaceLockVision
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
    var isSnapshot: Bool { snapshotDirectory != nil }
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

/// Where FaceLock keeps its files and its key. A demo uses a throwaway folder and a key in memory;
/// `--data-dir` gets a key of its own; a DEBUG build keeps everything in FaceLock-Debug folders,
/// so no run but the release app ever reads, rewrites or deletes the real enrollment or key.
struct AppPaths: Sendable, Equatable {
    enum Key: Equatable, Sendable {
        case memory
        case file(URL)
        case keychain(account: String)
    }

    let enrollment: URL
    let log: URL
    let key: Key
    /// Where the downloaded recognizer lives: shared by every run except one with `--data-dir`.
    var models = ModelLocator.installDirectory

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// The release app's files.
    static let release = AppPaths(enrollment: EnrollmentStore.defaultURL, log: TelemetryLog.defaultURL,
                                  key: .keychain(account: KeychainKeyStore.defaultAccount))

    /// A DEBUG build's files, next to but never inside the release folders.
    static let debug: AppPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Application Support/FaceLock-Debug")
        return AppPaths(enrollment: dir.appendingPathComponent("enrollment.v2"),
                        log: home.appendingPathComponent("Library/Logs/FaceLock-Debug/checks.jsonl"),
                        key: .file(dir.appendingPathComponent("dev.key")))
    }()

    static var standard: AppPaths { isDebugBuild ? debug : release }

    static func resolve(_ o: LaunchOptions) -> AppPaths {
        guard o.isDemo || o.dataDirectory != nil else {
            let base = standard
            // A dry run watches with your enrollment but logs elsewhere, so its pretend locks never count.
            let log = o.dryRun ? FileManager.default.temporaryDirectory.appendingPathComponent("FaceLock-dry-run/checks.jsonl")
                : base.log
            return AppPaths(enrollment: base.enrollment, log: log, key: base.key)
        }
        let dir = o.dataDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceLock-demo-\(ProcessInfo.processInfo.processIdentifier)")
        let key: Key = o.isDemo ? .memory
            : isDebugBuild ? .file(dir.appendingPathComponent("dev.key"))
            : .keychain(account: KeychainKeyStore.account(forDataDirectory: dir))
        return AppPaths(enrollment: dir.appendingPathComponent("enrollment.v2"), log: dir.appendingPathComponent("checks.jsonl"),
                        key: key, models: o.dataDirectory ?? ModelLocator.installDirectory)
    }

    /// True for the release app's own files; Settings says when a run keeps its files elsewhere.
    var isRelease: Bool { self == Self.release }

    func makeKeyStore() -> KeyStore {
        switch key {
        case .memory: return InMemoryKeyStore()
        case let .file(url): return FileKeyStore(url: url)
        case let .keychain(account): return KeychainKeyStore(account: account)
        }
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
