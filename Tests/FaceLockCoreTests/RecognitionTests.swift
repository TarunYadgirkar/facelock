import FaceLockCore
import Foundation
import Testing

@Suite("Scorer")
struct ScorerTests {
    @Test("top-3 is the mean of all templates when there are fewer than 3")
    func fewerThanThree() {
        let probe = unit(1)
        let a = vector(near: probe, cosine: 0.8, seed: 2), b = vector(near: probe, cosine: 0.6, seed: 3)
        let one = Gallery([template(a)]).score(probe)!
        #expect(abs(one.union - 0.8) < 2e-3)
        let two = Gallery([template(a), template(b)]).score(probe)!
        #expect(abs(two.union - 0.7) < 2e-3)
        let c = vector(near: probe, cosine: 0.9, seed: 4), d = vector(near: probe, cosine: 0.1, seed: 5)
        let four = Gallery([template(a), template(b), template(c), template(d)]).score(probe)!
        #expect(abs(four.union - (0.8 + 0.6 + 0.9) / 3) < 2e-3)
        #expect(Gallery().score(probe) == nil)
        #expect(Gallery([template(a, pool: .adaptive)]).score(probe) == nil)
    }

    @Test("float16 templates round-trip through Codable and keep cosine within 1e-3")
    func float16RoundTrip() throws {
        let e = unit(7)
        let t = template(e, session: 2, target: "left", sharpness: 42)
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Template.self, from: data)
        #expect(back == t)
        #expect(abs(Scorer.cosine(e, back.vector) - 1) < 1e-3)
        #expect(back.embedding.count == embeddingSize)
    }

    @Test("adaptive templates alone cannot make an owner: the anchor-only gate needs F")
    func anchorGate() {
        let probe = unit(10)
        let anchors = (0..<3).map { template(vector(near: probe, cosine: 0.40, seed: 20 + $0)) }
        let adaptive = (0..<3).map { template(vector(near: probe, cosine: 0.95, seed: 30 + $0), pool: .adaptive) }
        let s = Gallery(anchors + adaptive).score(probe)!
        #expect(s.union > 0.9)
        #expect(abs(s.anchor - 0.40) < 2e-3)
        #expect(!VerdictRules.isOwner(s, Thresholds(accept: 0.6, floor: 0.44)))
        #expect(VerdictRules.isOwner(MatchScore(union: 0.61, anchor: 0.45), Thresholds(accept: 0.6, floor: 0.44)))
    }

    @Test("frame verdicts: owner, stranger, unclear on quality, unclear with two faces")
    func verdicts() {
        let t = Thresholds(accept: 0.55, floor: 0.44, stranger: 0.25)
        let owner = observation(score: MatchScore(union: 0.7, anchor: 0.7))
        let stranger = observation(score: MatchScore(union: 0.2, anchor: 0.2))
        let middle = observation(score: MatchScore(union: 0.4, anchor: 0.4))
        let turned = observation(score: MatchScore(union: 0.9, anchor: 0.9), quality: .turned)
        #expect(VerdictRules.classify(FrameObservation(faces: []), t).verdict == .noFace)
        #expect(VerdictRules.classify(FrameObservation(faces: [owner]), t).verdict == .owner)
        #expect(VerdictRules.classify(FrameObservation(faces: [stranger]), t).verdict == .stranger)
        #expect(VerdictRules.classify(FrameObservation(faces: [middle]), t).verdict == .unclear)
        #expect(VerdictRules.classify(FrameObservation(faces: [turned]), t).verdict == .unclear)
        #expect(VerdictRules.classify(FrameObservation(faces: [stranger, stranger]), t).verdict == .unclear)
        let both = VerdictRules.classify(FrameObservation(faces: [stranger, owner]), t)
        #expect(both.verdict == .owner)
        #expect(both.ownerIndex == 1)
        #expect(both.secondFace)
        let small = observation(score: nil, face: frontalFace(x: 20, iod: 20))
        #expect(!VerdictRules.classify(FrameObservation(faces: [owner, small]), t).secondFace)
    }

    @Test("the floor is ceil to 0.01 of the stranger max + 0.10")
    func floor() {
        #expect(ModelCalibration.floor(fromStrangerMax: 0.3330) == 0.44)
        #expect(ModelCalibration.floor(fromStrangerMax: 0.33) == 0.43)
        #expect(ModelCalibration.floor(fromStrangerMax: 0.3401) == 0.45)
    }
}

@Suite("Calibration")
struct CalibrationTests {
    @Test("block-out excludes templates within 2 s and from the same target segment")
    func blockOut() {
        let base = unit(100)
        let a = template(base, at: 0, session: 0, target: "centre")
        let twin = template(vector(near: base, cosine: 0.99, seed: 1), at: 1, session: 0, target: "left")
        let sameSegment = template(vector(near: base, cosine: 0.98, seed: 2), at: 10, session: 0, target: "centre")
        let far = template(vector(near: base, cosine: 0.70, seed: 3), at: 30, session: 0, target: "left")
        let scores = Calibrator.blockOutScores([a, twin, sameSegment, far])
        let forA = scores.first { $0.0.id == a.id }!.1
        #expect(abs(forA - 0.70) < 2e-3)
    }

    @Test("T clamps to F with a close-looks warning, and to C at the top")
    func clamps() {
        let base = unit(200)
        let tight = (0..<12).map { template(vector(near: base, cosine: 0.97, seed: $0), at: Double($0) * 10, session: $0 % 3,
                                            target: "t\($0 % 4)") }
        let high = Calibrator.calibrate(Gallery(tight))
        #expect(high.thresholds.accept == 0.60)
        #expect(high.clampedToCeiling)
        #expect(!high.clampedToFloor)
        #expect(Calibrator.headline(high) == "Your looks pass with room to spare.")

        let loose = (0..<12).map { i in
            template(vector(near: base, cosine: i < 2 ? 0.2 : 0.5, seed: 50 + i), at: Double(i) * 10, session: 0, target: "t\(i)")
        }
        let low = Calibrator.calibrate(Gallery(loose))
        #expect(low.thresholds.accept == ModelCalibration.floor)
        #expect(low.clampedToFloor)
        #expect(!low.closeLooks.isEmpty)
        #expect(Calibrator.headline(low).contains("score close to strangers"))
        #expect(low.singleSession)
    }

    @Test("T = owner p2 - 0.05 between the clamps")
    func middle() {
        let base = unit(300)
        let ts = (0..<20).map { template(vector(near: base, cosine: 0.75, seed: 70 + $0), at: Double($0) * 10, session: $0 % 2,
                                         target: "t\($0)") }
        let r = Calibrator.calibrate(Gallery(ts))
        let expected = r.ownerLow! - 0.05
        #expect(r.thresholds.accept == expected)
        #expect(expected > 0.44 && expected < 0.60)
        #expect(!r.singleSession)
    }

    @Test("check with someone else raises T to their max + 0.05, capped at C, only when they come close")
    func someoneElse() {
        let base = unit(400)
        let ts = (0..<20).map { template(vector(near: base, cosine: 0.75, seed: 90 + $0), at: Double($0) * 10, target: "t\($0)") }
        let r = Calibrator.calibrate(Gallery(ts))
        let t = r.thresholds.accept
        let far = Calibrator.adjusting(r, someoneElseMax: t - 0.2)
        #expect(far.thresholds.accept == t)
        #expect(!far.raisedForSomeoneElse)
        let close = Calibrator.adjusting(r, someoneElseMax: t - 0.02)
        #expect(abs(close.thresholds.accept - (t + 0.03)) < 1e-6)
        #expect(close.raisedForSomeoneElse)
        let over = Calibrator.adjusting(r, someoneElseMax: 0.7)
        #expect(over.thresholds.accept == 0.60)
    }
}

@Suite("Adaptation safeguards")
struct AdaptationTests {
    let base = unit(500)
    var gallery: Gallery { Gallery((0..<10).map { template(vector(near: base, cosine: 0.8, seed: $0), at: Double($0)) }) }

    func candidate(cos: Float = 0.8, quality: Bool = true, faces: Int = 1, anchor: Float = 0.7, seed: Int = 99) -> AdaptationCandidate {
        AdaptationCandidate(embedding: vector(near: base, cosine: cos, seed: seed), qualityPassed: quality, faceCount: faces,
                            anchorScore: anchor, sharpness: 100)
    }

    func context(at seconds: Double = 100_000, stranger: Bool = false, idle: Double? = 5) -> AdaptationContext {
        AdaptationContext(threshold: 0.6, strangerOrUnclearSinceUnlock: stranger, secondsSinceInput: idle,
                          now: t0.addingTimeInterval(seconds))
    }

    @Test("each safeguard rejects on its own")
    func safeguards() {
        let g = gallery
        #expect(Adaptation.evaluate(candidate(), in: g, context: context()) == nil)
        #expect(Adaptation.evaluate(candidate(quality: false), in: g, context: context()) == .quality)
        #expect(Adaptation.evaluate(candidate(faces: 2), in: g, context: context()) == .notOneFace)
        #expect(Adaptation.evaluate(candidate(anchor: 0.59), in: g, context: context()) == .anchorBelowThreshold)
        #expect(Adaptation.evaluate(candidate(), in: g, context: context(stranger: true)) == .strangerSinceUnlock)
        #expect(Adaptation.evaluate(candidate(), in: g, context: context(idle: 61)) == .noRecentInput)
        #expect(Adaptation.evaluate(candidate(), in: g, context: context(idle: nil)) == .noRecentInput)
    }

    @Test("novelty: a near-duplicate of an adaptive template is rejected")
    func novelty() {
        let c = candidate()
        let near = template(vector(near: c.embedding, cosine: 0.95, seed: 7), pool: .adaptive, at: 0)
        #expect(Adaptation.evaluate(c, in: gallery.adding(near), context: context()) == .notNovel)
    }

    @Test("rate limit: one per 10 minutes and 12 per day")
    func rateLimit() {
        let recent = template(unit(1), pool: .adaptive, at: 100_000 - 300)
        #expect(Adaptation.evaluate(candidate(), in: gallery.adding(recent), context: context()) == .tooSoon)
        let day = (0..<12).map { template(unit(1000 + $0), pool: .adaptive, at: 100_000 - 3600 * Double($0 + 1)) }
        #expect(Adaptation.evaluate(candidate(), in: gallery.adding(day), context: context()) == .dailyLimit)
        let yesterday = (0..<12).map { template(unit(2000 + $0), pool: .adaptive, at: 100_000 - 90_000 - Double($0) * 700) }
        #expect(Adaptation.evaluate(candidate(), in: gallery.adding(yesterday), context: context()) == nil)
    }

    @Test("expiry after 60 days, the 120 cap, and reset")
    func poolLifecycle() {
        let old = template(unit(3), pool: .adaptive, at: 0)
        let fresh = template(unit(4), pool: .adaptive, at: 59 * 86_400)
        let g = gallery.adding([old, fresh])
        let expired = Adaptation.expiring(g, now: t0.addingTimeInterval(61 * 86_400))
        #expect(expired.adaptive.map(\.id) == [fresh.id])
        #expect(expired.anchors.count == 10)

        var big = gallery
        for i in 0..<125 { big = Adaptation.adding(template(unit(5000 + i), pool: .adaptive, at: Double(i)), to: big) }
        #expect(big.adaptive.count == 120)
        #expect(big.adaptive.map(\.capturedAt).min() == t0.addingTimeInterval(5))
        #expect(Adaptation.resetting(big).adaptive.isEmpty)
        #expect(Adaptation.resetting(big).anchors.count == 10)
    }
}
