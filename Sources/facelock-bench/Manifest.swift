import CryptoKit
import Foundation

struct ManifestRow {
    let role: String
    let identity: String
    /// Relative to the folder that holds lfw_funneled/.
    let path: String

    var isGenuine: Bool { role == "genuine" }
}

/// The 0.4 impostor-bank recipe, rebuilt deterministically from LFW funneled: the first image
/// (sorted) of every identity, shuffled with numpy default_rng(1), first 4,000; then every image
/// of the 5 stand-in owners. The list is verified by sha256 and never committed.
enum LFWManifest {
    static let owners = ["George_W_Bush", "Colin_Powell", "Tony_Blair", "Donald_Rumsfeld", "Gerhard_Schroeder"]
    static let strangers = 4000
    static let expectedSHA256 = "d6c2e2b8da8d5b43a1f05478563b1a5e60600b67b9c906173eaac7e3cbd29462"

    struct Built {
        let rows: [ManifestRow]
        let text: String
        let sha256: String
        var matches: Bool { sha256 == LFWManifest.expectedSHA256 }
    }

    static func build(lfwFunneled dir: URL) throws -> Built {
        let fm = FileManager.default
        let top = dir.lastPathComponent
        let ids = try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        var rel: [String] = []
        for id in ids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.appendingPathComponent(id).path, isDirectory: &isDir), isDir.boolValue else { continue }
            let files = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent(id).path)
            rel += files.filter { !$0.hasPrefix(".") && $0.hasSuffix(".jpg") }.map { "\(top)/\(id)/\($0)" }
        }
        rel.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let names = rel.map { $0.split(separator: "/")[1] }
        var first: [Substring: Int] = [:]
        for (j, n) in names.enumerated() where first[n] == nil { first[n] = j }
        var rng = PCG64(seed: 1)
        let picked = rng.shuffle(first.values.sorted()).prefix(strangers)
        let ownerSet = Set(owners)
        var rows = picked.map { ManifestRow(role: "impostor", identity: String(names[$0]), path: rel[$0]) }
        rows += rel.indices.filter { ownerSet.contains(String(names[$0])) }
            .map { ManifestRow(role: "genuine", identity: String(names[$0]), path: rel[$0]) }
        let text = "role\tidentity\tpath\n" + rows.map { "\($0.role)\t\($0.identity)\t\($0.path)\n" }.joined()
        let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return Built(rows: rows, text: text, sha256: sha)
    }
}
