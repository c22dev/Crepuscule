// Crepuscule - Grade.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public enum HalationPreset: Int, Codable, CaseIterable, Sendable {
    case photochemical = 0
    case optical = 1

    var lightWrap: LightWrapParams {
        switch self {
        case .photochemical: return LightWrapParams(redSens: 1.0, redIntens: 1.0, colorR: 1.0, colorG: 0x1.99999ap-2, colorB: 0.0)
        case .optical: return LightWrapParams(redSens: 0x1.666666p-1, redIntens: 1.0, colorR: 1.0, colorG: 1.0, colorB: 1.0)
        }
    }
}

public struct HalationParams: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var preset: HalationPreset
    public init(enabled: Bool = true, preset: HalationPreset = .photochemical) {
        self.enabled = enabled
        self.preset = preset
    }
}

public struct CropInsets: Codable, Equatable, Sendable {
    public var left, top, right, bottom: Double
    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    var areaFraction: Double { (1 - left - right) * (1 - top - bottom) }
}

public struct Grade: Codable, Equatable, Sendable {
    public var blackAndWhite = false
    public var exposureStops: Float = 0
    public var colorTemp: Float = 0
    public var tint: Float = 0
    public var halation = HalationParams()
    public var grainAmplitude: Float = 1.25
    public var pixSizeGrain = false
    public var grainSize: Float = 1.0
    public var grainDetail: Float = 0
    public var atanContrast: Float = 0
    public var atanPivot: Float = 0x1.666666p-2
    public var highlights: Float = 0
    public var shadows: Float = 0
    public var saturation: Float = 1.0
    public var cropInsets = CropInsets()
    public var mirrored = false
    public var rotationQuarterTurns = 0
    public var fineRotationDegrees = 0.0

    public init() {}
}

public enum Presets {
    public static let factoryDefault = Grade()
    public static let photochemicalHalation = factoryDefault
    public static let opticalHalation: Grade = {
        var g = Grade(); g.halation.preset = .optical; return g
    }()
    public static let noHalation: Grade = {
        var g = Grade(); g.halation.enabled = false; return g
    }()
    public static let blackAndWhite: Grade = {
        var g = Grade(); g.blackAndWhite = true; return g
    }()
    public static let all: [String: Grade] = [
        "default": factoryDefault, "optical": opticalHalation,
        "no-halation": noHalation, "bw": blackAndWhite,
    ]
}

public func shoulderToeParams(highlights: Float, shadows: Float) -> ShoulderToeParams {
    let h = min(max(highlights, -1), 1), s = min(max(shadows, -1), 1)
    return ShoulderToeParams(
        highlights: (h < 0 ? h * 0x1.6b851ep-1 : h * 4) + 1,
        shadows: s * (s >= 0 ? 0.5 : 0.95) + 1,
        highlightsFalloff: 3, shadowsFalloff: 4,
        enabled: (h == 0 && s == 0) ? 0 : 1)
}
