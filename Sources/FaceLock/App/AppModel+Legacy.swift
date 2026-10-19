import AppKit
import FaceLockCore

/// The Python FaceLock (0.4) on this Mac. Every step is a button the owner presses, and every
/// removal goes to the Trash.
enum LegacyItem: String, CaseIterable, Identifiable, Sendable {
    case runningWatcher, loginItem, launcher, config, enrollment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runningWatcher: return "The old FaceLock is running"
        case .loginItem: return "The old login item is still installed"
        case .launcher: return "The old launcher is in ~/Applications"
        case .config: return "Your old settings can come along"
        case .enrollment: return "The old face data is no longer used"
        }
    }

    var detail: String {
        switch self {
        case .runningWatcher: return "Two apps would fight over the camera. Quit it before you go on."
        case .loginItem: return "It starts the old version at login. FaceLock removes it and moves its file to the Trash."
        case .launcher: return "The 8 KB launcher for the old version. FaceLock moves it to the Trash."
        case .config: return "Imports how often to check, sound and notifications from ~/.config/facelock/config.toml."
        case .enrollment: return "The new recognizer can't read it. FaceLock moves enrollment.npz to the Trash."
        }
    }

    var action: String {
        switch self {
        case .runningWatcher: return "Quit Old Version"
        case .loginItem: return "Remove"
        case .launcher, .enrollment: return "Move to Trash"
        case .config: return "Import"
        }
    }
}

extension AppModel {
    func detectLegacy() {
        guard !options.isDemo else { return }
        var l = LegacyDetector.detect(home: FileManager.default.homeDirectoryForCurrentUser)
        if let app = l.launcherApp, !LegacyCheck.isOldLauncher(app, running: Bundle.main.bundleURL) { l.launcherApp = nil }
        if let pid = l.runningPID, !LegacyCheck.isOldWatcher(pid: pid) { l.runningPID = nil }
        legacy = l
    }

    /// Items still to offer. The old enrollment waits until the new one exists.
    var legacyItems: [LegacyItem] {
        let handled = prefs.legacyHandled
        var items: [LegacyItem] = []
        if legacy.runningPID != nil { items.append(.runningWatcher) }
        if legacy.launchAgent != nil { items.append(.loginItem) }
        if legacy.launcherApp != nil { items.append(.launcher) }
        if legacy.configFile != nil, !handled.contains(LegacyItem.config.rawValue) { items.append(.config) }
        if legacy.enrollment != nil, isEnrolled { items.append(.enrollment) }
        return items
    }

    var setupLegacyItems: [LegacyItem] { legacyItems.filter { $0 != .enrollment } }

    func perform(_ item: LegacyItem) async throws {
        let fm = FileManager.default
        switch item {
        case .runningWatcher:
            if let pid = legacy.runningPID, LegacyCheck.isOldWatcher(pid: pid) { kill(pid, SIGTERM) }
        case .loginItem:
            guard let plist = legacy.launchAgent else { break }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())", plist.path]
            try? p.run()
            p.waitUntilExit()
            try fm.trashItem(at: plist, resultingItemURL: nil)
        case .launcher:
            if let app = legacy.launcherApp { try fm.trashItem(at: app, resultingItemURL: nil) }
        case .config:
            if let url = legacy.configFile, let text = try? String(contentsOf: url, encoding: .utf8) {
                settings = LegacyConfigImport.settings(from: LegacyConfigImport.parse(text), base: settings)
            }
            prefs.legacyHandled.insert(LegacyItem.config.rawValue)
        case .enrollment:
            if let npz = legacy.enrollment { try fm.trashItem(at: npz, resultingItemURL: nil) }
        }
        if item == .runningWatcher { try? await Task.sleep(for: .milliseconds(500)) }
        detectLegacy()
    }
}
