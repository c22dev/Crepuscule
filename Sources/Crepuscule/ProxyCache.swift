// Crepuscule - ProxyCache.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation
import Metal

public struct RawProxy {
    public let texture: MTLTexture
    public let baselineStops: Float
    public let fullWidth, fullHeight: Int
}

public final class ProxyCache: @unchecked Sendable {
    enum Header {
        static let size = 24
        static let magic: UInt32 = 0x35585051
    }

    public let directory: URL
    public var byteLimit: Int
    private let lock = NSLock()

    public init(directory: URL, byteLimit: Int = 300 << 20) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    func fileURL(for source: URL, maxDimension: Int, vignette: Double = 1) -> URL? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { return nil }
        let name = "\(source.lastPathComponent)_\(size)_\(Int(date.timeIntervalSince1970))_\(maxDimension)\(vignette == 1 ? "" : String(format: "_v%.3f", vignette)).proxy"
        return directory.appendingPathComponent(name)
    }

    func read(_ file: URL, renderer: ColorPipelineRenderer) -> RawProxy? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count > Header.size else { return nil }
        let fields = data.withUnsafeBytes { raw in (0..<6).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) } }
        let baseline = Float(bitPattern: fields[5])
        let w = Int(fields[1]), h = Int(fields[2])
        guard fields[0] == Header.magic, w > 0, h > 0,
              let packed = Self.decompress(data.subdata(in: Header.size..<data.count), width: w, height: h),
              let texture = try? renderer.unpack(packed, width: w, height: h) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return RawProxy(texture: texture, baselineStops: baseline, fullWidth: Int(fields[3]), fullHeight: Int(fields[4]))
    }

    func write(_ packed: Data, width: Int, height: Int, fullWidth: Int, fullHeight: Int, baselineStops: Float, to file: URL) throws {
        var data = Data(count: Header.size)
        data.withUnsafeMutableBytes { raw in
            let fields = [Header.magic, UInt32(width), UInt32(height), UInt32(fullWidth), UInt32(fullHeight), baselineStops.bitPattern]
            for (i, f) in fields.enumerated() { raw.storeBytes(of: f, toByteOffset: i * 4, as: UInt32.self) }
        }
        guard let compressed = Self.compress(packed.prefix(width * height * 6), width: width, height: height) else { throw PipelineError.texture }
        data.append(compressed)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        evict()
    }

    static func compress(_ packed: Data, width: Int, height: Int) -> Data? {
        let n = width * height * 3
        guard packed.count >= n * 2 else { return nil }
        var planes = Data(count: n * 2)
        packed.withUnsafeBytes { src in
            planes.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: UInt16.self), hi = dst.baseAddress!.assumingMemoryBound(to: UInt8.self), lo = hi + n
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width * 3
                    for x in 0..<(width * 3) {
                        let i = row + x
                        let v = UInt16(littleEndian: s[i])
                        let d = x < 3 ? v : v &- UInt16(littleEndian: s[i - 3])
                        hi[i] = UInt8(d >> 8); lo[i] = UInt8(d & 0xFF)
                    }
                }
            }
        }
        return try? (planes as NSData).compressed(using: .lzfse) as Data
    }

    static func decompress(_ data: Data, width: Int, height: Int) -> Data? {
        let n = width * height * 3
        guard let planes = try? (data as NSData).decompressed(using: .lzfse) as Data, planes.count == n * 2 else { return nil }
        var packed = Data(count: n * 2)
        planes.withUnsafeBytes { src in
            packed.withUnsafeMutableBytes { dst in
                let hi = src.baseAddress!.assumingMemoryBound(to: UInt8.self), lo = hi + n
                let d = dst.bindMemory(to: UInt16.self)
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let row = y * width * 3
                    for x in 0..<(width * 3) {
                        let i = row + x
                        let delta = UInt16(hi[i]) << 8 | UInt16(lo[i])
                        let v = x < 3 ? delta : delta &+ UInt16(littleEndian: d[i - 3])
                        d[i] = v.littleEndian
                    }
                }
            }
        }
        return packed
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "proxy" }.compactMap {
            guard let v = try? $0.resourceValues(forKeys: Set(keys)), let s = v.fileSize, let d = v.contentModificationDate else { return nil }
            return ($0, s, d)
        }
    }

    public var byteCount: Int { entries().reduce(0) { $0 + $1.size } }

    func evict() {
        lock.lock(); defer { lock.unlock() }
        var all = entries().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        while total > byteLimit, all.count > 1 {
            let oldest = all.removeFirst()
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }
}

extension ColorPipelineRenderer {
    public func proxy(for url: URL, maxDimension: Int = 2048, cache: ProxyCache? = nil) throws -> RawProxy {
        let file = cache?.fileURL(for: url, maxDimension: maxDimension, vignette: appleVignetteAmount)
        if let cache, let file, let hit = cache.read(file, renderer: self) { return hit }
        let raw = try decode(url: url)
        let packed = try uploadPacked(raw, maxDimension: maxDimension)
        let proxy = RawProxy(texture: try unpack(packed.data, width: packed.width, height: packed.height), baselineStops: raw.baselineExposureStops,
                             fullWidth: raw.width, fullHeight: raw.height)
        if let cache, let file {
            try? cache.write(packed.data, width: packed.width, height: packed.height, fullWidth: raw.width, fullHeight: raw.height,
                             baselineStops: raw.baselineExposureStops, to: file)
        }
        return proxy
    }
}
