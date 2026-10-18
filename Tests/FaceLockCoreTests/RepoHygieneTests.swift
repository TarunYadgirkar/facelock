import Foundation
import Testing

@Suite("Repo hygiene")
struct RepoHygieneTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var isGitCheckout: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) }

    @Test("no tracked embeddings, models, or images outside the allowlist",
          .enabled(if: isGitCheckout, "not a git checkout"))
    func noBiometrics() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.root.appendingPathComponent("scripts/check-no-biometrics.sh").path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(message)")
    }
}
