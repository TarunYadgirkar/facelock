import CryptoKit
import Foundation

/// Where each w600k_r50.onnx initializer goes in ArcFaceR50.mlmodelc/weights/weight.bin and how it
/// was cast. tools/convert_models.py writes it from the converted model; it holds names, offsets and
/// hashes, never weights, so the app can ship it while the weights stay with InsightFace.
public struct RecognizerLayout: Decodable, Sendable {
    public struct Source: Decodable, Sendable {
        public let url: URL
        public let archiveSHA256: String
        public let archiveBytes: Int64
        public let member: String
        public let sha256: String
        public let bytes: Int64
        public let license: String

        enum CodingKeys: String, CodingKey {
            case url, member, sha256, bytes, license
            case archiveSHA256 = "archive_sha256"
            case archiveBytes = "archive_bytes"
        }
    }

    public struct Weights: Decodable, Sendable {
        public let bytes: Int
        public let sha256: String
        public let version: UInt32
    }

    public struct Blob: Decodable, Sendable {
        public let offset: Int
        public let dtype: UInt32
        public let initializer: String
        public let cast: Cast
        public let count: Int
    }

    public enum Cast: String, Decodable, Sendable {
        /// fp32 to fp16, rounding to nearest even.
        case f16
        /// As f16, but a nonzero value that rounds to zero keeps its sign as the smallest subnormal.
        case f16nz
        case f32
    }

    public let source: Source
    public let weights: Weights
    public let blobs: [Blob]

    public static let fileName = "ArcFaceR50.layout.json"

    public static func load(_ url: URL) throws -> RecognizerLayout {
        try JSONDecoder().decode(RecognizerLayout.self, from: Data(contentsOf: url))
    }
}

public enum RecognizerInstallError: Error, LocalizedError, Equatable {
    case badDownload(String)
    case badModelFile(String)
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case let .badDownload(d): return "The download isn't the expected file (\(d))."
        case let .badModelFile(d): return "The face model file couldn't be read (\(d))."
        case let .mismatch(d): return "The rebuilt face model doesn't match the one FaceLock was tested with (\(d))."
        }
    }
}

/// The float initializers of an ONNX model, read straight from the protobuf without a copy.
public struct ONNXInitializers {
    public let data: Data
    /// Name to the byte range of the tensor's raw_data in `data`.
    public let raw: [String: Range<Int>]

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        raw = try data.withUnsafeBytes { try Self.parse(UnsafeRawBufferPointer($0)) }
    }

    /// The float32 values of an initializer.
    public func floats(_ name: String) throws -> [Float] {
        guard let r = raw[name] else { throw RecognizerInstallError.badModelFile("no initializer \(name)") }
        return data.withUnsafeBytes { buf in
            (0..<(r.count / 4)).map { Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: r.lowerBound + $0 * 4, as: UInt32.self))) }
        }
    }

    private static let floatType: UInt64 = 1

    private static func parse(_ b: UnsafeRawBufferPointer) throws -> [String: Range<Int>] {
        var model = ProtoReader(b, 0..<b.count)
        var out: [String: Range<Int>] = [:]
        while let f = try model.next() {
            guard f.number == 7, case let .bytes(graph) = f.value else { continue }
            var g = ProtoReader(b, graph)
            while let gf = try g.next() {
                guard gf.number == 5, case let .bytes(tensor) = gf.value else { continue }
                let (name, range) = try initializer(b, tensor)
                out[name] = range
            }
        }
        return out
    }

    private static func initializer(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) throws -> (String, Range<Int>) {
        var t = ProtoReader(b, r)
        var name: String?, raw: Range<Int>?, type: UInt64?
        while let f = try t.next() {
            switch (f.number, f.value) {
            case let (2, .varint(v)): type = v
            case let (8, .bytes(s)): name = String(decoding: UnsafeRawBufferPointer(rebasing: b[s]), as: UTF8.self)
            case let (9, .bytes(s)): raw = s
            default: continue
            }
        }
        guard let name, let raw, type == floatType else {
            throw RecognizerInstallError.badModelFile("an initializer isn't raw float32")
        }
        return (name, raw)
    }
}

/// Protobuf wire format, just enough for ONNX: varints, fixed widths and length-delimited fields.
struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes(Range<Int>)
        case fixed
    }

    private let b: UnsafeRawBufferPointer
    private var pos: Int
    private let end: Int

    init(_ b: UnsafeRawBufferPointer, _ range: Range<Int>) {
        self.b = b
        pos = range.lowerBound
        end = range.upperBound
    }

    mutating func next() throws -> (number: UInt64, value: Value)? {
        guard pos < end else { return nil }
        let key = try varint()
        switch key & 7 {
        case 0: return (key >> 3, .varint(try varint()))
        case 1: try skip(8)
        case 2:
            let n = Int(try varint())
            guard n >= 0, pos + n <= end else { throw RecognizerInstallError.badModelFile("truncated field") }
            defer { pos += n }
            return (key >> 3, .bytes(pos..<(pos + n)))
        case 5: try skip(4)
        default: throw RecognizerInstallError.badModelFile("wire type \(key & 7)")
        }
        return (key >> 3, .fixed)
    }

    private mutating func skip(_ n: Int) throws {
        guard pos + n <= end else { throw RecognizerInstallError.badModelFile("truncated field") }
        pos += n
    }

    private mutating func varint() throws -> UInt64 {
        var v: UInt64 = 0, shift: UInt64 = 0
        while pos < end, shift < 64 {
            let byte = b[pos]
            pos += 1
            v |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return v }
            shift += 7
        }
        throw RecognizerInstallError.badModelFile("bad varint")
    }
}

/// Rebuilds ArcFaceR50.mlmodelc from the shipped skeleton (the compiled model without
/// weights/weight.bin) and the downloaded ONNX file, and accepts it only when weight.bin hashes to
/// the value pinned in the layout: the model then matches the tested one byte for byte.
public enum RecognizerAssembler {
    static let blobHeader = 64
    static let sentinel: UInt32 = 0xDEAD_BEEF

    public static func install(onnx: URL, skeleton: URL, layout: RecognizerLayout, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let final = directory.appendingPathComponent("\(ModelName.recognizer.rawValue).mlmodelc")
        let staging = directory.appendingPathComponent(".\(ModelName.recognizer.rawValue)-\(UUID().uuidString).mlmodelc")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: skeleton, to: staging)
        do {
            let weights = staging.appendingPathComponent("weights")
            try? fm.removeItem(at: weights)
            try fm.createDirectory(at: weights, withIntermediateDirectories: true)
            try writeWeights(ONNXInitializers(url: onnx), layout: layout, to: weights.appendingPathComponent("weight.bin"))
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return final
    }

    public static func writeWeights(_ inits: ONNXInitializers, layout: RecognizerLayout, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        var hasher = SHA256()
        var written = 0
        func write(_ d: Data) throws {
            hasher.update(data: d)
            try h.write(contentsOf: d)
            written += d.count
        }
        func pad(to offset: Int) throws {
            guard offset >= written else { throw RecognizerInstallError.mismatch("blob order") }
            if offset > written { try write(Data(count: offset - written)) }
        }
        var header = Data(count: blobHeader)
        header.store(UInt32(layout.blobs.count), at: 0)
        header.store(layout.weights.version, at: 4)
        try write(header)
        for blob in layout.blobs {
            try pad(to: blob.offset)
            let payload = try encode(try inits.floats(blob.initializer), blob)
            var meta = Data(count: blobHeader)
            meta.store(sentinel, at: 0)
            meta.store(blob.dtype, at: 4)
            meta.store(UInt64(payload.count), at: 8)
            meta.store(UInt64(blob.offset + blobHeader), at: 16)
            try write(meta)
            try write(payload)
        }
        try pad(to: layout.weights.bytes)
        let digest = hasher.finalize().hex
        guard written == layout.weights.bytes, digest == layout.weights.sha256 else {
            throw RecognizerInstallError.mismatch("weight.bin sha256 \(digest)")
        }
    }

    static func encode(_ values: [Float], _ blob: RecognizerLayout.Blob) throws -> Data {
        guard values.count == blob.count else { throw RecognizerInstallError.mismatch("\(blob.initializer) has \(values.count) values") }
        switch blob.cast {
        case .f32:
            return values.withUnsafeBufferPointer { Data(buffer: $0) }
        case .f16, .f16nz:
            let keep = blob.cast == .f16nz
            let halves = values.map { v -> Float16 in
                let h = Float16(v)
                guard keep, h == 0, v != 0 else { return h }
                return Float16(bitPattern: v.sign == .minus ? 0x8001 : 0x0001)
            }
            return halves.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}

extension Data {
    mutating func store<T: FixedWidthInteger>(_ v: T, at offset: Int) {
        Swift.withUnsafeBytes(of: v.littleEndian) { replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0) }
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
