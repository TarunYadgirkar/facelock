import Foundation

/// What the Python FaceLock (0.4) left on this Mac. Detection only: every removal asks first and
/// goes to the Trash, and that is the app's job.
public struct LegacyInstall: Equatable, Sendable {
    public var configFile: URL?
    public var launchAgent: URL?
    public var launcherApp: URL?
    public var pidFile: URL?
    /// The watcher process named by the pid file, when it is still alive.
    public var runningPID: Int32?
    public var enrollment: URL?

    public init() {}

    public var isEmpty: Bool {
        configFile == nil && launchAgent == nil && launcherApp == nil && pidFile == nil && enrollment == nil
    }
}

public enum LegacyPaths {
    public static let launchAgentLabel = "com.tarunyadgirkar.facelock"

    public static func configFile(home: URL) -> URL { home.appendingPathComponent(".config/facelock/config.toml") }
    public static func launchAgent(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }
    public static func launcherApp(home: URL) -> URL { home.appendingPathComponent("Applications/FaceLock.app") }
    public static func pidFile(home: URL) -> URL { home.appendingPathComponent(".local/state/facelock/watcher.pid") }
    public static func enrollment(home: URL) -> URL { home.appendingPathComponent(".local/share/facelock/enrollment.npz") }
}

public enum LegacyDetector {
    public static func detect(home: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                              read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) },
                              isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> LegacyInstall {
        func found(_ u: URL) -> URL? { exists(u) ? u : nil }
        var install = LegacyInstall()
        install.configFile = found(LegacyPaths.configFile(home: home))
        install.launchAgent = found(LegacyPaths.launchAgent(home: home))
        install.launcherApp = found(LegacyPaths.launcherApp(home: home))
        install.enrollment = found(LegacyPaths.enrollment(home: home))
        install.pidFile = found(LegacyPaths.pidFile(home: home))
        if let p = install.pidFile, let text = read(p), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0, isAlive(pid) {
            install.runningPID = pid
        }
        return install
    }
}

public struct LegacyConfig: Equatable, Sendable {
    public var values: [String: String] = [:]

    public func double(_ k: String) -> Double? { values[k].flatMap(Double.init) }
    public func int(_ k: String) -> Int? { values[k].flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    public func bool(_ k: String) -> Bool? { values[k].flatMap { $0 == "true" ? true : $0 == "false" ? false : nil } }
}

/// Reads the flat `key = value` TOML the Python app wrote, and maps cadence, sound and notify.
/// The old threshold is ignored: thresholds live in the enrollment store now.
public enum LegacyConfigImport {
    public static func parse(_ toml: String) -> LegacyConfig {
        var c = LegacyConfig()
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("[") else { continue }
            c.values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return c
    }

    /// The Python presets matched exactly; otherwise the nearest by check interval.
    public static func cadence(_ c: LegacyConfig) -> CadenceName? {
        guard let interval = c.double("interval") else { return nil }
        let exact = CadenceName.allCases.first { name in
            let p = Cadence.named(name)
            return interval == p.interval && c.double("recheck_interval") == p.recheckInterval
                && c.double("stranger_interval") == p.strangerInterval && c.int("confirm_checks") == p.confirmChecks
        }
        if let exact { return exact }
        return CadenceName.allCases.min { abs(Cadence.named($0).interval - interval) < abs(Cadence.named($1).interval - interval) }
    }

    public static func settings(from c: LegacyConfig, base: WatcherSettings = WatcherSettings()) -> WatcherSettings {
        var s = base
        if let name = cadence(c) { s.cadence = name }
        if let sound = c.bool("sound") { s.sound = sound }
        if let notify = c.bool("notify") { s.notify = notify }
        return s
    }
}
