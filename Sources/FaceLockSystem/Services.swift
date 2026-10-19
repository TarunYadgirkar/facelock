import AppKit
import CryptoKit
import FaceLockCore
import Foundation
import LocalAuthentication
import Security
import UserNotifications

/// The enrollment key in the login keychain (the file-based keychain macOS keeps per user).
/// FaceLock reads it without a prompt while you are logged in. macOS ignores "this device only"
/// for this keychain, so the item can travel with the keychain to a new Mac; the enrollment file
/// itself is excluded from Time Machine.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public static let service = "com.tarunyadgirkar.facelock.enrollment"
    public static let defaultAccount = "enrollment.v2"
    public let account: String
    private let interactive: Bool

    /// `interactive: false` never shows a keychain prompt: a tool reading the app's item fails
    /// at once with `KeyStoreError.unavailable` instead.
    public init(account: String = KeychainKeyStore.defaultAccount, interactive: Bool = true) {
        self.account = account
        self.interactive = interactive
    }

    /// A key of its own for a `--data-dir` run, so deleting that run's data never touches the real key.
    public static func account(forDataDirectory dir: URL) -> String {
        let digest = SHA256.hash(data: Data(dir.standardizedFileURL.path.utf8))
        return defaultAccount + "." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func loadKey() throws -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = interactive ? SecItemCopyMatching(q as CFDictionary, &out) : Self.withoutPrompts {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
            return SecItemCopyMatching(q as CFDictionary, &out)
        }
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, data.count == 32 else { throw KeyStoreError.corrupt }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.unavailable(status)
        }
    }

    /// Adds the key; an existing item is never overwritten.
    public func saveKey(_ key: SymmetricKey) throws {
        var q = query
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.exists }
        guard status == errSecSuccess else { throw KeyStoreError.unavailable(status) }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyStoreError.unavailable(status) }
    }

    /// The file-based keychain ignores LAContext.interactionNotAllowed for its access-control
    /// prompt ("facelock-bench wants to use your confidential information"); this switch is the
    /// one that makes it fail instead of asking.
    private static func withoutPrompts(_ body: () -> OSStatus) -> OSStatus {
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}

public enum NotificationAccess: Sendable, Equatable {
    /// A bare binary without a bundle can't post at all.
    case unavailable, notDetermined, allowed, denied
}

/// Banners attributed to FaceLock. Needs a bundled app; a bare CLI gets nothing.
public final class Notifier: @unchecked Sendable {
    public init() {}

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    public func requestAuthorization() async -> Bool {
        (try? await center?.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func access() async -> NotificationAccess {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// System Settings > Notifications > FaceLock.
    public static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.tarunyadgirkar.facelock"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    public func post(title: String, body: String, sound: Bool) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    public static func text(for n: Notice) -> (title: String, body: String) {
        switch n {
        case .someoneElseInView:
            return ("Someone else is in view", "FaceLock sees another face next to yours.")
        case let .lockFailed(outcome):
            return outcome == .displaySleptOnly
                ? ("FaceLock couldn't lock your Mac", "The display went to sleep instead. It locks only if a password is required immediately after sleep.")
                : ("FaceLock couldn't lock your Mac", "Lock it with Control-Command-Q.")
        case let .stillFaceFlagged(observeOnly):
            return observeOnly
                ? ("A face stayed perfectly still", "FaceLock noted it in the log. Nothing was locked.")
                : ("Turn your head", "FaceLock saw a face that stayed perfectly still.")
        }
    }
}

/// "Teach a new look" starts with Touch ID or the login password.
public enum OwnerAuthentication {
    public static func confirm(reason: String = "teach FaceLock a new look") async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
