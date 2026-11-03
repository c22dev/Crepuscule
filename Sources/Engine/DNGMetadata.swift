// Crepuscule - DNGMetadata.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public struct DNGMetadata: Sendable {
    public var make = ""
    public var isMosaic = false
    public var baselineExposureTag: Float = 0
    public var colorMatrices: [[Double]] = [[], []]
    public var forwardMatrices: [[Double]] = [[], []]
    public var cameraCalibrations: [[Double]] = [[], []]
    public var illuminants: [Int] = [0, 0]
    public var analogBalance: [Double] = []
    public var asShotNeutral: [Double] = []
    public var mergeHeadroomStops: Float = 0
    public var burstMerge: BurstMergeInfo?

    public var asShotMultipliers: [Double] {
        guard asShotNeutral.count == 3, asShotNeutral[0] != 0 else { return [] }
        return asShotNeutral.map { abs($0) > 0.0001 ? 1 / $0 : 0 }
    }

    public var baselineExposureStops: Float {
        let tag = abs(baselineExposureTag) < 10 ? baselineExposureTag : 0
        let apple = make.lowercased().hasPrefix("apple")
        return tag + ((!isMosaic && apple) ? 2.0 : 0.5) + mergeHeadroomStops
    }

    public init() {}

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8 else { throw PipelineError.invalidDNG("file too short") }
        let reader: TIFFReader
        switch (data[0], data[1]) {
        case (0x49, 0x49): reader = TIFFReader(data: data, little: true)
        case (0x4D, 0x4D): reader = TIFFReader(data: data, little: false)
        default: throw PipelineError.invalidDNG("not a TIFF container")
        }
        let root = reader.entries(at: Int(reader.u32(4)))
        apply(reader, root)
        var largest = 0
        for ifd in [root] + reader.ints(root[330]).map({ reader.entries(at: $0) }) {
            let photometric = reader.ints(ifd[262]).first
            guard (reader.ints(ifd[254]).first ?? 0) == 0, photometric == 32803 || photometric == 34892 else { continue }
            let area = (reader.ints(ifd[256]).first ?? 0) * (reader.ints(ifd[257]).first ?? 0)
            if area > largest {
                largest = area
                isMosaic = photometric == 32803
            }
        }
    }

    private mutating func apply(_ r: TIFFReader, _ e: [UInt16: TIFFReader.Entry]) {
        make = r.string(e[271])
        baselineExposureTag = Float(r.doubles(e[50730]).first ?? 0)
        colorMatrices = [r.doubles(e[50721]), r.doubles(e[50722])]
        cameraCalibrations = [r.doubles(e[50723]), r.doubles(e[50724])]
        forwardMatrices = [r.doubles(e[50964]), r.doubles(e[50965])]
        analogBalance = r.doubles(e[50727])
        asShotNeutral = r.doubles(e[50728])
        illuminants = [r.ints(e[50778]).first ?? 0, r.ints(e[50779]).first ?? 0]
        if let marker = BurstMergeInfo(marker: r.string(e[65000])) {
            burstMerge = marker
            mergeHeadroomStops = marker.headroomStops
        }
    }
}

public struct BurstMergeInfo: Equatable, Sendable {
    public var frames = 0, shorts = 0, algorithm = 0
    public var headroomStops: Float = 0, exposureBiasStops: Float = 0

    public init?(marker: String) {
        guard marker.hasPrefix(BurstMerger.markerPrefix) || marker.hasPrefix(BurstMerger.legacyMarkerPrefix) else { return nil }
        for part in marker.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "frames": frames = Int(kv[1]) ?? 0
            case "shorts": shorts = Int(kv[1]) ?? 0
            case "alg": algorithm = Int(kv[1]) ?? 0
            case "headroom": headroomStops = Float(kv[1]) ?? 0
            case "bias": exposureBiasStops = Float(kv[1]) ?? 0
            default: break
            }
        }
    }
}

struct TIFFReader {
    struct Entry { let type: UInt16; let count: Int; let valueOffset: Int }
    let data: Data
    let little: Bool

    func u16(_ o: Int) -> UInt16 {
        guard o + 2 <= data.count else { return 0 }
        let v = UInt16(data[o]) | UInt16(data[o + 1]) << 8
        return little ? v : v.byteSwapped
    }
    func u32(_ o: Int) -> UInt32 {
        guard o + 4 <= data.count else { return 0 }
        let v = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[o + $1]) << UInt32($1 * 8) }
        return little ? v : v.byteSwapped
    }

    func entries(at offset: Int) -> [UInt16: Entry] {
        var out: [UInt16: Entry] = [:]
        guard offset > 0, offset + 2 <= data.count else { return out }
        for i in 0..<Int(u16(offset)) {
            let p = offset + 2 + i * 12
            guard p + 12 <= data.count else { break }
            let type = u16(p + 2), count = Int(u32(p + 4))
            let sizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8]
            let size = (sizes[type] ?? 1) * count
            out[u16(p)] = Entry(type: type, count: count, valueOffset: size <= 4 ? p + 8 : Int(u32(p + 8)))
        }
        return out
    }

    func doubles(_ e: Entry?) -> [Double] {
        guard let e, e.count < 4096 else { return [] }
        return (0..<e.count).map { i in
            switch e.type {
            case 1, 7: return Double(data[e.valueOffset + i])
            case 3: return Double(u16(e.valueOffset + i * 2))
            case 4: return Double(u32(e.valueOffset + i * 4))
            case 5: return Double(u32(e.valueOffset + i * 8)) / Double(max(u32(e.valueOffset + i * 8 + 4), 1))
            case 9: return Double(Int32(bitPattern: u32(e.valueOffset + i * 4)))
            case 10: return Double(Int32(bitPattern: u32(e.valueOffset + i * 8))) / Double(Int32(bitPattern: u32(e.valueOffset + i * 8 + 4)))
            case 11: return Double(Float(bitPattern: u32(e.valueOffset + i * 4)))
            case 12:
                let lo = UInt64(u32(e.valueOffset + i * 8 + (little ? 0 : 4))), hi = UInt64(u32(e.valueOffset + i * 8 + (little ? 4 : 0)))
                return Double(bitPattern: hi << 32 | lo)
            default: return 0
            }
        }
    }
    func ints(_ e: Entry?) -> [Int] { doubles(e).map { Int($0) } }
    func string(_ e: Entry?) -> String {
        guard let e, e.valueOffset + e.count <= data.count else { return "" }
        return String(decoding: data[e.valueOffset..<(e.valueOffset + e.count)].prefix { $0 != 0 }, as: UTF8.self)
    }
}
