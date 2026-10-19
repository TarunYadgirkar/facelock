import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public enum Display {
    /// `pmset displaysleepnow`.
    @discardableResult
    public static func sleepNow() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

public enum PowerSource {
    public static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}

/// Keeps the Mac awake after FaceLock locks it, so the lock screen stays up. AC power only: the
/// assertion is dropped as soon as the Mac switches to battery, and taken again on AC while the
/// screen is still locked.
public final class StayAwake: @unchecked Sendable {
    private var assertion: IOPMAssertionID = 0
    private var wanted = false
    private let lock = NSLock()
    private let onBattery: @Sendable () -> Bool

    public init(onBattery: @escaping @Sendable () -> Bool = { PowerSource.isOnBattery }) {
        self.onBattery = onBattery
    }

    public var isHolding: Bool { lock.withLock { assertion != 0 } }

    public func begin() {
        lock.withLock {
            wanted = true
            acquire()
        }
    }

    public func end() {
        lock.withLock {
            wanted = false
            release()
        }
    }

    public func powerSourceChanged(onBattery battery: Bool) {
        lock.withLock {
            if battery { release() } else if wanted { acquire() }
        }
    }

    private func acquire() {
        guard assertion == 0, !onBattery() else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "FaceLock keeps the lock screen up" as CFString, &assertion)
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
