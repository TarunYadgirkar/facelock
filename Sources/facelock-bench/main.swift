import FaceLockCore
import FaceLockVision
import Foundation

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct Args {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ argv: [String]) {
        command = argv.dropFirst().first ?? "help"
        var v: [String: String] = [:], f: Set<String> = []
        var it = Array(argv.dropFirst(2)).makeIterator()
        var pending: String?
        while let a = it.next() {
            if a.hasPrefix("--") {
                if let p = pending { f.insert(p) }
                pending = String(a.dropFirst(2))
            } else if let p = pending {
                v[p] = a
                pending = nil
            }
        }
        if let p = pending { f.insert(p) }
        values = v
        flags = f
    }

    func string(_ k: String, _ d: String) -> String { values[k] ?? d }
    func double(_ k: String, _ d: Double) -> Double { values[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { values[k].flatMap { Int($0) } ?? d }
    func has(_ k: String) -> Bool { flags.contains(k) || values[k] != nil }
    func url(_ k: String) -> URL? { values[k].map { URL(fileURLWithPath: $0) } }
}

let usageText = """
facelock-bench: FaceLock's benchmark harness. Every subcommand runs in memory and prints JSON aggregates.

  accuracy --lfw bench/data/lfw_funneled [--anchors 54]
  latency [--image Tests/Fixtures/grace_hopper.jpg] [--lfw DIR] [--frames 200] [--manifest-images 1190] [--reps 2]
  burst [--idle 30] [--bursts 5]
  cold [--runs 4]
  idle [--seconds 600] [--state present|locked]
  owner-report [--out PATH]          (refuses any path inside the repo)
  plan                               (compute plan of both models)
  dry-run [--image PATH] [--seconds 120] [--leave-after 5]
Common: --models DIR (default: $FACELOCK_MODELS, then <repo>/models)
"""

let args = Args(CommandLine.arguments)
let models = ModelLocator(directory: args.url("models"))
let fixture = ModelLocator.repoModels.deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/grace_hopper.jpg")

func run() async throws {
    switch args.command {
    case "accuracy":
        guard let lfw = args.url("lfw") else { throw BenchError("accuracy needs --lfw <lfw_funneled dir> (bench/lfw.sh fetches it)") }
        printJSON(try Accuracy.run(lfw: lfw, models: models, anchorsPerOwner: args.int("anchors", 54)))
    case "latency":
        printJSON(try Latency.run(image: args.url("image") ?? fixture, lfw: args.url("lfw"), models: models,
                                  frames: args.int("frames", 200), manifestImages: args.int("manifest-images", 1190),
                                  reps: args.int("reps", 2)))
    case "burst":
        printJSON(try Burst.run(image: args.url("image") ?? fixture, models: models, idle: args.double("idle", 30),
                                bursts: args.int("bursts", 5)))
    case "cold":
        printJSON(try Cold.run(image: args.url("image") ?? fixture, models: models, runs: args.int("runs", 4)))
    case "cold-child":
        try Cold.child(image: args.url("image") ?? fixture, models: models)
    case "idle":
        printJSON(try await Idle.run(image: args.url("image") ?? fixture, models: models, seconds: args.double("seconds", 600),
                                     state: args.string("state", "present")))
    case "owner-report":
        try OwnerReport.run(out: args.url("out"))
    case "fixture-inputs":
        guard let out = args.url("out") else { throw BenchError("fixture-inputs needs --out DIR (outside the repo)") }
        try FixtureInputs.run(image: args.url("image") ?? fixture, models: models, out: out)
    case "plan":
        var out: [String: Any] = [:]
        for m in ModelName.allCases {
            let p = try await computePlan(try models.url(m))
            out[m.rawValue] = ["ops_by_device": p.opsByDevice, "neural_engine_op_share": rounded(p.neuralEngineOpShare),
                               "neural_engine_cost_share": rounded(p.neuralEngineCostShare), "label": p.label]
        }
        printJSON(out)
    case "dry-run":
        try await DryRun.run(image: args.url("image") ?? fixture, models: models, seconds: args.double("seconds", 120),
                            leaveAfter: args.has("leave-after") ? args.double("leave-after", 5) : nil)
    default:
        print(usageText)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("facelock-bench: \(error)\n".utf8))
    exit(1)
}
