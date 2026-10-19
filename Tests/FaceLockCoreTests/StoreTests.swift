import CryptoKit
import FaceLockCore
import Foundation
import Testing

func scratchDirectory() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("facelock-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func samplePayload() -> EnrollmentPayload {
    let base = unit(900)
    let ts = (0..<6).map { template(vector(near: base, cosine: 0.8, seed: $0), at: Double($0) * 5, target: "t\($0)") }
    let report = Calibrator.calibrate(Gallery(ts), now: t0)
    return EnrollmentPayload(templates: ts, thresholds: report.thresholds, calibration: report,
                             thresholdLog: [Calibrator.change(from: nil, to: report, reason: "enrollment")], createdAt: t0)
}

@Suite("Enrollment store")
struct StoreTests {
    @Test("encrypt and decrypt round trip, written 0600")
    func roundTrip() throws {
        let dir = try scratchDirectory()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: InMemoryKeyStore())
        #expect(store.load() == .empty)
        let p = samplePayload()
        try store.save(p)
        #expect(store.load() == .loaded(p))
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let raw = try Data(contentsOf: store.url)
        #expect(raw.prefix(4) == Data("FLK2".utf8))
        #expect(raw.range(of: Data("templates".utf8)) == nil)
        try store.save(p)
        #expect(store.load() == .loaded(p))
    }

    @Test("a flipped byte is detected and asks for a re-enroll")
    func tamper() throws {
        let dir = try scratchDirectory()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: InMemoryKeyStore())
        try store.save(samplePayload())
        var raw = try Data(contentsOf: store.url)
        raw[raw.count / 2] ^= 0x01
        try raw.write(to: store.url)
        #expect(store.load() == .needsReenroll(.unreadable))
    }

    @Test("a missing key leads to the re-enroll state, not a crash")
    func missingKey() throws {
        let dir = try scratchDirectory()
        let keys = InMemoryKeyStore()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: keys)
        try store.save(samplePayload())
        try keys.deleteKey()
        #expect(store.load() == .needsReenroll(.keyMissing))
        let other = EnrollmentStore(url: store.url, keys: InMemoryKeyStore(key: SymmetricKey(size: .bits256)))
        #expect(other.load() == .needsReenroll(.unreadable))
    }

    @Test("the migration hook upgrades an older schema; a newer one asks for a re-enroll")
    func migration() throws {
        let key = SymmetricKey(size: .bits256)
        let p = samplePayload()
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        var obj = try JSONSerialization.jsonObject(with: e.encode(p)) as! [String: Any]
        obj["schema"] = 0
        obj["model"] = obj.removeValue(forKey: "modelID")
        let old = try AES.GCM.seal(JSONSerialization.data(withJSONObject: obj), using: key, authenticating: EnrollmentCodec.magic)
        let file = EnrollmentCodec.magic + old.combined!
        #expect(throws: StoreError.noMigration(0)) { try EnrollmentCodec.decode(file, key: key) }
        let renamed: EnrollmentCodec.Migration = { o in o["modelID"] = o.removeValue(forKey: "model") }
        let migrated = try EnrollmentCodec.decode(file, key: key, migrations: [0: renamed])
        #expect(migrated == p)

        obj["schema"] = 99
        let newer = try AES.GCM.seal(JSONSerialization.data(withJSONObject: obj), using: key, authenticating: EnrollmentCodec.magic)
        #expect(throws: StoreError.newerSchema(99)) { try EnrollmentCodec.decode(EnrollmentCodec.magic + newer.combined!, key: key) }
    }

    @Test("an enrollment from another model asks for a re-enroll")
    func otherModel() throws {
        let dir = try scratchDirectory()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: InMemoryKeyStore())
        var p = samplePayload()
        p.modelID = "w600k_mbf"
        try store.save(p)
        #expect(store.load() == .needsReenroll(.otherModel))
    }

    @Test("the DEBUG file key round-trips at mode 0600")
    func fileKey() throws {
        let dir = try scratchDirectory()
        let keys = FileKeyStore(url: dir.appendingPathComponent("dev.key"))
        #expect(try keys.loadKey() == nil)
        let k = SymmetricKey(size: .bits256)
        try keys.saveKey(k)
        #expect(try keys.loadKey() == k)
        let mode = try FileManager.default.attributesOfItem(atPath: keys.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}

@Suite("Legacy 0.4 install")
struct LegacyTests {
    @Test("config.toml cadence, sound and notify map; the old threshold is ignored", arguments: [
        ("interval = 30.0\nrecheck_interval = 10.0\nstranger_interval = 5.0\nconfirm_checks = 3\nsound = true\nnotify = false\nthreshold = 0.42\n",
         CadenceName.balanced, true, false),
        ("# facelock config\ninterval = 15.0\nrecheck_interval = 6.0\nstranger_interval = 2.0\nconfirm_checks = 2\nsound = false\n",
         .strict, false, true),
        ("interval = 50.0\n", .relaxed, false, true),
        ("interval = 20.0\nrecheck_interval = 4.0\n", .strict, false, true),
    ])
    func config(_ toml: String, _ cadence: CadenceName, _ sound: Bool, _ notify: Bool) {
        let s = LegacyConfigImport.settings(from: LegacyConfigImport.parse(toml))
        #expect(s.cadence == cadence)
        #expect(s.sound == sound)
        #expect(s.notify == notify)
    }

    @Test("detects the old LaunchAgent, launcher, pid file and enrollment")
    func detect() throws {
        let home = try scratchDirectory()
        let files = [LegacyPaths.configFile(home: home), LegacyPaths.launchAgent(home: home), LegacyPaths.pidFile(home: home),
                     LegacyPaths.enrollment(home: home)]
        for f in files {
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("4242\n".utf8).write(to: f)
        }
        try FileManager.default.createDirectory(at: LegacyPaths.launcherApp(home: home), withIntermediateDirectories: true)
        let found = LegacyDetector.detect(home: home, isAlive: { $0 == 4242 })
        #expect(found.configFile != nil && found.launchAgent != nil && found.launcherApp != nil && found.enrollment != nil)
        #expect(found.runningPID == 4242)
        #expect(LegacyDetector.detect(home: home, isAlive: { _ in false }).runningPID == nil)
        #expect(LegacyDetector.detect(home: try scratchDirectory()).isEmpty)
    }
}

@Suite("Telemetry")
struct TelemetryTests {
    @Test("records round-trip as JSON lines with no embeddings, and the weekly summary counts")
    func summaryCounts() throws {
        let log = TelemetryLog(url: try scratchDirectory().appendingPathComponent("checks.jsonl"))
        let now = Date()
        log.record(.check(summary(.owner), kind: .regular, at: now))
        log.record(.cancel(.owner, at: now))
        log.record(.cancel(.input, at: now))
        log.record(.lock(.locked, at: now))
        log.record(.lock(.locked, at: now.addingTimeInterval(-8 * 86_400)))
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 5)
        #expect(!text.contains("embedding"))
        let s = log.weeklySummary(now: now)
        #expect(s.locks == 1)
        #expect(s.cancelledByOwner == 1 && s.cancelledByInput == 1)
        #expect(s.countdownsStopped == 2)
        #expect(s.failedLocks == 0)
        #expect(s.medianPresentOnTime == 0.4)
    }

    @Test("rotates at the size cap")
    func rotation() throws {
        let log = TelemetryLog(url: try scratchDirectory().appendingPathComponent("checks.jsonl"), maxBytes: 600)
        for i in 0..<10 { log.record(.check(summary(.away), kind: .recheck, at: Date().addingTimeInterval(Double(i)))) }
        log.flush()
        #expect(!log.rotatedFiles().isEmpty)
        #expect(log.records(since: .distantPast).count == 10)
    }
}

/// A key store whose keychain is out of reach for now, then back.
final class FlakyKeyStore: KeyStore, @unchecked Sendable {
    private let inner = InMemoryKeyStore()
    var reachable = true
    var saves = 0

    func loadKey() throws -> SymmetricKey? {
        guard reachable else { throw KeyStoreError.unavailable(-25308) }
        return try inner.loadKey()
    }

    func saveKey(_ key: SymmetricKey) throws {
        saves += 1
        try inner.saveKey(key)
    }

    func deleteKey() throws { try inner.deleteKey() }
}

@Suite("Enrollment key")
struct KeyTests {
    @Test("a keychain that refuses for now is retryable, never a re-enroll, and saving never replaces the key")
    func unavailableKey() throws {
        let dir = try scratchDirectory()
        let keys = FlakyKeyStore()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: keys)
        let p = samplePayload()
        try store.save(p)
        keys.reachable = false
        #expect(store.load() == .keyUnavailable)
        #expect(throws: KeyStoreError.unavailable(-25308)) { try store.save(p) }
        #expect(keys.saves == 1)
        keys.reachable = true
        #expect(store.load() == .loaded(p))
    }

    @Test("key stores never overwrite an existing key")
    func neverReplace() throws {
        let mem = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        #expect(throws: KeyStoreError.exists) { try mem.saveKey(SymmetricKey(size: .bits256)) }
        let file = FileKeyStore(url: try scratchDirectory().appendingPathComponent("dev.key"))
        try file.saveKey(SymmetricKey(size: .bits256))
        #expect(throws: KeyStoreError.exists) { try file.saveKey(SymmetricKey(size: .bits256)) }
    }

    @Test("a key that isn't 256 bits asks for a re-enroll and is replaced on the next save")
    func corruptKey() throws {
        let dir = try scratchDirectory()
        let keys = FileKeyStore(url: dir.appendingPathComponent("dev.key"))
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: keys)
        let p = samplePayload()
        try store.save(p)
        try Data(repeating: 7, count: 5).write(to: keys.url)
        #expect(store.load() == .needsReenroll(.keyMissing))
        try store.save(p)
        #expect(store.load() == .loaded(p))
    }

    @Test("the enrollment is excluded from Time Machine")
    func excludedFromBackup() throws {
        let dir = try scratchDirectory()
        let store = EnrollmentStore(url: dir.appendingPathComponent("enrollment.v2"), keys: InMemoryKeyStore())
        try store.save(samplePayload())
        let values = try store.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

@Suite("Telemetry retention")
struct RetentionTests {
    @Test("records older than 30 days go at launch, with no size-triggered rotation")
    func pruneAtLaunch() throws {
        let dir = try scratchDirectory()
        let log = TelemetryLog(url: dir.appendingPathComponent("checks.jsonl"))
        let now = Date()
        let old = now.addingTimeInterval(-31 * 86_400)
        let rotated = dir.appendingPathComponent("checks.\(Int(old.timeIntervalSince1970)).jsonl")
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        func line(_ r: CheckRecord) throws -> String { String(decoding: try e.encode(r), as: UTF8.self) + "\n" }
        try (try line(.lock(.locked, at: old))).write(to: rotated, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: rotated.path)
        try (try line(.lock(.locked, at: old)) + line(.lock(.failed, at: now.addingTimeInterval(-86_400))))
            .write(to: log.url, atomically: true, encoding: .utf8)
        log.prune(now: now)
        #expect(!FileManager.default.fileExists(atPath: rotated.path))
        let kept = log.records(since: .distantPast)
        #expect(kept.count == 1)
        #expect(kept.first?.outcome == .failed)
        let mode = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("the first write of a new day prunes too")
    func pruneOnFirstWriteOfDay() throws {
        let dir = try scratchDirectory()
        let log = TelemetryLog(url: dir.appendingPathComponent("checks.jsonl"))
        let now = Date()
        log.record(.lock(.locked, at: now.addingTimeInterval(-40 * 86_400)))
        log.flush()
        log.record(.lock(.locked, at: now))
        log.flush()
        #expect(log.records(since: .distantPast).count == 1)
    }

    @Test("failed locks count separately from dry runs")
    func failedLocks() {
        let now = Date()
        let s = TelemetrySummary([.lock(.failed, at: now), .lock(.displaySleptOnly, at: now), .lock(.dryRun, at: now),
                                  .lock(.locked, at: now)])
        #expect(s.locks == 1)
        #expect(s.failedLocks == 2)
    }
}
