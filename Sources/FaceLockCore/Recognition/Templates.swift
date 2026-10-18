import Foundation

public let embeddingSize = 512

public enum TemplatePool: String, Codable, Sendable {
    /// Enrollment and taught looks; changed only by an explicit user action.
    case anchor
    /// Learned while watching, under the adaptation safeguards.
    case adaptive
}

public struct Template: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let vector: [Float16]
    public let pool: TemplatePool
    public let capturedAt: Date
    public let session: Int
    /// Enrollment target ("centre", "left", ...), "teach", or "adaptive".
    public let target: String
    public let sharpness: Float

    public init(id: UUID = UUID(), embedding: [Float], pool: TemplatePool, capturedAt: Date,
                session: Int, target: String, sharpness: Float) {
        precondition(embedding.count == embeddingSize, "512-float embedding")
        self.id = id
        self.vector = embedding.map { Float16($0) }
        self.pool = pool
        self.capturedAt = capturedAt
        self.session = session
        self.target = target
        self.sharpness = sharpness
    }

    public var embedding: [Float] { vector.map { Float($0) } }
}

extension Template: Codable {
    private enum Keys: String, CodingKey { case id, vector, pool, capturedAt, session, target, sharpness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let data = try c.decode(Data.self, forKey: .vector)
        guard data.count == embeddingSize * MemoryLayout<Float16>.size else {
            throw DecodingError.dataCorruptedError(forKey: .vector, in: c, debugDescription: "template is not 512 float16 values")
        }
        id = try c.decode(UUID.self, forKey: .id)
        vector = data.withUnsafeBytes { raw in (0..<embeddingSize).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Float16.self) } }
        pool = try c.decode(TemplatePool.self, forKey: .pool)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        session = try c.decode(Int.self, forKey: .session)
        target = try c.decode(String.self, forKey: .target)
        sharpness = try c.decode(Float.self, forKey: .sharpness)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vector)
        try c.encode(pool, forKey: .pool)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(session, forKey: .session)
        try c.encode(target, forKey: .target)
        try c.encode(sharpness, forKey: .sharpness)
    }
}

public struct MatchScore: Equatable, Sendable, Codable {
    /// Mean cosine of the 3 closest templates across both pools.
    public let union: Float
    /// The same over anchors only, so adaptive templates can never carry a decision alone.
    public let anchor: Float

    public init(union: Float, anchor: Float) {
        self.union = union
        self.anchor = anchor
    }
}

public enum Scorer {
    public static let k = 3

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    public static func cosine(_ e: [Float], _ t: [Float16]) -> Float {
        e.withUnsafeBufferPointer { a in
            t.withUnsafeBufferPointer { b in
                var s: Float = 0
                for i in 0..<min(a.count, b.count) { s += a[i] * Float(b[i]) }
                return s
            }
        }
    }

    /// Mean of the k highest values, or of all of them when there are fewer than k.
    public static func meanOfTop(_ values: [Float], k: Int = Scorer.k) -> Float? {
        guard !values.isEmpty else { return nil }
        let top = values.count <= k ? values : Array(values.sorted(by: >).prefix(k))
        return top.reduce(0, +) / Float(top.count)
    }
}

struct TopK {
    private(set) var values: [Float] = []
    let k: Int

    init(k: Int = Scorer.k) { self.k = k }

    mutating func insert(_ v: Float) {
        if values.count < k {
            values.append(v)
            values.sort(by: >)
        } else if let last = values.last, v > last {
            values[k - 1] = v
            values.sort(by: >)
        }
    }

    var mean: Float? { values.isEmpty ? nil : values.reduce(0, +) / Float(values.count) }
}

public struct Gallery: Equatable, Sendable {
    public let templates: [Template]

    public init(_ templates: [Template] = []) {
        self.templates = templates
    }

    public var anchors: [Template] { templates.filter { $0.pool == .anchor } }
    public var adaptive: [Template] { templates.filter { $0.pool == .adaptive } }
    public var isEmpty: Bool { templates.isEmpty }

    /// Union and anchor-only top-3 in one pass; nil without anchors.
    public func score(_ embedding: [Float]) -> MatchScore? {
        var union = TopK(), anchor = TopK()
        for t in templates {
            let c = Scorer.cosine(embedding, t.vector)
            union.insert(c)
            if t.pool == .anchor { anchor.insert(c) }
        }
        guard let a = anchor.mean, let u = union.mean else { return nil }
        return MatchScore(union: u, anchor: a)
    }

    public func maxCosine(_ embedding: [Float], pool: TemplatePool) -> Float? {
        templates.filter { $0.pool == pool }.map { Scorer.cosine(embedding, $0.vector) }.max()
    }

    public func adding(_ template: Template) -> Gallery { Gallery(templates + [template]) }
    public func adding(_ more: [Template]) -> Gallery { Gallery(templates + more) }
    public func filtered(_ keep: (Template) -> Bool) -> Gallery { Gallery(templates.filter(keep)) }

    /// 5th percentile of anchor sharpness, the base of the runtime blur gate.
    public var sharpnessP5: Double? {
        let s = anchors.map { Double($0.sharpness) }
        return s.isEmpty ? nil : Stats.quantile(s, 0.05)
    }

    public var sessionCount: Int { Set(anchors.map(\.session)).count }
}
