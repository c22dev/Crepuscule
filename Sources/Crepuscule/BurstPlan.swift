// Crepuscule - BurstPlan.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public struct BurstFrameSpec: Equatable, Sendable {
    public enum Role: Sendable { case base, short }
    public var sequence: Int
    public var role: Role
    public var iso: Float
    public var durationSeconds: Double
    public var exposureScale: Double
}

public struct BurstHints: Sendable {
    public var nearClipFraction: Float, hardClipFraction: Float, shadowFraction: Float
    public var sampleAgeSeconds: Double
    public init(nearClipFraction: Float = 0, hardClipFraction: Float = 0, shadowFraction: Float = 0, sampleAgeSeconds: Double = .infinity) {
        self.nearClipFraction = nearClipFraction; self.hardClipFraction = hardClipFraction
        self.shadowFraction = shadowFraction; self.sampleAgeSeconds = sampleAgeSeconds
    }
}

public struct NightBurst: Sendable, Equatable {
    public var rotationRate: Double?
    public var pixelsPerRadian: Double
    public static let maxFrames = 16
    public static let budget = 2.0
    public static let blurPixels = 1.5
    public init(rotationRate: Double?, pixelsPerRadian: Double) { self.rotationRate = rotationRate; self.pixelsPerRadian = pixelsPerRadian }

    public static func applies(iso: Float, duration: Double) -> Bool { Double(iso) * duration >= 20 }

    func frameDuration(iso: Float, duration: Double, limits l: BurstPlanner.Limits) -> Double {
        var d = duration
        if let rate = rotationRate, rate > 0, pixelsPerRadian > 0 { d = min(d, Self.blurPixels / (rate * pixelsPerRadian)) }
        d = max(d, Double(iso) * duration / Double(l.maxISO))
        return min(max(d, l.minDuration), min(l.maxDuration, 0.25))
    }
}

public enum BurstPlanner {
    public struct Limits: Sendable {
        public var minISO, maxISO: Float, minDuration, maxDuration: Double
        public init(minISO: Float, maxISO: Float, minDuration: Double, maxDuration: Double) {
            self.minISO = minISO; self.maxISO = maxISO; self.minDuration = minDuration; self.maxDuration = maxDuration
        }
    }

    public static func frameCount(iso: Float) -> Int {
        switch iso { case ..<150: return 3; case ..<300: return 4; case ..<600: return 5; case ..<1200: return 6; case ..<2400: return 7; default: return 8 }
    }

    public static func plan(iso rawISO: Float, duration rawDuration: Double, limits l: Limits, hints: BurstHints = BurstHints(), highlightRetentionStops: Double = 2,
                            night: NightBurst? = nil) -> [BurstFrameSpec] {
        var iso = min(max(rawISO.isFinite && rawISO > 0 ? rawISO : l.minISO, l.minISO), l.maxISO)
        var duration = min(max(rawDuration.isFinite && rawDuration > 0 ? rawDuration : 1.0 / 60, l.minDuration), l.maxDuration)
        var count = frameCount(iso: iso)
        if let night, NightBurst.applies(iso: iso, duration: duration) {
            let d = night.frameDuration(iso: iso, duration: duration, limits: l)
            iso = min(max(iso * Float(duration / d), l.minISO), l.maxISO)
            duration = d
            count = min(max(count, Int(NightBurst.budget / d)), NightBurst.maxFrames)
        } else if duration > 0 {
            let budget = Int(0.6 / duration)
            count = budget < 2 ? 2 : min(budget, count)
        }
        let useHints = hints.sampleAgeSeconds < 0.5
        let hardClip = useHints && hints.hardClipFraction > 0.005
        let noHighlights = useHints && hints.nearClipFraction < 0.001 && hints.shadowFraction <= 0.3

        var shorts: [BurstFrameSpec] = []
        if noHighlights {
            count = night != nil && count > 7 ? count : min(count, 7) + 1
        } else {
            let stops = min(max(highlightRetentionStops, 0.5), 4)
            func short(_ s: Double) -> BurstFrameSpec? {
                let target = pow(2, s)
                let d = max(duration / target, l.minDuration)
                let ratio = duration / d
                let i = max(iso / Float(target / ratio), l.minISO)
                let actual = ratio * Double(iso / i)
                guard target * 0.7 <= actual else { return nil }
                return BurstFrameSpec(sequence: 0, role: .short, iso: i, durationSeconds: min(max(d, l.minDuration), l.maxDuration), exposureScale: actual)
            }
            let first = short(stops)
            if let first { shorts.append(first) }
            if hardClip, let deep = short(stops + 3) {
                shorts.append(deep)
            } else if let first {
                shorts.append(first)
            }
        }

        var positions = Set<Int>()
        if shorts.count == 2 {
            positions.insert(count < 3 ? 1 : (count * 171) >> 9)
            positions.insert(min((count * 172) >> 8, count - 1))
        } else if shorts.count == 1 {
            positions.insert(count >> 1)
        }
        var frames: [BurstFrameSpec] = []
        var used = 0
        // count = base frames, shorts get slotted in front (like 100039ee8)
        for i in 0..<count {
            if positions.contains(i), used < shorts.count {
                frames.append(shorts[used]); used += 1
            }
            frames.append(BurstFrameSpec(sequence: 0, role: .base, iso: iso, durationSeconds: duration, exposureScale: 1))
        }
        while used < shorts.count {
            frames.insert(shorts[used], at: max(frames.count - 1, 0)); used += 1
        }
        for i in frames.indices { frames[i].sequence = i }
        return frames
    }
}
