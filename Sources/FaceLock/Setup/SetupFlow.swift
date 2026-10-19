import FaceLockCore
import Foundation

enum SetupStep: String, CaseIterable, Identifiable, Sendable {
    case welcome, before, camera, face, result, someoneElse, finish

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .before: return "Old version"
        case .camera: return "Camera"
        case .face: return "Your face"
        case .result: return "Result"
        case .someoneElse: return "Someone else"
        case .finish: return "Finish"
        }
    }
}

/// First run without a terminal: what FaceLock is, the old version, camera access, enrollment,
/// the calibration result, an optional second person, and starting at login.
@MainActor @Observable
final class SetupFlow {
    let model: AppModel
    var step: SetupStep
    let enrollment = EnrollmentModel()
    let someoneElse: SomeoneElseModel
    var report: CalibrationReport?
    var saveError: String?
    /// The old-version step stays in the rail once shown, even after its items are handled.
    private let showsBefore: Bool

    init(model: AppModel, start: SetupStep?) {
        self.model = model
        showsBefore = !model.setupLegacyItems.isEmpty
        someoneElse = SomeoneElseModel(app: model)
        step = start ?? .welcome
        report = model.payload?.calibration
    }

    var steps: [SetupStep] { SetupStep.allCases.filter { $0 != .before || showsBefore } }

    func isDone(_ s: SetupStep) -> Bool {
        guard let i = steps.firstIndex(of: s), let current = steps.firstIndex(of: step) else { return false }
        return i < current
    }

    func next() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        leave(step)
        step = steps[i + 1]
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0, step != .result else { return }
        leave(step)
        step = steps[i - 1]
    }

    private func leave(_ s: SetupStep) {
        if s == .face { enrollment.stop() }
    }

    /// Saves the new enrollment and moves on to the result.
    func saveEnrollment() {
        do {
            report = try model.completeEnrollment(enrollment.session.templates)
            enrollment.stop()
            step = .result
        } catch {
            saveError = "FaceLock couldn't save your face. \(error.localizedDescription)"
        }
    }

    func close() {
        enrollment.stop()
    }
}
