// Crepuscule - ManualExposure.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public struct ManualSettings: Sendable, Equatable, Codable {
    public var iso: Float?
    public var duration: Double?
    public var aperture: Float?
    public var lensPosition: Float?
    public init(iso: Float? = nil, duration: Double? = nil, aperture: Float? = nil, lensPosition: Float? = nil) {
        self.iso = iso; self.duration = duration; self.aperture = aperture; self.lensPosition = lensPosition
    }

    public var exposureManual: Bool { iso != nil || duration != nil || aperture != nil }
    public var isAuto: Bool { !exposureManual && lensPosition == nil }
}

public struct ManualRange: Sendable, Equatable {
    public var minISO, maxISO: Float
    public var minDuration, maxDuration: Double
    public var minAperture, maxAperture: Float
    public var apertureStops: [Float]
    public var manualFocus: Bool
    public init(minISO: Float, maxISO: Float, minDuration: Double, maxDuration: Double,
                minAperture: Float, maxAperture: Float, apertureStops: [Float] = [], manualFocus: Bool) {
        self.minISO = minISO; self.maxISO = maxISO; self.minDuration = minDuration; self.maxDuration = maxDuration
        self.minAperture = minAperture; self.maxAperture = maxAperture; self.apertureStops = apertureStops; self.manualFocus = manualFocus
    }
    // only the 18 pro main cam so far
    public var variableAperture: Bool { maxAperture > minAperture + 0.05 }
}

public enum ManualStops {
    static let isoThirds: [Float] = [12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250,
                                     1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600]
    static let apertureThirds: [Float] = [1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16]
    static let shutterThirds: [Double] = [1.0 / 16000, 1.0 / 12800, 1.0 / 10000, 1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200, 1.0 / 2500,
                                          1.0 / 2000, 1.0 / 1600, 1.0 / 1250, 1.0 / 1000, 1.0 / 800, 1.0 / 640, 1.0 / 500, 1.0 / 400, 1.0 / 320,
                                          1.0 / 250, 1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100, 1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 40, 1.0 / 30,
                                          1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10, 1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 0.3, 0.4, 0.5, 0.6,
                                          0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]

    public static func iso(in r: ManualRange) -> [Float] { fit(isoThirds, Double(r.minISO), Double(r.maxISO)).map { Float($0) } }
    public static func shutter(in r: ManualRange) -> [Double] { fit(shutterThirds, r.minDuration, r.maxDuration) }
    public static func aperture(in r: ManualRange) -> [Float] {
        guard r.variableAperture else { return [] }
        let device = r.apertureStops.filter { $0 >= r.minAperture - 0.01 && $0 <= r.maxAperture + 0.01 }.sorted()
        return device.count > 1 ? device : fit(apertureThirds, Double(r.minAperture), Double(r.maxAperture)).map { Float($0) }
    }

    private static func fit<T: BinaryFloatingPoint>(_ stops: [T], _ lo: Double, _ hi: Double) -> [Double] {
        guard lo > 0, hi >= lo else { return [] }
        var out = stops.map(Double.init).filter { $0 >= lo * 0.999 && $0 <= hi * 1.001 }
        if out.first.map({ $0 > lo * 1.08 }) ?? true { out.insert(lo, at: 0) }
        if out.last.map({ $0 < hi / 1.08 }) ?? true { out.append(hi) }
        return out
    }

    public static func nearest<T: BinaryFloatingPoint>(_ v: T, in stops: [T]) -> Int {
        guard !stops.isEmpty, v > 0 else { return 0 }
        let l = log2(Double(v))
        return stops.indices.min { abs(log2(Double(stops[$0])) - l) < abs(log2(Double(stops[$1])) - l) } ?? 0
    }
}
