import FaceLockVision
import Foundation

enum RecognizerState: Equatable {
    case needed
    case working(RecognizerInstaller.Phase)
    case failed(String)
    case installed
}

/// The r50 weights can't ship with FaceLock (non-commercial research licence), so the owner
/// downloads them from InsightFace once, after accepting that licence, and FaceLock rebuilds its
/// Core ML model from them.
extension AppModel {
    static let megabyte: Int64 = 1_000_000

    func installRecognizer() {
        guard recognizerInstaller == nil else { return }
        guard let kit = ModelLocator.recognizerKit(), let layout = try? RecognizerLayout.load(kit.layout) else {
            recognizer = .failed("This copy of FaceLock is incomplete. Download FaceLock again, then retry.")
            return
        }
        let installer = RecognizerInstaller(layout: layout, skeleton: kit.skeleton, directory: paths.models) { [weak self] phase in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recognizerPhase(phase) } }
        }
        recognizerInstaller = installer
        recognizer = .working(.downloading(received: 0, total: layout.source.archiveBytes))
        Task {
            do {
                _ = try await installer.run()
                recognizer = .installed
                recognizerInstaller = nil
                await loadEngine()
            } catch {
                recognizer = .failed(Self.describe(error))
                recognizerInstaller = nil
            }
        }
    }

    func cancelRecognizerInstall() {
        recognizerInstaller?.cancel()
    }

    /// Progress arrives for every network write; the UI needs it once per megabyte.
    private func recognizerPhase(_ phase: RecognizerInstaller.Phase) {
        guard case let .working(current) = recognizer else { return }
        if case let .downloading(old, _) = current, case let .downloading(new, _) = phase,
           old / Self.megabyte == new / Self.megabyte { return }
        recognizer = .working(phase)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return "Download cancelled."
            case .notConnectedToInternet, .networkConnectionLost:
                return "The download stopped because this Mac went offline. Connect to the internet and try again."
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "GitHub didn't answer. Check your internet connection and try again."
            default: return "The download failed (\(e.localizedDescription)). Try again."
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "This Mac is out of disk space. FaceLock needs about 550 MB free while it downloads. Free some space and try again."
        }
        if let e = error as? RecognizerInstallError { return "\(e.localizedDescription) Try again." }
        return "\(error.localizedDescription) Try again."
    }
}
