import Compression
import CryptoKit
import Foundation

/// Gets the r50 recognizer onto this Mac: InsightFace's own buffalo_l.zip from GitHub, checked
/// against the pinned SHA-256, w600k_r50.onnx inflated out of it (and checked), the rest deleted,
/// then ArcFaceR50.mlmodelc rebuilt next to it. FaceLock never hosts or ships the weights.
public final class RecognizerInstaller: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case downloading(received: Int64, total: Int64)
        case verifying
        case extracting
        case building
    }

    public let layout: RecognizerLayout
    public let skeleton: URL
    public let directory: URL
    private let onPhase: @Sendable (Phase) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()

    public init(layout: RecognizerLayout, skeleton: URL, directory: URL, onPhase: @escaping @Sendable (Phase) -> Void) {
        self.layout = layout
        self.skeleton = skeleton
        self.directory = directory
        self.onPhase = onPhase
    }

    public var onnxURL: URL { directory.appendingPathComponent(layout.source.member) }

    /// Downloads when the ONNX file is missing or wrong, then rebuilds the Core ML model.
    public func run() async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeLeftovers()
        if (try? sha256(of: onnxURL)) != layout.source.sha256 {
            let zip = try await download()
            defer { try? FileManager.default.removeItem(at: zip) }
            onPhase(.verifying)
            let got = try sha256(of: zip)
            guard got == layout.source.archiveSHA256 else { throw RecognizerInstallError.badDownload("sha256 \(got)") }
            onPhase(.extracting)
            try ZipMember.extract(layout.source.member, from: zip, to: onnxURL, sha256: layout.source.sha256)
        }
        onPhase(.building)
        return try RecognizerAssembler.install(onnx: onnxURL, skeleton: skeleton, layout: layout, into: directory)
    }

    /// A run cut short (FaceLock quit, the Mac slept for good) leaves a download, a partial ONNX file
    /// or a half-built model behind; each is hundreds of MB.
    private func removeLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where (name.hasPrefix(".buffalo_l-") && name.hasSuffix(".zip")) || name.hasSuffix(".partial")
            || (name.hasPrefix(".\(ModelName.recognizer.rawValue)-") && name.hasSuffix(".mlmodelc")) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func cancel() {
        lock.withLock { session }?.invalidateAndCancel()
    }

    private func download() async throws -> URL {
        onPhase(.downloading(received: 0, total: layout.source.archiveBytes))
        return try await withCheckedThrowingContinuation { c in
            let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            lock.withLock {
                continuation = c
                session = s
            }
            s.downloadTask(with: layout.source.url).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { continuation = nil }
            return continuation
        }
        lock.withLock { session }?.finishTasksAndInvalidate()
        c?.resume(with: result)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : layout.source.archiveBytes
        onPhase(.downloading(received: totalBytesWritten, total: total))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return finish(.failure(RecognizerInstallError.badDownload("HTTP \(http.statusCode)")))
        }
        // The system deletes `location` when this returns, so move it first.
        let kept = directory.appendingPathComponent(".buffalo_l-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

public func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    var more = true
    while more {
        try autoreleasepool {
            let chunk = try h.read(upToCount: 4 << 20) ?? Data()
            hasher.update(data: chunk)
            more = !chunk.isEmpty
        }
    }
    return hasher.finalize().hex
}

/// One deflated or stored member of a zip archive, streamed to disk and hashed as it inflates.
public enum ZipMember {
    struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    public static func extract(_ member: String, from archive: URL, to dst: URL, sha256 expected: String) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let entry = try find(member, in: input)
        try input.seek(toOffset: UInt64(entry.localHeader))
        let local = try read(input, 30)
        guard local.u32(0) == 0x0403_4B50 else { throw RecognizerInstallError.badDownload("no local header for \(member)") }
        try input.seek(toOffset: UInt64(entry.localHeader + 30 + Int(local.u16(26)) + Int(local.u16(28))))

        let partial = dst.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var written = 0
        let sink: (Data?) throws -> Void = { d in
            guard let d, !d.isEmpty else { return }
            hasher.update(data: d)
            try output.write(contentsOf: d)
            written += d.count
        }
        do {
            let filter: OutputFilter? = switch entry.method {
            case 0: nil
            case 8: try OutputFilter(.decompress, using: .zlib, writingTo: sink)
            default: throw RecognizerInstallError.badDownload("compression method \(entry.method)")
            }
            var left = entry.compressedSize
            while left > 0 {
                try autoreleasepool {
                    let chunk = try read(input, min(left, 4 << 20))
                    left -= chunk.count
                    if let filter { try filter.write(chunk) } else { try sink(chunk) }
                }
            }
            try filter?.finalize()
            try output.close()
            let digest = hasher.finalize().hex
            guard written == entry.size, digest == expected else { throw RecognizerInstallError.badDownload("\(member) sha256 \(digest)") }
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.moveItem(at: partial, to: dst)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    static func find(_ member: String, in h: FileHandle) throws -> Entry {
        let size = Int(try h.seekToEnd())
        let tail = min(size, 65_557)
        try h.seek(toOffset: UInt64(size - tail))
        let end = try read(h, tail)
        guard let eocd = stride(from: end.count - 22, through: 0, by: -1).first(where: { end.u32($0) == 0x0605_4B50 }) else {
            throw RecognizerInstallError.badDownload("not a zip archive")
        }
        let count = Int(end.u16(eocd + 10)), dirSize = Int(end.u32(eocd + 12)), dirOffset = Int(end.u32(eocd + 16))
        guard dirOffset + dirSize <= size else { throw RecognizerInstallError.badDownload("truncated archive") }
        try h.seek(toOffset: UInt64(dirOffset))
        let dir = try read(h, dirSize)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, dir.u32(p) == 0x0201_4B50 else { break }
            let n = Int(dir.u16(p + 28)), e = Int(dir.u16(p + 30)), c = Int(dir.u16(p + 32))
            let name = String(decoding: dir[(dir.startIndex + p + 46)..<(dir.startIndex + p + 46 + n)], as: UTF8.self)
            if name == member {
                return Entry(method: dir.u16(p + 10), compressedSize: Int(dir.u32(p + 20)), size: Int(dir.u32(p + 24)),
                             localHeader: Int(dir.u32(p + 42)))
            }
            p += 46 + n + e + c
        }
        throw RecognizerInstallError.badDownload("\(member) is not in the archive")
    }

    static func read(_ h: FileHandle, _ n: Int) throws -> Data {
        let d = try h.read(upToCount: n) ?? Data()
        guard d.count == n else { throw RecognizerInstallError.badDownload("truncated archive") }
        return d
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 { withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
    func u32(_ o: Int) -> UInt32 { withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
}
