// Crepuscule - DemoCamera.swift
// Constantin Clerc (c22dev) - 0.1
#if targetEnvironment(simulator)
import AVFoundation
import Crepuscule
import CoreImage
import UIKit

enum DemoScene {
    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func background(_ u: Double, _ v: Double, seed: Double) -> SIMD3<Double> {
        let horizon = 0.56 + 0.03 * sin(u * 5 + seed)
        let t = min(v / horizon, 1)
        let high = SIMD3<Double>(0.10, 0.16, 0.36) * (1 - t)
        let low = SIMD3<Double>(0.98, 0.5, 0.26) * (t * t)
        var c: SIMD3<Double> = high + low + SIMD3<Double>(0.06, 0.05, 0.06)
        let d = hypot(u - (0.25 + 0.5 * (seed / 7).truncatingRemainder(dividingBy: 1)), (v - horizon + 0.07) * 1.3)
        let glow: Double = 0.012 / max(d * d, 0.0008)
        c += SIMD3<Double>(1, 0.72, 0.42) * glow
        let swell: Double = 0.06 * sin(u * 3.1 + seed * 1.7) + 0.02 * sin(u * 9)
        let ridge: Double = horizon - 0.1 - swell
        let depth: Double = min(max((v - ridge) / (horizon - ridge), 0), 1)
        let hills: SIMD3<Double> = SIMD3<Double>(0.05, 0.05, 0.08) + SIMD3<Double>(0.24, 0.11, 0.07) * depth
        let onHill = smooth(ridge - 0.002, ridge + 0.002, v)
        c = c * (1 - onHill) + hills * onHill
        let f = min(max((v - horizon) / (1 - horizon), 0), 1)
        let far = SIMD3<Double>(0.15, 0.18, 0.045) * (1 - f)
        let near = SIMD3<Double>(0.018, 0.045, 0.016) * f
        let wave: Double = 0.85 + 0.25 * sin(u * 40 + v * 90 + 2 * sin(u * 13 + seed))
        let field: SIMD3<Double> = (far + near) * wave
        let onField = smooth(horizon - 0.002, horizon + 0.002, v)
        return c * (1 - onField) + field * onField
    }

    static func poppies(seed: Double) -> [(x: Double, y: Double, r: Double)] {
        var g = SeededRandom(seed: UInt64(seed * 1000) + 11)
        return (0..<170).map { _ in
            let t = pow(Double.random(in: 0...1, using: &g), 1.4)
            return (Double.random(in: -0.02...1.02, using: &g), 0.585 + t * 0.42, 0.004 + t * t * 0.042)
        }.sorted { $0.y < $1.y }
    }

    static func rgb16(width: Int, height: Int, seed: Double, ev: Double) -> Data {
        let gain = pow(2, ev)
        var buf = [SIMD3<Double>](repeating: .zero, count: width * height)
        buf.withUnsafeMutableBufferPointer { b in
            let p = b.baseAddress!
            nonisolated(unsafe) let shared = p
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width { shared[y * width + x] = background(Double(x) / Double(width), Double(y) / Double(height), seed: seed) }
            }
        }
        for f in poppies(seed: seed) {
            let rx = f.r * Double(width), ry = f.r * 0.75 * Double(width)
            let cx = f.x * Double(width), cy = f.y * Double(height)
            for y in max(Int(cy - ry), 0)..<max(min(Int(cy + ry) + 1, height), max(Int(cy - ry), 0)) {
                for x in max(Int(cx - rx), 0)..<max(min(Int(cx + rx) + 1, width), max(Int(cx - rx), 0)) {
                    let dx = (Double(x) - cx) / rx, dy = (Double(y) - cy) / ry
                    let d = dx * dx + dy * dy
                    guard d < 1 else { continue }
                    let a = min((1 - d) * 5, 1)
                    let petal: SIMD3<Double> = SIMD3<Double>(0.8, 0.035, 0.01) * (0.55 + (1 - d) * 0.8)
                    let centre: SIMD3<Double> = d < 0.05 ? SIMD3<Double>(0.01, 0.01, 0.01) : petal
                    buf[y * width + x] = buf[y * width + x] * (1 - a) + centre * a
                }
            }
        }
        var data = Data(count: width * height * 6)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self)
            for i in 0..<(width * height) {
                let c = simd_min(simd_max(buf[i] * gain, .zero), SIMD3(repeating: 1))
                out[i * 3] = UInt16(c.x * 65535); out[i * 3 + 1] = UInt16(c.y * 65535); out[i * 3 + 2] = UInt16(c.z * 65535)
            }
        }
        return data
    }

    static func viewfinderImage(seed: Double) -> CIImage {
        let w = 810, h = 1080
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let image = CIImage(bitmapData: rgba16(rgb16(width: w, height: h, seed: seed, ev: 0)), bytesPerRow: w * 8,
                            size: CGSize(width: w, height: h), format: .RGBA16, colorSpace: linear)
        return image.oriented(.up)
    }

    private static func rgba16(_ rgb: Data) -> Data {
        var out = Data(count: rgb.count / 3 * 4)
        rgb.withUnsafeBytes { s in
            out.withUnsafeMutableBytes { d in
                let a = s.bindMemory(to: UInt16.self), b = d.bindMemory(to: UInt16.self)
                for i in 0..<(a.count / 3) {
                    b[i * 4] = a[i * 3]; b[i * 4 + 1] = a[i * 3 + 1]; b[i * 4 + 2] = a[i * 3 + 2]; b[i * 4 + 3] = 65535
                }
            }
        }
        return out
    }

    static func writeDNG(to url: URL, width: Int, height: Int, seed: Double, ev: Double) throws {
        let pixels = rgb16(width: width, height: height, seed: seed, ev: ev)
        var extra = Data()
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: Data)] = []
        func le16(_ v: [UInt16]) -> Data { v.withUnsafeBytes { Data($0) } }
        func le32(_ v: [UInt32]) -> Data { v.withUnsafeBytes { Data($0) } }
        func srational(_ v: [(Int32, Int32)]) -> Data { v.flatMap { [$0.0, $0.1] }.withUnsafeBytes { Data($0) } }
        func add(_ tag: UInt16, _ type: UInt16, _ count: Int, _ d: Data) { entries.append((tag, type, UInt32(count), d)) }
        let make = Data("Crepuscule\0".utf8), model = Data("Simulator\0".utf8), unique = Data("Crepuscule Simulator\0".utf8)
        add(254, 4, 1, le32([0]))
        add(256, 4, 1, le32([UInt32(width)]))
        add(257, 4, 1, le32([UInt32(height)]))
        add(258, 3, 3, le16([16, 16, 16]))
        add(259, 3, 1, le16([1]))
        add(262, 3, 1, le16([34892]))
        add(271, 2, make.count, make)
        add(272, 2, model.count, model)
        add(273, 4, 1, le32([0]))
        add(274, 3, 1, le16([1]))
        add(277, 3, 1, le16([3]))
        add(278, 4, 1, le32([UInt32(height)]))
        add(279, 4, 1, le32([UInt32(pixels.count)]))
        add(284, 3, 1, le16([1]))
        add(50706, 1, 4, Data([1, 4, 0, 0]))
        add(50708, 2, unique.count, unique)
        add(50721, 10, 9, srational([(32405, 10000), (-15371, 10000), (-4985, 10000), (-9693, 10000), (18760, 10000), (416, 10000), (557, 10000), (-2040, 10000), (10572, 10000)]))
        add(50728, 5, 3, le32([1, 1, 1, 1, 1, 1]))
        add(50778, 3, 1, le16([21]))
        let ifdOffset = 8, ifdSize = 2 + entries.count * 12 + 4
        var cursor = ifdOffset + ifdSize
        var table = Data(le16([UInt16(entries.count)]))
        for var e in entries {
            let isStrip = e.tag == 273
            table += le16([e.tag, e.type]) + le32([e.count])
            if e.value.count <= 4 && !isStrip {
                e.value.append(Data(count: 4 - e.value.count))
                table += e.value
            } else if isStrip {
                table += Data(count: 4)
            } else {
                table += le32([UInt32(cursor)])
                extra += e.value
                cursor += e.value.count
            }
        }
        table += le32([0])
        let stripIndex = entries.firstIndex { $0.tag == 273 }!
        table.replaceSubrange((2 + stripIndex * 12 + 8)..<(2 + stripIndex * 12 + 12), with: le32([UInt32(cursor)]))
        var file = Data([0x49, 0x49, 42, 0]) + le32([UInt32(ifdOffset)])
        file += table
        file += extra
        file += pixels
        try file.write(to: url, options: .atomic)
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

final class DemoCameraBackend: CameraBackend {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStats: ((FrameStats) -> Void)?
    var formatLabel: String { "DEMO RAW" }
    var captureSession: AVCaptureSession? { nil }
    var previewAngle: CGFloat { 90 }
    var sessionQueue: DispatchQueue? { nil }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "crepuscule.demo")
    private let context = CIContext()
    private var base: CIImage?
    private var buffer: CVPixelBuffer?
    private var zoom = 1.0
    private var bias: Float = 0
    private var tick = 0.0
    private let lensList = [
        CameraLens(id: "uw", facing: .back, focalLength: 13, name: "Ultra Wide"),
        CameraLens(id: "w", facing: .back, focalLength: 26, name: "Wide"),
        CameraLens(id: "w2", facing: .back, focalLength: 52, name: "2x", cropFactor: 2, deviceID: "w"),
        CameraLens(id: "t", facing: .back, focalLength: 100, name: "Telephoto"),
        CameraLens(id: "f", facing: .front, focalLength: 23, name: "Front"),
    ]

    func prepare(preferred: (CameraLens) -> Bool) async throws -> (lenses: [CameraLens], active: CameraLens?) {
        base = DemoScene.viewfinderImage(seed: 3)
        CVPixelBufferCreate(kCFAllocatorDefault, 810, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        zoom = 1.6
        resume()
        return (lensList, lensList[1])
    }

    func select(_ lens: CameraLens) async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        queue.sync { zoom = lens.id == "uw" ? 1 : lens.id == "t" ? 4 : lens.id == "f" ? 1.3 : 1.6 }
    }

    func resume() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 20)
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
    }

    func pause() { timer?.cancel(); timer = nil }
    func focus(atViewPoint point: CGPoint, front: Bool) {}
    func setBias(_ stops: Float) { queue.async { self.bias = stops } }
    func lockExposure(atViewPoint point: CGPoint, front: Bool) async -> Bool { false }
    func unlockExposure() {}
    func setShutterLimit(_ denominator: Int?) {}
    func setMuteShutter(_ on: Bool) {}
    func setNightBursts(_ on: Bool) {}
    func setCodeScanning(_ on: Bool, onCode: ((String) -> Void)?) {}
    func setProRAWPreferred(_ on: Bool) async -> Bool { false }
    func reading() -> ExposureReading? {
        ExposureReading(iso: 125, duration: 1.0 / 240, aperture: 1.8, meterOffset: 0, bias: queue.sync { bias })
    }
    func captureAngle() -> CGFloat? { 90 }

    private func frame() {
        guard let base, let buffer else { return }
        tick += 0.02
        let e = base.extent
        let z = zoom * (1 + 0.003 * sin(tick))
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: e.midX + 4 * sin(tick * 0.7), y: e.midY))
        let shown = base.transformed(by: t).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: bias]).cropped(to: e)
        context.render(shown, to: buffer, bounds: e, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        tickStats(buffer)
        onFrame?(buffer)
    }

    private var statCount = 0
    private func tickStats(_ b: CVPixelBuffer) {
        statCount += 1
        if statCount % 4 == 0, let s = FrameStats.measure(b, time: ProcessInfo.processInfo.systemUptime) { onStats?(s) }
    }

    var flashMode = AVCaptureDevice.FlashMode.off

    func shoot(mode: DriveMode, timer: SelfTimer, stack: Bool, retention: Double, metering: CameraCapture.BracketMetering, crop: Double, progress: @escaping @Sendable (DriveProgress) -> Void) async throws -> [CaptureResult] {
        let seed = Double.random(in: 0...20)
        let runner = DriveRunner<CaptureResult>(mode: mode, timer: timer, shoot: { ev in
            try await Task.sleep(nanoseconds: 180_000_000)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
            try DemoScene.writeDNG(to: url, width: 1536, height: 2048, seed: seed, ev: ev)
            return CaptureResult(baseURL: url, frames: [(url, nil)], cropInsets: CropInsets())
        }, waitForStill: { try? await Task.sleep(nanoseconds: 250_000_000) }, progress: progress)
        return try await runner.run()
    }
}

enum DemoSeed {
    @MainActor
    static func requestIntents(_ router: IntentRouter) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoIntentShoot") { router.request(.shoot(drive: .burst3, timer: nil)) }
        if args.contains("-demoIntentLibrary") { router.request(.library) }
        if args.contains("-demoIntentLook") { router.request(.look("Mono")) }
    }

    @MainActor
    static func apply(library: Library, camera: CameraModel, openLibrary: () -> Void) async {
        let d = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        let count = d.integer(forKey: "demoSeed")
        if count > 0, library.items.isEmpty {
            for i in 0..<count {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
                let seed = Double(i) * 2.3 + 1
                await Task.detached { try? DemoScene.writeDNG(to: url, width: 1536, height: 2048, seed: seed, ev: 0) }.value
                let aspect: AspectRatioPreset = i % 5 == 2 ? .flat : .native
                let item = try? library.add(raw: url, aspect: aspect, driveTag: i % 4 == 3 ? "2/3" : nil)
                if let item, i % 6 == 4 {
                    var g = item.grade; g.blackAndWhite = true
                    library.setGrade(g, aspect: aspect, for: item.id)
                }
            }
        }
        if args.contains("-demoScope") { camera.aspect = .flat }
        if args.contains("-demoGridLines") { camera.showGrid = true }
        if args.contains("-demo2x") {
            while camera.phase != .running { try? await Task.sleep(nanoseconds: 100_000_000) }
            if let lens = camera.backLenses.first(where: { $0.cropFactor == 2 }) { camera.select(lens) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if args.contains("-demoShoot") {
            camera.drive = .bracket3; camera.timer = .three
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            camera.pressShutter()
        }
        if args.contains("-demoOpen") || args.contains("-demoSave") || DemoFlags.openGrid || DemoFlags.openEditor {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            openLibrary()
        }
    }
}
#endif
