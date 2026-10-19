import Foundation

/// ~/Library/Logs/FaceLock/checks.jsonl: one JSON object per line, rotated at 5 MB. No record is
/// kept longer than 30 days: the log is pruned at launch and on the first write of each day.
public final class TelemetryLog: TelemetrySink, @unchecked Sendable {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FaceLock/checks.jsonl")
    public static let maxBytes = 5 * 1024 * 1024
    public static let keepDays = 30.0

    public let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.tarunyadgirkar.facelock.telemetry", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var prunedDay: Int?

    public init(url: URL = TelemetryLog.defaultURL, maxBytes: Int = TelemetryLog.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        decoder = d
    }

    public func record(_ r: CheckRecord) {
        queue.async { self.write(r) }
    }

    /// Blocks until queued records are on disk.
    public func flush() { queue.sync {} }

    private func write(_ r: CheckRecord) {
        guard var line = try? encoder.encode(r) else { return }
        line.append(0x0A)
        let day = Int(r.at.timeIntervalSince1970 / 86_400)
        if day != prunedDay { pruneOnQueue(now: r.at) }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size + line.count > maxBytes { rotate(now: r.at) }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    private func rotate(now: Date) {
        let fm = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        let rotated = url.deletingPathExtension().appendingPathExtension("\(stamp).jsonl")
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Drops every record older than 30 days, in rotated files and the active one.
    public func prune(now: Date) {
        queue.sync { pruneOnQueue(now: now) }
    }

    public func pruneInBackground(now: Date) {
        queue.async { self.pruneOnQueue(now: now) }
    }

    private func pruneOnQueue(now: Date) {
        prunedDay = Int(now.timeIntervalSince1970 / 86_400)
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86_400)
        for f in rotatedFiles() + [url] { prune(f, before: cutoff) }
    }

    /// A file last written before the cutoff goes; one whose first record is older is rewritten
    /// without the old lines. Files that are entirely recent are not touched.
    private func prune(_ f: URL, before cutoff: Date) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: f.path) else { return }
        let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        if modified < cutoff {
            try? fm.removeItem(at: f)
            return
        }
        guard let first = firstRecordDate(f), first < cutoff, let text = try? String(contentsOf: f, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").filter { line in
            (try? decoder.decode(CheckRecord.self, from: Data(line.utf8))).map { $0.at >= cutoff } ?? false
        }
        if kept.isEmpty {
            try? fm.removeItem(at: f)
        } else {
            try? SecureFile.write(Data((kept.joined(separator: "\n") + "\n").utf8), to: f)
        }
    }

    private func firstRecordDate(_ f: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), let end = head.firstIndex(of: 0x0A) else { return nil }
        return (try? decoder.decode(CheckRecord.self, from: head[head.startIndex..<end]))?.at
    }

    public func rotatedFiles() -> [URL] {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(stem + ".") && $0.lastPathComponent != url.lastPathComponent }
    }

    public func records(since: Date) -> [CheckRecord] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (rotatedFiles() + [url]).flatMap { f -> [CheckRecord] in
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? d.decode(CheckRecord.self, from: Data($0.utf8)) }
        }.filter { $0.at >= since }
    }

    public func weeklySummary(now: Date = Date()) -> TelemetrySummary {
        TelemetrySummary(records(since: now.addingTimeInterval(-7 * 86_400)))
    }
}

public struct TelemetrySummary: Equatable, Sendable {
    public let checks: Int
    public let locks: Int
    public let cancelledByOwner: Int
    public let cancelledByInput: Int
    public let cancelledByFace: Int
    public let failedLocks: Int
    /// Median camera on-time of checks that found the owner.
    public let medianPresentOnTime: Double?

    public init(_ records: [CheckRecord]) {
        checks = records.filter { $0.event == .check }.count
        locks = records.filter { $0.event == .lock && $0.outcome == .locked }.count
        failedLocks = records.filter { $0.event == .lock && $0.outcome?.isFailure == true }.count
        cancelledByOwner = records.filter { $0.event == .cancel && $0.cancel == .owner }.count
        cancelledByInput = records.filter { $0.event == .cancel && $0.cancel == .input }.count
        cancelledByFace = records.filter { $0.event == .cancel && $0.cancel == .face }.count
        let on = records.filter { $0.event == .check && $0.verdict == .owner && ($0.kind == .regular || $0.kind == .manual) }
            .compactMap(\.onTime)
        medianPresentOnTime = on.isEmpty ? nil : Stats.median(on)
    }

    /// Countdowns you stopped by coming back or by moving the mouse or pressing a key.
    public var countdownsStopped: Int { cancelledByOwner + cancelledByInput }
}
