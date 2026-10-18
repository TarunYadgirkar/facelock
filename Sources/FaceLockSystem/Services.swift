import CryptoKit
import FaceLockCore
import Foundation
import LocalAuthentication
import Security
import UserNotifications

/// The enrollment key in the login keychain, this device only, readable while unlocked.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    public static let service = "com.tarunyadgirkar.facelock.enrollment"
    private let account: String
    private let interactive: Bool

    /// `interactive: false` never shows a keychain prompt (a tool reading the app's item fails instead).
    public init(account: String = "enrollment.v2", interactive: Bool = true) {
        self.account = account
        self.interactive = interactive
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func loadKey() throws -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        if !interactive {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public func saveKey(_ key: SymmetricKey) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func deleteKey() throws {
        SecItemDelete(query as CFDictionary)
    }
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
