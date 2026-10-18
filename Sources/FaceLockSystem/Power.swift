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

/// Keeps the Mac awake after FaceLock locks it, so the lock screen stays up. AC power only.
public final class StayAwake: @unchecked Sendable {
    private var assertion: IOPMAssertionID = 0
    private let lock = NSLock()

    public init() {}

    public func begin() {
        lock.withLock {
            guard assertion == 0, !PowerSource.isOnBattery else { return }
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "FaceLock keeps the lock screen up" as CFString, &assertion)
        }
    }

    public func end() {
        lock.withLock {
            guard assertion != 0 else { return }
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
