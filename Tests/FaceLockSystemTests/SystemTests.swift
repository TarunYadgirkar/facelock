import FaceLockCore
import FaceLockSystem
import Foundation
import ServiceManagement
import Testing

final class FakeLoginService: LoginService {
    var status: SMAppService.Status
    var next: SMAppService.Status
    var fails = false

    init(status: SMAppService.Status, next: SMAppService.Status) {
        self.status = status
        self.next = next
    }

    func register() throws {
        if fails { throw NSError(domain: "test", code: 1) }
        status = next
    }

    func unregister() throws { status = .notRegistered }
}

@Suite("System")
struct SystemTests {
    @Test("SACLockScreenImmediate resolves (never called)")
    func lockSymbol() {
        #expect(LockAPI.symbolResolves)
    }

    @Test("login item status maps from SMAppService", arguments: [
        (SMAppService.Status.enabled, LoginItemState.enabled),
        (.requiresApproval, .requiresApproval),
        (.notRegistered, .notRegistered),
        (.notFound, .notFound),
    ])
    func statusMapping(_ s: SMAppService.Status, _ expected: LoginItemState) {
        #expect(LoginItem.map(s) == expected)
    }

    @Test("the toggle reports what macOS says after registering, not what was asked")
    func toggleReflectsStatus() {
        let approval = FakeLoginService(status: .notRegistered, next: .requiresApproval)
        let item = LoginItem(service: approval)
        #expect(item.set(true) == .requiresApproval)
        #expect(!item.state.isOn)
        #expect(item.state.detail == "Approve in System Settings > General > Login Items")
        let failing = FakeLoginService(status: .notRegistered, next: .enabled)
        failing.fails = true
        #expect(LoginItem(service: failing).set(true) == .notRegistered)
        let ok = FakeLoginService(status: .notRegistered, next: .enabled)
        #expect(LoginItem(service: ok).set(true) == .enabled)
        #expect(LoginItem(service: ok).set(false) == .notRegistered)
    }

    @Test("session dictionary parsing")
    func sessionParsing() {
        let locked = SessionState.parse(["CGSSessionScreenIsLocked": true, "kCGSSessionOnConsoleKey": NSNumber(value: 1),
                                         "kCGSSessionUserNameKey": "someone"])
        #expect(locked == SessionInfo(screenIsLocked: true, onConsole: true, userName: "someone"))
        let open = SessionState.parse(["kCGSSessionOnConsoleKey": true])
        #expect(!open.screenIsLocked)
        #expect(SessionState.parse([:]) == SessionInfo(screenIsLocked: false, onConsole: false, userName: nil))
    }

    @Test("the input monitor reports the first input after it starts")
    func inputMonitor() async throws {
        let clock = FakeIdle()
        let monitor = InputMonitor(idle: { clock.idle })
        let fired = Flag()
        monitor.start { fired.set() }
        try await Task.sleep(for: .milliseconds(350))
        #expect(!fired.value)
        clock.idle = 0
        try await Task.sleep(for: .milliseconds(350))
        #expect(fired.value)
        monitor.stop()
    }

    @Test("notification wording for each notice")
    func notices() {
        #expect(Notifier.text(for: .lockFailed(.failed)).title == "FaceLock couldn't lock your Mac")
        #expect(Notifier.text(for: .someoneElseInView).title == "Someone else is in view")
        #expect(Notifier.text(for: .stillFaceFlagged(observeOnly: true)).body.contains("Nothing was locked"))
    }
}

final class FakeIdle: @unchecked Sendable {
    var idle: TimeInterval = 1000
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}
