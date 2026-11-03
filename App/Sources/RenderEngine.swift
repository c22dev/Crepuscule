// Crepuscule - RenderEngine.swift
// Constantin Clerc (c22dev) - 0.1
import Crepuscule
import ImageIO
import Metal
import UIKit
import UniformTypeIdentifiers

enum EngineError: LocalizedError {
    case missingLUT
    var errorDescription: String? { "The print LUT isn't in the app bundle. Run Scripts/extract-assets.sh and rebuild." }
}

actor RenderEngine {
    static let shared = RenderEngine()

    private var renderer: ColorPipelineRenderer?
    private var lut: MTLTexture?
    private var memory: [(url: URL, proxy: RawProxy)] = []
    private let proxyCache: ProxyCache
    private var vignette = UserDefaults.standard.object(forKey: "appleVignetteAmount") as? Double ?? 1

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        proxyCache = ProxyCache(directory: caches.appendingPathComponent("Proxies"))
    }

    private func ready() throws -> (ColorPipelineRenderer, MTLTexture) {
        if let renderer, let lut { return (renderer, lut) }
        let r = try ColorPipelineRenderer()
        r.appleVignetteAmount = vignette
        guard let url = Bundle.main.url(forResource: "PrintLUT", withExtension: "cube") else { throw EngineError.missingLUT }
        let l = try r.loadCube(url: url)
        renderer = r; lut = l
        return (r, l)
    }

    func makeLiveGrader() throws -> LiveGrader {
        let (r, l) = try ready()
        return LiveGrader(renderer: try ColorPipelineRenderer(device: r.device, library: r.library), lut: l)
    }

    private func proxy(_ url: URL, useDisk: Bool) throws -> RawProxy {
        if let i = memory.firstIndex(where: { $0.url == url }) {
            let hit = memory.remove(at: i)
            memory.append(hit)
            return hit.proxy
        }
        let (r, _) = try ready()
        let p = try r.proxy(for: url, cache: useDisk ? proxyCache : nil)
        memory.append((url, p))
        if memory.count > 4 { memory.removeFirst() }
        return p
    }

    func fullSize(of url: URL, useDisk: Bool) throws -> (width: Int, height: Int) {
        let p = try proxy(url, useDisk: useDisk)
        return (p.fullWidth, p.fullHeight)
    }

    func preview(url: URL, grade: Grade, seed: Float, longSide: Int? = nil, useDisk: Bool) throws -> CGImage {
        let (r, l) = try ready()
        let p = try proxy(url, useDisk: useDisk)
        let framed = try r.applyGeometry(p.texture, grade: grade, longSide: longSide)
        return try r.cgImage(r.grade(framed, grade: grade, baselineStops: p.baselineStops, lut: l, seed: seed))
    }

    func writeThumbnail(url: URL, grade: Grade, seed: Float, to file: URL, useDisk: Bool) throws {
        let image = try preview(url: url, grade: grade, seed: seed, longSide: 720, useDisk: useDisk)
        let data = try ExportEncoder.encode(image, format: .jpeg, quality: 0.85)
        try data.write(to: file, options: .atomic)
    }

    func export(url: URL, grade: Grade, seed: Float, settings: AppSettings) throws -> URL {
        let (r, l) = try ready()
        let image = try r.render(dng: url, grade: grade, lut: l, seed: seed, exportLongSide: settings.exportLongSide)
        let meta = ExportEncoder.metadata(from: url, software: "Crepuscule")
        let format = settings.exportFormatForEncoder
        let data = try ExportEncoder.encode(image, format: format, quality: settings.exportQuality, metadata: meta)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.fileExtension)
        try data.write(to: out, options: .atomic)
        return out
    }

    func invalidate(_ url: URL) { memory.removeAll { $0.url == url } }

    func setVignette(_ amount: Double) {
        vignette = amount
        renderer?.appleVignetteAmount = amount
        memory.removeAll()
    }

    func cacheBytes() -> Int { proxyCache.byteCount }
    func clearCache() { proxyCache.removeAll(); memory.removeAll() }
}
