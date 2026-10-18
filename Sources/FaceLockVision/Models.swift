import CoreML
import Foundation

public enum ModelName: String, CaseIterable, Sendable {
    case detector = "YuNet320x240"
    case recognizer = "ArcFaceR50"
}

public enum ModelError: Error, CustomStringConvertible {
    case missing(String)

    public var description: String {
        switch self {
        case let .missing(name): return "\(name).mlmodelc not found; run tools/convert_models.py"
        }
    }
}

/// Finds the compiled models: an explicit directory, $FACELOCK_MODELS, the app bundle, then
/// the repo's models/ folder next to the package.
public struct ModelLocator: Sendable {
    public let directories: [URL]

    public init(directory: URL? = nil) {
        var dirs: [URL] = []
        if let directory { dirs.append(directory) }
        if let env = ProcessInfo.processInfo.environment["FACELOCK_MODELS"] { dirs.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        dirs.append(Self.repoModels)
        directories = dirs
    }

    /// <repo>/models, found from this source file's location at build time.
    public static let repoModels = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("models")

    public func url(_ name: ModelName) throws -> URL {
        for d in directories {
            let u = d.appendingPathComponent("\(name.rawValue).mlmodelc")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        throw ModelError.missing(name.rawValue)
    }

    public var isAvailable: Bool { ModelName.allCases.allSatisfy { (try? url($0)) != nil } }
}

public enum ComputeChoice: String, Sendable, CaseIterable {
    /// The production choice for both models. Never `.all`: it put r50 on the GPU.
    case neuralEngine = "ane"
    case cpu

    public var units: MLComputeUnits { self == .cpu ? .cpuOnly : .cpuAndNeuralEngine }
}

public func loadModel(_ url: URL, compute: ComputeChoice) throws -> MLModel {
    let c = MLModelConfiguration()
    c.computeUnits = compute.units
    return try MLModel(contentsOf: url, configuration: c)
}

public struct ComputePlanSummary: Sendable, Codable, Equatable {
    public let opsByDevice: [String: Int]
    public let costByDevice: [String: Double]

    public var neuralEngineOpShare: Double {
        let total = opsByDevice.values.reduce(0, +)
        return total > 0 ? Double(opsByDevice["neural_engine"] ?? 0) / Double(total) : 0
    }

    public var neuralEngineCostShare: Double {
        let total = costByDevice.values.reduce(0, +)
        return total > 0 ? (costByDevice["neural_engine"] ?? 0) / total : 0
    }

    /// For Diagnostics: "Neural Engine" or "Running on CPU".
    public var label: String {
        neuralEngineCostShare >= 0.5 ? "Neural Engine (\(Int((neuralEngineCostShare * 100).rounded()))%)" : "Running on CPU"
    }
}

/// Which device Core ML plans for each op (MLComputePlan).
public func computePlan(_ url: URL, compute: ComputeChoice = .neuralEngine) async throws -> ComputePlanSummary {
    let c = MLModelConfiguration()
    c.computeUnits = compute.units
    let plan = try await MLComputePlan.load(contentsOf: url, configuration: c)
    guard case let .program(program) = plan.modelStructure, let main = program.functions["main"] else {
        return ComputePlanSummary(opsByDevice: [:], costByDevice: [:])
    }
    var ops: [String: Int] = [:], cost: [String: Double] = [:]
    for op in main.block.operations {
        guard let usage = plan.deviceUsage(for: op) else { continue }
        let name: String
        switch usage.preferred {
        case .cpu: name = "cpu"
        case .gpu: name = "gpu"
        case .neuralEngine: name = "neural_engine"
        @unknown default: name = "other"
        }
        ops[name, default: 0] += 1
        cost[name, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
    }
    return ComputePlanSummary(opsByDevice: ops, costByDevice: cost)
}
