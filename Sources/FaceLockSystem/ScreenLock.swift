import CoreGraphics
import FaceLockCore
import Foundation

/// SACLockScreenImmediate from the private login framework, resolved with dlopen/dlsym. Fine
/// for a Developer ID app; not allowed on the App Store.
public enum LockAPI {
    public static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    public static let symbol = "SACLockScreenImmediate"
    typealias LockFunction = @convention(c) () -> Int32

    static func resolve() -> LockFunction? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY), let sym = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(sym, to: LockFunction.self)
    }

    /// For Diagnostics: the symbol resolves. Never calls it.
    public static var symbolResolves: Bool { resolve() != nil }
}

public struct SessionInfo: Equatable, Sendable {
    public let screenIsLocked: Bool
    public let onConsole: Bool
    public let userName: String?

    public init(screenIsLocked: Bool, onConsole: Bool, userName: String?) {
        self.screenIsLocked = screenIsLocked
        self.onConsole = onConsole
        self.userName = userName
    }
}

public enum SessionState {
    public static func parse(_ d: [String: Any]) -> SessionInfo {
        func flag(_ k: String) -> Bool {
            if let b = d[k] as? Bool { return b }
            if let n = d[k] as? NSNumber { return n.boolValue }
            return false
        }
        return SessionInfo(screenIsLocked: flag("CGSSessionScreenIsLocked"), onConsole: flag("kCGSSessionOnConsoleKey"),
                           userName: d["kCGSSessionUserNameKey"] as? String)
    }

    public static func current() -> SessionInfo {
        parse(CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
    }
}

public final class ScreenLocker: @unchecked Sendable {
    public static let confirmWithin: TimeInterval = 2
    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.lock", qos: .userInitiated)

    public init() {}

    /// Locks, then confirms CGSSessionScreenIsLocked within 2 s. On failure the display sleeps,
    /// which locks only when "require password immediately" is set.
    public func lock(completion: @escaping @Sendable (LockOutcome) -> Void) {
        queue.async {
            if let fn = LockAPI.resolve() {
                _ = fn()
                let deadline = Date().addingTimeInterval(Self.confirmWithin)
                while Date() < deadline {
                    if SessionState.current().screenIsLocked { return completion(.locked) }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            completion(Display.sleepNow() ? .displaySleptOnly : .failed)
        }
    }
}
