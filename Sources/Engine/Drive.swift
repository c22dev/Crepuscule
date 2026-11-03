// Crepuscule - Drive.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public enum DriveMode: String, Codable, CaseIterable, Sendable {
    case single, burst3, burst5, bracket3, bracket5

    public var shots: Int {
        switch self { case .single: return 1; case .burst3, .bracket3: return 3; case .burst5, .bracket5: return 5 }
    }
    public var isBracket: Bool { self == .bracket3 || self == .bracket5 }
    public var evOffsets: [Double] {
        switch self {
        case .bracket3: return [0, -1, 1]
        case .bracket5: return [0, -1, 1, -2, 2]
        default: return Array(repeating: 0, count: shots)
        }
    }
}

public enum SelfTimer: Int, Codable, CaseIterable, Sendable {
    case off = 0, three = 3, ten = 10
}

public enum DriveProgress: Equatable, Sendable {
    case countdown(remaining: Int)
    case steadying
    case shot(index: Int, of: Int)
}

public struct DriveRunner<Shot: Sendable>: Sendable {
    public var mode: DriveMode
    public var timer: SelfTimer
    public var shoot: @Sendable (_ ev: Double) async throws -> Shot
    public var sleep: @Sendable (_ seconds: Double) async throws -> Void
    public var waitForStill: @Sendable () async -> Void
    public var progress: @Sendable (DriveProgress) -> Void

    public init(mode: DriveMode, timer: SelfTimer,
                shoot: @escaping @Sendable (Double) async throws -> Shot,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
                waitForStill: @escaping @Sendable () async -> Void = {},
                progress: @escaping @Sendable (DriveProgress) -> Void = { _ in }) {
        self.mode = mode; self.timer = timer; self.shoot = shoot; self.sleep = sleep
        self.waitForStill = waitForStill; self.progress = progress
    }

    public func run() async throws -> [Shot] {
        var remaining = timer.rawValue
        while remaining > 0 {
            progress(.countdown(remaining: remaining))
            try await sleep(1)
            remaining -= 1
        }
        try Task.checkCancellation()
        if mode != .single || timer != .off {
            progress(.steadying)
            await waitForStill()
        }
        var shots: [Shot] = []
        for (i, ev) in mode.evOffsets.enumerated() {
            if Task.isCancelled { break }
            progress(.shot(index: i + 1, of: mode.shots))
            do {
                shots.append(try await shoot(ev))
            } catch {
                if shots.isEmpty { throw error }
                break
            }
        }
        return shots
    }
}

public enum BracketExposure {
    public static func solve(iso: Float, duration: Double, ev: Double, limits l: BurstPlanner.Limits, longestDuration: Double = 0.25) -> (iso: Float, duration: Double) {
        let wanted = duration * pow(2, ev)
        let longest = min(l.maxDuration, max(longestDuration, duration))
        let d = min(max(wanted, l.minDuration), longest)
        let i = iso * Float(wanted / d)
        return (min(max(i, l.minISO), l.maxISO), d)
    }
}

public struct MotionHistory: Sendable {
    public private(set) var samples: [(time: Double, rate: Double)] = []
    public var span: Double = 4

    public init() {}

    public mutating func add(time: Double, rate: Double) {
        samples.append((time, rate))
        if let first = samples.first, time - first.time > span { samples.removeAll { time - $0.time > span } }
    }

    public func angle(from start: Double, to end: Double) -> Double? {
        guard end > start, let first = samples.first, let last = samples.last,
              first.time <= start, last.time >= end - 0.05 else { return nil }
        var total = 0.0
        for (i, s) in samples.enumerated() {
            let next = i + 1 < samples.count ? samples[i + 1].time : max(end, s.time)
            let a = max(s.time, start), b = min(next, end)
            if b > a { total += s.rate * (b - a) }
        }
        return total
    }
}

public struct StillnessDetector: Sendable {
    public var window: Int
    public private(set) var samples: [Double] = []

    public init(window: Int = 12) { self.window = max(window, 1) }

    public mutating func add(rotationRate x: Double, _ y: Double, _ z: Double) {
        samples.append(x * x + y * y + z * z)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    public var rmsRate: Double? {
        guard samples.count == window else { return nil }
        return (samples.reduce(0, +) / Double(window)).squareRoot()
    }

    public static func predictedBlurPixels(rate: Double, duration: Double, horizontalFOVDegrees fov: Double, imageWidth: Int) -> Double {
        guard fov > 0 else { return 0 }
        return rate * duration * Double(imageWidth) / (fov * .pi / 180)
    }

    public func isStill(duration: Double, horizontalFOVDegrees fov: Double, imageWidth: Int, limitPixels: Double = 3) -> Bool {
        guard let rmsRate else { return false }
        return Self.predictedBlurPixels(rate: rmsRate, duration: duration, horizontalFOVDegrees: fov, imageWidth: imageWidth) <= limitPixels
    }
}

public struct CameraLens: Identifiable, Equatable, Sendable {
    public enum Facing: Sendable { case back, front }
    public let id: String
    public let facing: Facing
    public let focalLength: Int
    public let name: String
    public let cropFactor: Double
    public let deviceID: String
    public init(id: String, facing: Facing, focalLength: Int, name: String, cropFactor: Double = 1, deviceID: String? = nil) {
        self.id = id; self.facing = facing; self.focalLength = focalLength; self.name = name
        self.cropFactor = cropFactor; self.deviceID = deviceID ?? id
    }
    public static let maxZoomFocal = 270.0

    public func crop(focal: Double) -> CameraLens {
        let base = Double(focalLength) / cropFactor
        let f = Int(focal.rounded())
        return CameraLens(id: deviceID + "#z\(f)", facing: facing, focalLength: f, name: "\(f)", cropFactor: max(focal / base, 1), deviceID: deviceID)
    }

    public static func equivalentFocalLength(horizontalFOVDegrees fov: Double) -> Int {
        guard fov > 0, fov < 180 else { return 0 }
        return Int((18 / tan(fov * .pi / 360)).rounded())
    }
}

public struct ExposureReading: Equatable, Sendable {
    public var iso: Float
    public var duration: Double
    public var aperture: Float
    public var meterOffset: Float
    public var bias: Float
    public var lensPosition: Float
    public init(iso: Float = 0, duration: Double = 0, aperture: Float = 0, meterOffset: Float = 0, bias: Float = 0, lensPosition: Float = 0) {
        self.iso = iso; self.duration = duration; self.aperture = aperture; self.meterOffset = meterOffset; self.bias = bias
        self.lensPosition = lensPosition
    }
}

extension AspectRatioPreset {
    public func uprightCropInsets(imageWidth w: Double, imageHeight h: Double, cropFactor factor: Double) -> CropInsets {
        let f = 1 / max(factor, 1), edge = (1 - f) / 2
        let c = uprightCropInsets(imageWidth: w * f, imageHeight: h * f)
        return CropInsets(left: edge + c.left * f, top: edge + c.top * f, right: edge + c.right * f, bottom: edge + c.bottom * f)
    }

    public func uprightCropInsets(imageWidth w: Double, imageHeight h: Double, custom: (width: Double, height: Double) = (16, 9)) -> CropInsets {
        guard var target = ratio(custom: custom), w > 0, h > 0 else { return CropInsets() }
        if h > w, target > 1 { target = 1 / target }
        let current = w / h
        if target < current {
            let inset = (1 - target / current) / 2
            return CropInsets(left: inset, right: inset)
        }
        let inset = (1 - current / target) / 2
        return CropInsets(top: inset, bottom: inset)
    }
}
