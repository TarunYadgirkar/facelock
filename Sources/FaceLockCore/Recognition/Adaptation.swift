import Foundation

public struct AdaptationPolicy: Equatable, Sendable, Codable {
    public var maxTemplates = 120
    public var maxAge: TimeInterval = 60 * 24 * 3600
    public var noveltyCeiling: Float = 0.92
    public var minInterval: TimeInterval = 600
    public var maxPerDay = 12
    public var inputWithin: TimeInterval = 60

    public init() {}

    public static let standard = AdaptationPolicy()
}

public enum AdaptationRejection: String, Equatable, Sendable, Codable {
    case quality
    case notOneFace
    case anchorBelowThreshold
    case notNovel
    case strangerSinceUnlock
    case noRecentInput
    case tooSoon
    case dailyLimit
}

public struct AdaptationCandidate: Equatable, Sendable {
    public let embedding: [Float]
    public let qualityPassed: Bool
    public let faceCount: Int
    public let anchorScore: Float
    public let sharpness: Float

    public init(embedding: [Float], qualityPassed: Bool, faceCount: Int, anchorScore: Float, sharpness: Float) {
        self.embedding = embedding
        self.qualityPassed = qualityPassed
        self.faceCount = faceCount
        self.anchorScore = anchorScore
        self.sharpness = sharpness
    }
}

public struct AdaptationContext: Equatable, Sendable {
    public let threshold: Float
    public let strangerOrUnclearSinceUnlock: Bool
    public let secondsSinceInput: TimeInterval?
    public let now: Date

    public init(threshold: Float, strangerOrUnclearSinceUnlock: Bool, secondsSinceInput: TimeInterval?, now: Date) {
        self.threshold = threshold
        self.strangerOrUnclearSinceUnlock = strangerOrUnclearSinceUnlock
        self.secondsSinceInput = secondsSinceInput
        self.now = now
    }
}

public enum Adaptation {
    /// nil means the frame may join the adaptive pool.
    public static func evaluate(_ c: AdaptationCandidate, in gallery: Gallery, context x: AdaptationContext,
                                policy p: AdaptationPolicy = .standard) -> AdaptationRejection? {
        if !c.qualityPassed { return .quality }
        if c.faceCount != 1 { return .notOneFace }
        if c.anchorScore < x.threshold { return .anchorBelowThreshold }
        if let m = gallery.maxCosine(c.embedding, pool: .adaptive), m >= p.noveltyCeiling { return .notNovel }
        if x.strangerOrUnclearSinceUnlock { return .strangerSinceUnlock }
        guard let idle = x.secondsSinceInput, idle <= p.inputWithin else { return .noRecentInput }
        let added = gallery.adaptive.map(\.capturedAt)
        if let last = added.max(), x.now.timeIntervalSince(last) < p.minInterval { return .tooSoon }
        if added.filter({ x.now.timeIntervalSince($0) < 24 * 3600 }).count >= p.maxPerDay { return .dailyLimit }
        return nil
    }

    public static func template(for c: AdaptationCandidate, at now: Date, session: Int) -> Template {
        Template(embedding: c.embedding, pool: .adaptive, capturedAt: now, session: session, target: "adaptive",
                 sharpness: c.sharpness)
    }

    /// Adds an adaptive template, dropping the oldest ones past the pool cap.
    public static func adding(_ t: Template, to gallery: Gallery, policy p: AdaptationPolicy = .standard) -> Gallery {
        let adaptive = (gallery.adaptive + [t]).sorted { $0.capturedAt < $1.capturedAt }.suffix(p.maxTemplates)
        return Gallery(gallery.anchors + adaptive)
    }

    public static func expiring(_ gallery: Gallery, now: Date, policy p: AdaptationPolicy = .standard) -> Gallery {
        gallery.filtered { $0.pool == .anchor || now.timeIntervalSince($0.capturedAt) <= p.maxAge }
    }

    /// "Reset learned looks".
    public static func resetting(_ gallery: Gallery) -> Gallery {
        gallery.filtered { $0.pool == .anchor }
    }
}
