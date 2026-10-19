import CryptoKit
import Foundation

/// The decrypted contents of enrollment.v2.
public struct EnrollmentPayload: Equatable, Sendable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    public var modelID: String
    public var templates: [Template]
    public var thresholds: Thresholds
    public var calibration: CalibrationReport?
    public var thresholdLog: [ThresholdChange]
    public var createdAt: Date

    public init(templates: [Template], thresholds: Thresholds, calibration: CalibrationReport?,
                thresholdLog: [ThresholdChange] = [], createdAt: Date = Date(),
                modelID: String = ModelCalibration.modelID) {
        schema = Self.currentSchema
        self.modelID = modelID
        self.templates = templates
        self.thresholds = thresholds
        self.calibration = calibration
        self.thresholdLog = thresholdLog
        self.createdAt = createdAt
    }

    public var gallery: Gallery { Gallery(templates) }

    public var recognition: RecognitionContext {
        RecognitionContext(gallery: gallery, thresholds: thresholds,
                           sharpnessFloor: QualityGate.sharpnessFloor(enrollmentP5: gallery.sharpnessP5))
    }
}

public enum ReenrollReason: String, Equatable, Sendable {
    case keyMissing, unreadable, newerSchema, otherModel
}

public enum StoreLoad: Equatable, Sendable {
    case empty
    case loaded(EnrollmentPayload)
    case needsReenroll(ReenrollReason)
    /// The key exists but the keychain would not hand it over right now; try again later.
    case keyUnavailable
}

public enum StoreError: Error, Equatable {
    case badHeader, newerSchema(Int), noMigration(Int)
}

public enum KeyStoreError: Error, Equatable {
    /// The store would not hand the key over now (keychain locked, a refused prompt): retry later.
    case unavailable(Int32)
    /// A key is stored but is not a 256-bit key, so it cannot decrypt anything.
    case corrupt
    /// Saving would replace an existing key; only an explicit delete may remove one.
    case exists
}

/// Where the 256-bit file key lives: the login keychain for release builds, a file for DEBUG and
/// separate data folders. `loadKey` returns nil only when there is no key, and `saveKey` never
/// replaces one, so a passing keychain error can never cost the owner their enrollment.
public protocol KeyStore: AnyObject, Sendable {
    func loadKey() throws -> SymmetricKey?
    func saveKey(_ key: SymmetricKey) throws
    func deleteKey() throws
}

public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    public init(key: SymmetricKey? = nil) {
        self.key = key
    }

    public func loadKey() throws -> SymmetricKey? { lock.withLock { key } }

    public func saveKey(_ key: SymmetricKey) throws {
        try lock.withLock {
            guard self.key == nil else { throw KeyStoreError.exists }
            self.key = key
        }
    }

    public func deleteKey() throws { lock.withLock { key = nil } }
}

/// Ad-hoc dev builds, whose changing signature would make every keychain read prompt.
public final class FileKeyStore: KeyStore, @unchecked Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadKey() throws -> SymmetricKey? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let d: Data
        do { d = try Data(contentsOf: url) } catch { throw KeyStoreError.unavailable(-1) }
        guard d.count == 32 else { throw KeyStoreError.corrupt }
        return SymmetricKey(data: d)
    }

    public func saveKey(_ key: SymmetricKey) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw KeyStoreError.exists }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SecureFile.write(key.withUnsafeBytes { Data($0) }, to: url)
    }

    public func deleteKey() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public enum SecureFile {
    /// Atomic write of a 0600 file.
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// enrollment.v2 = "FLK2" + AES-GCM sealed box (nonce, ciphertext, tag) of the JSON payload, with
/// the header as associated data.
public enum EnrollmentCodec {
    public static let magic = Data("FLK2".utf8)
    public typealias Migration = @Sendable (inout [String: Any]) throws -> Void

    /// Upgrades older payload schemas in place, keyed by the schema they upgrade from.
    public static let migrations: [Int: Migration] = [:]

    public static func encode(_ p: EnrollmentPayload, key: SymmetricKey) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        let sealed = try AES.GCM.seal(try e.encode(p), using: key, authenticating: magic)
        guard let combined = sealed.combined else { throw StoreError.badHeader }
        return magic + combined
    }

    public static func decode(_ data: Data, key: SymmetricKey,
                              migrations: [Int: Migration] = EnrollmentCodec.migrations) throws -> EnrollmentPayload {
        guard data.count > magic.count, data.prefix(magic.count) == magic else { throw StoreError.badHeader }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
        let plain = try AES.GCM.open(box, using: key, authenticating: magic)
        return try migrate(plain, migrations: migrations)
    }

    static func migrate(_ plain: Data, migrations: [Int: Migration]) throws -> EnrollmentPayload {
        guard var obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw StoreError.badHeader }
        var schema = obj["schema"] as? Int ?? 0
        if schema > EnrollmentPayload.currentSchema { throw StoreError.newerSchema(schema) }
        while schema < EnrollmentPayload.currentSchema {
            guard let m = migrations[schema] else { throw StoreError.noMigration(schema) }
            try m(&obj)
            schema += 1
            obj["schema"] = schema
        }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(EnrollmentPayload.self, from: JSONSerialization.data(withJSONObject: obj))
    }
}

public final class EnrollmentStore: @unchecked Sendable {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FaceLock/enrollment.v2")

    public let url: URL
    private let keys: KeyStore

    public init(url: URL = EnrollmentStore.defaultURL, keys: KeyStore) {
        self.url = url
        self.keys = keys
    }

    public func load() -> StoreLoad {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let stored: SymmetricKey?
        do {
            stored = try keys.loadKey()
        } catch KeyStoreError.corrupt {
            return .needsReenroll(.keyMissing)
        } catch {
            return .keyUnavailable
        }
        guard let key = stored else { return .needsReenroll(.keyMissing) }
        do {
            let p = try EnrollmentCodec.decode(data, key: key)
            return p.modelID == ModelCalibration.modelID ? .loaded(p) : .needsReenroll(.otherModel)
        } catch StoreError.newerSchema {
            return .needsReenroll(.newerSchema)
        } catch {
            return .needsReenroll(.unreadable)
        }
    }

    /// Encrypts under the existing key, or a new one when there is none. A key the store will not
    /// hand over right now makes this throw rather than replace it.
    public func save(_ p: EnrollmentPayload) throws {
        let key: SymmetricKey
        do {
            key = try keys.loadKey() ?? newKey()
        } catch KeyStoreError.corrupt {
            // A key that is not 256 bits decrypts nothing, so replacing it loses nothing.
            try keys.deleteKey()
            key = try newKey()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SecureFile.write(try EnrollmentCodec.encode(p, key: key), to: url)
        // Time Machine skips it: the templates stay on this Mac, not in its backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    private func newKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try keys.saveKey(key)
        return key
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try keys.deleteKey()
    }
}
