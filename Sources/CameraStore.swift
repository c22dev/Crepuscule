// Crepuscule - CameraStore.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

@MainActor
protocol CameraStore: AnyObject {
    var burstMerge: Bool { get }
    var bracketMetering: CameraCapture.BracketMetering { get }
    var highlightRetentionStops: Double { get }
    var aspectRatioPreset: AspectRatioPreset { get set }
    var perImageDefaults: Grade { get set }
    var allLooks: [(name: String, grade: Grade)] { get }
    func file(_ result: CaptureResult, bias: Float, aspect: AspectRatioPreset, tag: String?, cropFactor: Double, night: Bool, mirror: Bool) throws -> (() async throws -> Void)?
}

enum ExposureText {
    static func shutter(_ s: Double) -> String {
        guard s > 0 else { return "—" }
        if s >= 0.3 { return String(format: "%.1f″", s) }
        return "1/\(Int((1 / s).rounded()))"
    }
    static func ev(_ v: Float) -> String { String(format: "%+.1f", v) }
    static func aperture(_ f: Float) -> String { f >= 10 ? String(format: "ƒ/%.0f", f) : String(format: "ƒ/%.1f", f) }
}
