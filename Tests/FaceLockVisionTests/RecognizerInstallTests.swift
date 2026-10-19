import CryptoKit
@testable import FaceLockVision
import Foundation
import Testing

@Suite("Recognizer download and rebuild")
struct RecognizerInstallTests {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("facelock-recognizer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// A deflated member next to a stored one, made by /usr/bin/zip.
    static func archive(_ dir: URL, payload: Data) throws -> URL {
        try payload.write(to: dir.appendingPathComponent("w600k_r50.onnx"))
        try Data("other".utf8).write(to: dir.appendingPathComponent("det_10g.onnx"))
        let zip = dir.appendingPathComponent("buffalo_l.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-9", zip.path, "det_10g.onnx", "w600k_r50.onnx"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("w600k_r50.onnx"))
        return zip
    }

    @Test("one member inflates out of the archive and must match its SHA-256")
    func extract() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        let zip = try Self.archive(dir, payload: payload)
        let out = dir.appendingPathComponent("out.onnx")
        try ZipMember.extract("w600k_r50.onnx", from: zip, to: out, sha256: Self.hex(payload))
        #expect(try Data(contentsOf: out) == payload)
        #expect(throws: RecognizerInstallError.self) {
            try ZipMember.extract("w600k_r50.onnx", from: zip, to: out, sha256: String(repeating: "0", count: 64))
        }
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathExtension("partial").path))
        #expect(throws: RecognizerInstallError.self) {
            try ZipMember.extract("missing.onnx", from: zip, to: out, sha256: Self.hex(payload))
        }
    }

    @Test("fp16 casts match coremltools: round to nearest even, f16nz keeps tiny values' sign")
    func casts() throws {
        let values: [Float] = [1e-30, -1e-30, 0, 1, 65504, 1.0009765625]
        func bits(_ cast: RecognizerLayout.Cast) throws -> [UInt16] {
            let blob = try JSONDecoder().decode(RecognizerLayout.Blob.self, from: Data(
                #"{"offset":64,"dtype":1,"initializer":"x","cast":"\#(cast.rawValue)","count":6}"#.utf8))
            let d = try RecognizerAssembler.encode(values, blob)
            return d.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        }
        #expect(try bits(.f16) == [0, 0x8000, 0, 0x3C00, 0x7BFF, 0x3C01])
        #expect(try bits(.f16nz) == [0x0001, 0x8001, 0, 0x3C00, 0x7BFF, 0x3C01])
    }

    static var onnx: URL? {
        [ModelLocator.installDirectory, ModelLocator.repoModels.appendingPathComponent("upstream")]
            .map { $0.appendingPathComponent("w600k_r50.onnx") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test("the rebuilt model is byte for byte the tested one", .enabled(if: onnx != nil && ModelLocator.recognizerKit() != nil,
                                                                     "no w600k_r50.onnx on this Mac"))
    func rebuild() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kit = try #require(ModelLocator.recognizerKit())
        let layout = try RecognizerLayout.load(kit.layout)
        let model = try RecognizerAssembler.install(onnx: try #require(Self.onnx), skeleton: kit.skeleton, layout: layout, into: dir)
        let weights = try Data(contentsOf: model.appendingPathComponent("weights/weight.bin"))
        #expect(Self.hex(weights) == layout.weights.sha256)
        #expect(FileManager.default.fileExists(atPath: model.appendingPathComponent("model.mil").path))
    }
}
