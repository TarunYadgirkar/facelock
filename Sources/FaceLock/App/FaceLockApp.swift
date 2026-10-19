import AppKit
import SwiftUI
import UserNotifications

@main
struct FaceLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(AppDelegate.model)
                .environment(AppDelegate.windows)
        } label: {
            MenuBarLabel().environment(AppDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static let options = LaunchOptions.parse(CommandLine.arguments)
    @MainActor static let model = AppModel(options: options)
    @MainActor static let windows = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let options = Self.options
            if !options.isDemo, Self.anotherInstanceIsRunning() {
                NSApp.terminate(nil)
                return
            }
            if Bundle.main.bundleIdentifier != nil, !options.isDemo { UNUserNotificationCenter.current().delegate = self }
            Self.windows.model = Self.model
            Self.model.start()
            if let dir = options.snapshotDirectory {
                Task { await Snapshotter(model: Self.model, windows: Self.windows, directory: dir).run() }
                return
            }
            if options.showSetup || (!Self.model.isEnrolled && !options.demoEnrolled) {
                Self.windows.openSetup()
            }
        }
    }

    /// Two FaceLocks would fight over the camera.
    @MainActor private static func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me }) else { return false }
        other.activate()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
