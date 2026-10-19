import Foundation
import ServiceManagement

public enum LoginItemState: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    public var isOn: Bool { self == .enabled }

    /// Shown under the "Start at login" toggle, so it never claims more than macOS reports.
    public var detail: String? {
        switch self {
        case .enabled, .notRegistered: return nil
        case .requiresApproval: return "Approve in System Settings > General > Login Items"
        case .notFound: return "Move FaceLock to the Applications folder, then turn this on."
        }
    }

    /// When macOS refuses to register: almost always an app run from Downloads or the disk image.
    public static let registerFailed = "macOS didn't add FaceLock to Login Items. Move FaceLock to Applications and try again."
}

public protocol LoginService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginService {}

public final class LoginItem {
    private let service: LoginService

    public init(service: LoginService = SMAppService.mainApp) {
        self.service = service
    }

    public static func map(_ s: SMAppService.Status) -> LoginItemState {
        switch s {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public var state: LoginItemState { Self.map(service.status) }

    /// Registers or unregisters, then reports what macOS says rather than what was asked, with
    /// the error when macOS refused.
    @discardableResult
    public func set(_ on: Bool) -> (state: LoginItemState, error: Error?) {
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            return (state, error)
        }
        return (state, nil)
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
