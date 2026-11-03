// Crepuscule - SuperResolution.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public enum SuperResolution {
    public static let algorithmVersion = 1

    nonisolated(unsafe) static var trace: ((_ index: Int, _ cols: Int, _ fx: [Float], _ fy: [Float], _ robust: [Float]?) -> Void)?

    public struct Rect: Sendable, Equatable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
        func offset(_ dx: Int, _ dy: Int) -> Rect { Rect(x: x + dx, y: y + dy, width: width, height: height) }
    }

    struct Options {
        var kDetail: Float = 0.33
        var kDenoise: Float = 3
        var kStretch: Float = 3
        var kShrink: Float = 1.5
        var edgeLow: Float = 1.5
        var edgeHigh: Float = 5
        var anisotropic = true
        var robustness = true
        var robustScale: Float = 12
        var robustThreshold: Float = 0.12
        var localStdWeight: Float = 1
        var aliasWeight: Float = 0.5
        var minWeight: Float = 0.6
        var margin = 96
    }

    struct Plan {
        var crop: Rect, window: Rect
        var outWidth: Int, outHeight: Int
        var cx: Int { crop.x - window.x }
        var cy: Int { crop.y - window.y }
        var sx: Float { Float(outWidth) / Float(crop.width) }
        var sy: Float { Float(outHeight) / Float(crop.height) }
    }

    static func plan(width W: Int, height H: Int, area: Rect?, cropFactor: Double, outputScale: Double?, margin: Int) throws -> Plan {
        guard cropFactor >= 1, cropFactor.isFinite else { throw PipelineError.decode("crop factor must be at least 1") }
        let a = area ?? Rect(x: 0, y: 0, width: W, height: H)
        guard a.x >= 0, a.y >= 0, a.width > 0, a.height > 0, a.x + a.width <= W, a.y + a.height <= H else {
            throw PipelineError.decode("visible area outside the sensor")
        }
        let cw = max(Int((Double(a.width) / cropFactor).rounded()) & ~1, 32)
        let ch = max(Int((Double(a.height) / cropFactor).rounded()) & ~1, 32)
        let x0 = (a.x + (a.width - cw) / 2) & ~1, y0 = (a.y + (a.height - ch) / 2) & ~1
        guard x0 >= 0, y0 >= 0, x0 + cw <= W, y0 + ch <= H else { throw PipelineError.decode("crop outside the sensor") }
        let s = outputScale ?? min(cropFactor, 2)
        guard s >= 1, s <= 4, s.isFinite else { throw PipelineError.decode("output scale must be within 1...4") }
        let wx0 = max(x0 - margin, 0) & ~1, wy0 = max(y0 - margin, 0) & ~1
        let wx1 = min(x0 + cw + margin, W), wy1 = min(y0 + ch + margin, H)
        let window = Rect(x: wx0, y: wy0, width: (wx1 - wx0) & ~1, height: (wy1 - wy0) & ~1)
        guard window.width >= 128, window.height >= 128 else { throw PipelineError.decode("crop too small for super-resolution") }
        return Plan(crop: Rect(x: x0, y: y0, width: cw, height: ch), window: window,
                    outWidth: Int((Double(cw) * s).rounded()), outHeight: Int((Double(ch) * s).rounded()))
    }

    static func window(_ c: RawCFA, _ r: Rect) -> RawCFA {
        var data = [UInt16](repeating: 0, count: r.width * r.height)
        c.data.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBufferPointer { dst in
                for y in 0..<r.height {
                    let s = (r.y + y) * c.width + r.x
                    UnsafeMutableRawPointer(dst.baseAddress! + y * r.width)
                        .copyMemory(from: src.baseAddress! + s, byteCount: r.width * 2)
                }
            }
        }
        var out = RawCFA(width: r.width, height: r.height, data: data, black: c.black, white: c.white)
        out.pattern = c.pattern; out.gains = c.gains; out.exposure = c.exposure
        return out
    }

    public static func reconstruct(_ frames: [BurstFrame], cropFactor: Double, outputScale: Double? = nil,
                                   noiseModel: (a: Float, b: Float)? = nil) throws -> SuperResolutionResult {
        try reconstruct(frames, cropFactor: cropFactor, outputScale: outputScale, area: nil,
                        noise: noiseModel.map { BurstMerger.Noise(a: $0.a, b: $0.b) }, options: Options())
    }

    static func reconstruct(_ frames: [BurstFrame], cropFactor: Double, outputScale: Double?, area: Rect?,
                            noise: BurstMerger.Noise? = nil, options: Options) throws -> SuperResolutionResult {
        guard let first = frames.first else { throw PipelineError.decode("no frames") }
        let plan = try self.plan(width: first.cfa.width, height: first.cfa.height, area: area, cropFactor: cropFactor,
                                 outputScale: outputScale, margin: options.margin)
        let windowed = frames.map { f -> BurstFrame? in
            guard f.cfa.width == first.cfa.width, f.cfa.height == first.cfa.height else { return nil }
            return BurstFrame(cfa: window(f.cfa, plan.window), scale: f.scale, blurPixels: f.blurPixels)
        }
        return try run(windowed, plan: plan, noiseModel: noise, options: options)
    }

    struct FrameState {
        var index: Int
        var data: [UInt16]
        var black: Float
        var fx: [Float], fy: [Float]
        var robust: [Float]?
    }

    static func run(_ frames: [BurstFrame?], plan: Plan, noiseModel: BurstMerger.Noise? = nil, options: Options,
                    steps: ProgressSteps? = nil) throws -> SuperResolutionResult {
        let start = Date()
        let eligible = frames.indices.filter { frames[$0]?.isSameExposure == true }
        guard !eligible.isEmpty else { throw PipelineError.decode("no same-exposure frame") }
        let refIndex: Int
        var sharpness: [Int: Float] = [:]
        if eligible.count == 1 {
            refIndex = eligible[0]
        } else if eligible.allSatisfy({ (frames[$0]!.blurPixels ?? -1) >= 0 }) {
            refIndex = eligible.min { frames[$0]!.blurPixels! < frames[$1]!.blurPixels! }!
        } else {
            for i in eligible { sharpness[i] = BurstMerger.sharpness(frames[i]!) }
            refIndex = eligible.max { sharpness[$0]! < sharpness[$1]! }!
        }
        let base = frames[refIndex]!
        let range = base.range, cap = range * 0.9
        let refPyramid = BurstMerger.pyramid(BurstMerger.luma(base, cap: cap))
        let refHalf = HalfRGB(base)
        var noise = BurstMerger.defaultNoise(range: range)
        var fitted = false
        if let given = noiseModel { noise = given; fitted = true } else if let n = estimateNoise(base, region: plan.crop.offset(-plan.window.x, -plan.window.y)) {
            noise = n; fitted = true
        }
        var maps: (kernels: [Float], alias: [Float])? = nil
        var cols = 1, rows = 1
        var states: [FrameState] = []
        var pending: [(Int, [Float], [Float], [Float]?)] = []
        for i in frames.indices where i != refIndex && frames[i] != nil && !eligible.contains(i) { steps?.step() }
        for i in eligible where i != refIndex {
            defer { steps?.step() }
            let alt = frames[i]!
            if let e0 = base.cfa.exposure, let e1 = alt.cfa.exposure, e0 > 0, abs(e1 / e0 - 1) > 0.03 { continue }
            let altPyramid = BurstMerger.pyramid(BurstMerger.luma(alt, cap: cap))
            var al = BurstMerger.align(ref: refPyramid, alt: altPyramid, scale: 1, noise: noise)
            if !fitted, let n = BurstMerger.fitNoise(base: base, alt: alt, alignment: al) { noise = n; fitted = true }
            if let s = sharpness[i], let s0 = sharpness[refIndex], s < 0.5 * s0 { continue }
            _ = BurstMerger.tileWeights(ref: refPyramid[0], alignment: &al, scale: 1, noise: noise, cap: cap)
            BurstMerger.fillOffsets(&al)
            cols = al.cols; rows = al.rows
            let (fx, fy) = refine(ref: refPyramid[0], alt: altPyramid[0], alignment: al, noise: noise)
            if maps == nil { maps = kernelMap(ref: refHalf, cfa: base.cfa, plan: plan, noise: noise, options: options) }
            let robust = options.robustness
                ? robustness(ref: refPyramid[0], alt: altPyramid[0], fx: fx, fy: fy, cols: cols, rows: rows, alias: maps!.alias,
                             plan: plan, noise: noise, options: options)
                : nil
            trace?(i, cols, fx, fy, robust)
            if let robust, robust.reduce(0, +) < 0.05 * Float(robust.count) { continue }
            pending.append((i, fx, fy, robust))
        }
        states.append(FrameState(index: refIndex, data: base.cfa.data, black: base.cfa.black,
                                 fx: [Float](repeating: 0, count: cols * rows), fy: [Float](repeating: 0, count: cols * rows), robust: nil))
        for (i, fx, fy, robust) in pending {
            states.append(FrameState(index: i, data: frames[i]!.cfa.data, black: frames[i]!.cfa.black, fx: fx, fy: fy, robust: robust))
        }
        let kernels = (maps ?? kernelMap(ref: refHalf, cfa: base.cfa, plan: plan, noise: noise, options: options)).kernels
        let accumulated: (rgb: [UInt16], coverage: Float)
        if let gpu = GPUAccumulator.shared,
           let r = try? accumulateGPU(gpu, states: states, cols: cols, rows: rows, plan: plan, pattern: base.cfa.pattern,
                                      windowWidth: base.cfa.width, windowHeight: base.cfa.height, range: range,
                                      kernels: kernels, options: options) {
            accumulated = r
        } else {
            accumulated = accumulate(states: states, cols: cols, rows: rows, plan: plan, pattern: base.cfa.pattern,
                                     windowWidth: base.cfa.width, windowHeight: base.cfa.height, range: range,
                                     kernels: kernels, options: options)
        }
        let (rgb, coverage) = accumulated
        steps?.step()
        return SuperResolutionResult(rgb: rgb, width: plan.outWidth, height: plan.outHeight, referenceIndex: refIndex,
                                     merged: states.count, coverage: coverage, crop: plan.crop,
                                     scaleX: Double(plan.sx), scaleY: Double(plan.sy), noiseModel: (noise.a, noise.b),
                                     seconds: Date().timeIntervalSince(start))
    }

    static func estimateNoise(_ f: BurstFrame, region: Rect) -> BurstMerger.Noise? {
        let W = f.cfa.width, range = f.range, black = f.cfa.black, pattern = f.cfa.pattern
        let B = 8
        let bx0 = max(region.x, 2) / B, by0 = max(region.y, 2) / B
        let bx1 = (min(region.x + region.width, W - 2)) / B, by1 = (min(region.y + region.height, f.cfa.height - 2)) / B
        guard bx1 > bx0, by1 > by0 else { return nil }
        let bins = 16
        let logRange = log(max(range, 2))
        var perBin = [[(Float, Float)]](repeating: [], count: bins)
        f.cfa.data.withUnsafeBufferPointer { d in
            for by in by0..<by1 { for bx in bx0..<bx1 {
                var sum: Float = 0, sum2: Float = 0, n: Float = 0, clipped = false
                for y in max(by * B, 1)..<min(by * B + B, f.cfa.height - 1) {
                    for x in max(bx * B, 1)..<min(bx * B + B, W - 1) where pattern[(y & 1) * 2 + (x & 1)] == 1 {
                        let v = Float(d[y * W + x]) - black
                        if v > range * 0.9 { clipped = true }
                        let nb = (Float(d[(y - 1) * W + x - 1]) + Float(d[(y - 1) * W + x + 1]) + Float(d[(y + 1) * W + x - 1])
                                  + Float(d[(y + 1) * W + x + 1])) * 0.25 - black
                        let r = v - nb
                        sum += v; sum2 += r * r; n += 1
                    }
                }
                guard !clipped, n >= 16 else { continue }
                let m = sum / n
                guard m >= 1 else { continue }
                let bin = Int(log(m) / logRange * Float(bins))
                guard bin >= 0, bin < bins else { continue }
                perBin[bin].append((m, sum2 / n / 1.25))
            } }
        }
        var S = 0.0, Sm = 0.0, Sv = 0.0, Smm = 0.0, Smv = 0.0, used = 0
        for blocks in perBin where blocks.count >= 20 {
            let sorted = blocks.sorted { $0.1 < $1.1 }
            let q = sorted[sorted.count / 10]
            let m = Double(q.0), v = Double(q.1) / 0.7, w = Double(blocks.count).squareRoot()
            S += w; Sm += w * m; Sv += w * v; Smm += w * m * m; Smv += w * m * v; used += 1
        }
        guard used >= 2 else { return nil }
        let det = S * Smm - Sm * Sm
        guard det > 0 else { return nil }
        var a = (S * Smv - Sv * Sm) / det, b = (Smm * Sv - Smv * Sm) / det
        if a < 0 { a = 0; b = Sv / S }
        let floor = Double((range / 4095) * (range / 4095))
        return BurstMerger.Noise(a: Float(max(a, 0)), b: Float(max(b, floor)))
    }

    struct HalfRGB {
        var width: Int, height: Int
        var r: [Float], g: [Float], b: [Float]

        init(_ f: BurstFrame) {
            let W = f.cfa.width
            width = W / 2; height = f.cfa.height / 2
            let w = W / 2, h = f.cfa.height / 2, n = w * h
            var r = [Float](repeating: 0, count: n), g = r, b = r
            let black = f.cfa.black, pattern = f.cfa.pattern
            f.cfa.data.withUnsafeBufferPointer { d in
                r.withUnsafeMutableBufferPointer { rp in g.withUnsafeMutableBufferPointer { gp in b.withUnsafeMutableBufferPointer { bp in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            var s: (Float, Float, Float) = (0, 0, 0)
                            for k in 0..<4 {
                                let v = Float(d[(2 * y + k / 2) * W + 2 * x + k % 2]) - black
                                switch pattern[k] { case 0: s.0 += v; case 1: s.1 += v * 0.5; default: s.2 += v }
                            }
                            rp[y * w + x] = s.0; gp[y * w + x] = s.1; bp[y * w + x] = s.2
                        }
                    }
                } } }
            }
            self.r = r; self.g = g; self.b = b
        }
    }

    static func refine(ref: BurstMerger.Plane, alt: BurstMerger.Plane, alignment al: BurstMerger.Alignment,
                       noise: BurstMerger.Noise) -> (fx: [Float], fy: [Float]) {
        let w = ref.width, h = ref.height
        let cols = al.cols, rows = al.rows, count = cols * rows
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        ref.v.withUnsafeBufferPointer { r in
            gx.withUnsafeMutableBufferPointer { px in gy.withUnsafeMutableBufferPointer { py in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    guard y > 0, y < h - 1 else { return }
                    for x in 1..<(w - 1) {
                        px[y * w + x] = 0.5 * (r[y * w + x + 1] - r[y * w + x - 1])
                        py[y * w + x] = 0.5 * (r[(y + 1) * w + x] - r[(y - 1) * w + x])
                    }
                }
            } }
        }
        func bounds(_ t: Int) -> (Int, Int, Int, Int) {
            let tx = t % cols, ty = t / cols
            return (max(tx * 16 - 4, 1), min(tx * 16 + 20, w - 1), max(ty * 16 - 4, 1), min(ty * 16 + 20, h - 1))
        }
        func residual(_ r: UnsafeBufferPointer<Float>, _ a: UnsafeBufferPointer<Float>, _ t: Int, _ dx: Float, _ dy: Float) -> Float {
            let (x0, x1, y0, y1) = bounds(t)
            var s: Float = 0, n: Float = 0
            for y in y0..<y1 {
                let sy = Float(y) + dy
                guard sy >= 0, sy < Float(h - 1) else { continue }
                let iy = Int(sy), v = sy - Float(iy)
                for x in x0..<x1 {
                    let sx = Float(x) + dx
                    guard sx >= 0, sx < Float(w - 1) else { continue }
                    let ix = Int(sx), u = sx - Float(ix), j = iy * w + ix
                    let top = a[j] + (a[j + 1] - a[j]) * u, bottom = a[j + w] + (a[j + w + 1] - a[j + w]) * u
                    let e = top + (bottom - top) * v - r[y * w + x]
                    s += e * e; n += 1
                }
            }
            return n > 0 ? s / n : .infinity
        }
        var fx = [Float](repeating: 0, count: count), fy = fx
        var confidence = [Float](repeating: 0, count: count), own = [Float](repeating: .infinity, count: count)
        var sigma2 = [Float](repeating: 0, count: count)
        ref.v.withUnsafeBufferPointer { r in alt.v.withUnsafeBufferPointer { a in
        gx.withUnsafeBufferPointer { px in gy.withUnsafeBufferPointer { py in
        fx.withUnsafeMutableBufferPointer { ox in fy.withUnsafeMutableBufferPointer { oy in
        confidence.withUnsafeMutableBufferPointer { cp in own.withUnsafeMutableBufferPointer { op in sigma2.withUnsafeMutableBufferPointer { sp in
            DispatchQueue.concurrentPerform(iterations: count) { t in
                let o = al.offsets[t]
                let (x0, x1, y0, y1) = bounds(t)
                ox[t] = Float(o.dx); oy[t] = Float(o.dy)
                guard x1 > x0 + 4, y1 > y0 + 4 else { return }
                var axx: Float = 0, axy: Float = 0, ayy: Float = 0, sum: Float = 0
                for y in y0..<y1 { for x in x0..<x1 {
                    let i = y * w + x
                    axx += px[i] * px[i]; axy += px[i] * py[i]; ayy += py[i] * py[i]; sum += r[i]
                } }
                let n = Float((x1 - x0) * (y1 - y0))
                let lumaVar = (noise.a * max(sum / n, 0) + noise.b) / 4
                sp[t] = lumaVar
                let lambda = n * lumaVar * 0.5
                let half = 0.5 * (axx + ayy), root = (0.25 * (axx - ayy) * (axx - ayy) + axy * axy).squareRoot()
                cp[t] = max(half - root, 0) / max(lambda, 1e-6)
                let bxx = axx + lambda, byy = ayy + lambda
                let det = bxx * byy - axy * axy
                guard det > 0 else { return }
                var dx = Float(o.dx), dy = Float(o.dy)
                for _ in 0..<6 {
                    var bx: Float = 0, by: Float = 0
                    for y in y0..<y1 {
                        let sy = Float(y) + dy
                        guard sy >= 0, sy < Float(h - 1) else { continue }
                        let iy = Int(sy), fy = sy - Float(iy)
                        for x in x0..<x1 {
                            let sx = Float(x) + dx
                            guard sx >= 0, sx < Float(w - 1) else { continue }
                            let ix = Int(sx), fxv = sx - Float(ix)
                            let j = iy * w + ix
                            let top = a[j] + (a[j + 1] - a[j]) * fxv
                            let bottom = a[j + w] + (a[j + w + 1] - a[j + w]) * fxv
                            let e = top + (bottom - top) * fy - r[y * w + x]
                            bx += px[y * w + x] * e; by += py[y * w + x] * e
                        }
                    }
                    var ddx = -(byy * bx - axy * by) / det, ddy = -(bxx * by - axy * bx) / det
                    ddx = min(max(ddx, -1), 1); ddy = min(max(ddy, -1), 1)
                    dx += ddx; dy += ddy
                    if abs(ddx) < 0.005, abs(ddy) < 0.005 { break }
                }
                if abs(dx - Float(o.dx)) <= 1.5, abs(dy - Float(o.dy)) <= 1.5, dx.isFinite, dy.isFinite { ox[t] = dx; oy[t] = dy }
                op[t] = residual(r, a, t, ox[t], oy[t])
            }
        } } } } } } } } }

        func centre(_ t: Int) -> (Float, Float) {
            (Float(t % cols * 16 + 8) / Float(max(w, 1)) - 0.5, Float(t / cols * 16 + 8) / Float(max(h, 1)) - 0.5)
        }
        var weights = confidence.map { $0 > 4 ? Float(1) : 0 }
        guard weights.filter({ $0 > 0 }).count >= 6 else { return (fx, fy) }
        var cx: [Float] = [0, 0, 0], cy: [Float] = [0, 0, 0]
        for _ in 0..<6 {
            var m = [Double](repeating: 0, count: 9), bx = [Double](repeating: 0, count: 3), by = bx
            for t in 0..<count where weights[t] > 0 {
                let (x, y) = centre(t)
                let v: [Double] = [1, Double(x), Double(y)], wt = Double(weights[t])
                for i in 0..<3 {
                    for j in 0..<3 { m[i * 3 + j] += wt * v[i] * v[j] }
                    bx[i] += wt * v[i] * Double(fx[t]); by[i] += wt * v[i] * Double(fy[t])
                }
            }
            guard let sx = solve3(m, bx), let sy = solve3(m, by) else { return (fx, fy) }
            cx = sx.map(Float.init); cy = sy.map(Float.init)
            for t in 0..<count where confidence[t] > 4 {
                let (x, y) = centre(t)
                let ex = fx[t] - (cx[0] + cx[1] * x + cx[2] * y), ey = fy[t] - (cy[0] + cy[1] * x + cy[2] * y)
                let u = (ex * ex + ey * ey) / (0.75 * 0.75)
                weights[t] = u < 1 ? (1 - u) * (1 - u) : 0
            }
        }
        let ownFx = fx, ownFy = fy
        ref.v.withUnsafeBufferPointer { r in alt.v.withUnsafeBufferPointer { a in
        fx.withUnsafeMutableBufferPointer { ox in fy.withUnsafeMutableBufferPointer { oy in
            DispatchQueue.concurrentPerform(iterations: count) { t in
                let (x, y) = centre(t)
                let mx = cx[0] + cx[1] * x + cx[2] * y, my = cy[0] + cy[1] * x + cy[2] * y
                guard abs(mx - ownFx[t]) > 0.02 || abs(my - ownFy[t]) > 0.02 else { return }
                let atModel = residual(r, a, t, mx, my)
                if atModel <= 4 * own[t] + 4 * sigma2[t] { ox[t] = mx; oy[t] = my }
            }
        } } } }
        return (fx, fy)
    }

    static func solve3(_ m: [Double], _ b: [Double]) -> [Double]? {
        func det(_ a: [Double]) -> Double {
            a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        return (0..<3).map { k in
            var a = m
            for i in 0..<3 { a[i * 3 + k] = b[i] }
            return det(a) / d
        }
    }

    @inline(__always)
    static func tileLerp(_ p: Float, _ n: Int) -> (Int, Int, Float) {
        let u = min(max((p - 15.5) / 32, 0), Float(n - 1))
        let t0 = Int(u)
        return (t0, min(t0 + 1, n - 1), u - Float(t0))
    }

    static func robustness(ref: BurstMerger.Plane, alt: BurstMerger.Plane, fx: [Float], fy: [Float], cols: Int, rows: Int,
                           alias: [Float], plan: Plan, noise: BurstMerger.Noise, options: Options) -> [Float] {
        let hw = ref.width, hh = ref.height
        let cbx = plan.cx / 2, cby = plan.cy / 2, cbw = plan.crop.width / 2, cbh = plan.crop.height / 2
        let ex0 = max(cbx - 3, 0), ey0 = max(cby - 3, 0)
        let ex1 = min(cbx + cbw + 3, hw), ey1 = min(cby + cbh + 3, hh)
        let ew = ex1 - ex0, eh = ey1 - ey0
        var warped = [Float](repeating: .nan, count: ew * eh)
        warped.withUnsafeMutableBufferPointer { wp in alt.v.withUnsafeBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: eh) { j in
                let by = ey0 + j
                let (ty0, ty1, wy) = tileLerp(Float(2 * by) + 0.5, rows)
                for i in 0..<ew {
                    let bx = ex0 + i
                    let (tx0, tx1, wx) = tileLerp(Float(2 * bx) + 0.5, cols)
                    let dx = (fx[ty0 * cols + tx0] * (1 - wx) + fx[ty0 * cols + tx1] * wx) * (1 - wy)
                        + (fx[ty1 * cols + tx0] * (1 - wx) + fx[ty1 * cols + tx1] * wx) * wy
                    let dy = (fy[ty0 * cols + tx0] * (1 - wx) + fy[ty0 * cols + tx1] * wx) * (1 - wy)
                        + (fy[ty1 * cols + tx0] * (1 - wx) + fy[ty1 * cols + tx1] * wx) * wy
                    let sx = Float(bx) + dx, sy = Float(by) + dy
                    guard sx >= 0, sy >= 0, sx < Float(hw - 1), sy < Float(hh - 1) else { continue }
                    let ix = Int(sx), iy = Int(sy), u = sx - Float(ix), v = sy - Float(iy)
                    let k = iy * hw + ix
                    let top = p[k] + (p[k + 1] - p[k]) * u, bottom = p[k + hw] + (p[k + hw + 1] - p[k + hw]) * u
                    wp[j * ew + i] = top + (bottom - top) * v
                }
            }
        } }
        var raw = [Float](repeating: 0, count: ew * eh)
        let s = options.robustScale, t = options.robustThreshold, kStd = options.localStdWeight
        raw.withUnsafeMutableBufferPointer { rp in warped.withUnsafeBufferPointer { wp in ref.v.withUnsafeBufferPointer { rv in
            DispatchQueue.concurrentPerform(iterations: eh) { j in
                guard j > 0, j < eh - 1 else { return }
                for i in 1..<(ew - 1) {
                    var sa: Float = 0, sr: Float = 0
                    for dj in -1...1 { for di in -1...1 {
                        sa += wp[(j + dj) * ew + i + di]; sr += rv[(ey0 + j + dj) * hw + ex0 + i + di]
                    } }
                    guard !sa.isNaN else { continue }
                    var s1: Float = 0, s2: Float = 0, n: Float = 0
                    for y in max(ey0 + j - 2, 0)...min(ey0 + j + 2, hh - 1) { for x in max(ex0 + i - 2, 0)...min(ex0 + i + 2, hw - 1) {
                        let r = rv[y * hw + x]; s1 += r; s2 += r * r; n += 1
                    } }
                    let mr = sr / 9, ma = sa / 9
                    let localVar = max(s2 / n - (s1 / n) * (s1 / n), 0)
                    let sigmaMD2 = 2 * (noise.a * max(mr, 0) + noise.b) / 4 / 9
                    let d = abs(ma - mr)
                    let dShrunk = d * d * d / (d * d + sigmaMD2)
                    let ax = min(max(ex0 + i - cbx, 0), cbw - 1), ay = min(max(ey0 + j - cby, 0), cbh - 1)
                    let sigma2 = max(sigmaMD2, kStd * kStd * localVar) + alias[ay * cbw + ax]
                    rp[j * ew + i] = min(max(s * expf(-dShrunk * dShrunk / sigma2) - t, 0), 1)
                }
            }
        } } }
        var out = [Float](repeating: 0, count: cbw * cbh)
        out.withUnsafeMutableBufferPointer { op in raw.withUnsafeBufferPointer { rp in
            DispatchQueue.concurrentPerform(iterations: cbh) { j in
                let ey = cby + j - ey0
                for i in 0..<cbw {
                    let ex = cbx + i - ex0
                    var m: Float = 1
                    for dj in -2...2 {
                        let y = min(max(ey + dj, 1), eh - 2)
                        for di in -2...2 { m = min(m, rp[y * ew + min(max(ex + di, 1), ew - 2)]) }
                    }
                    op[j * cbw + i] = m
                }
            }
        } }
        return out
    }

    static func kernelMap(ref: HalfRGB, cfa: RawCFA, plan: Plan, noise: BurstMerger.Noise, options: Options) -> (kernels: [Float], alias: [Float]) {
        let hw = ref.width, hh = ref.height, W = cfa.width, H = cfa.height
        let cbx = plan.cx / 2, cby = plan.cy / 2, cbw = plan.crop.width / 2, cbh = plan.crop.height / 2
        let g = cfa.gains.count == 3 && cfa.gains.allSatisfy({ $0 > 0 }) ? cfa.gains : [1, 1, 1]
        let gn = g.map { $0 / g[1] }
        let pattern = cfa.pattern, black = cfa.black
        let guideVarFactor = (gn[pattern[0]] * gn[pattern[0]] + gn[pattern[1]] * gn[pattern[1]]
                              + gn[pattern[2]] * gn[pattern[2]] + gn[pattern[3]] * gn[pattern[3]]) / 4
        let bx0 = max(cbx - 2, 0), by0 = max(cby - 2, 0), bx1 = min(cbx + cbw + 2, hw), by1 = min(cby + cbh + 2, hh)
        let gx0 = 2 * bx0 - 1, gy0 = 2 * by0 - 1, gw = 2 * (bx1 - bx0) + 3, gh = 2 * (by1 - by0) + 3
        var guide = [Float](repeating: 0, count: gw * gh)
        guide.withUnsafeMutableBufferPointer { gp in
            cfa.data.withUnsafeBufferPointer { d in
                ref.r.withUnsafeBufferPointer { rr in ref.g.withUnsafeBufferPointer { rg in ref.b.withUnsafeBufferPointer { rb in
                    let planes = [rr, rg, rb]
                    DispatchQueue.concurrentPerform(iterations: gh) { j in
                        let y = min(max(gy0 + j, 0), H - 1)
                        let v = min(max((Float(y) - 0.5) / 2, 0), Float(hh - 1))
                        let iy = min(Int(v), hh - 2), fv = v - Float(iy)
                        for i in 0..<gw {
                            let x = min(max(gx0 + i, 0), W - 1)
                            let u = min(max((Float(x) - 0.5) / 2, 0), Float(hw - 1))
                            let ix = min(Int(u), hw - 2), fu = u - Float(ix)
                            let k = iy * hw + ix
                            func lerp(_ p: UnsafeBufferPointer<Float>) -> Float {
                                let top = p[k] + (p[k + 1] - p[k]) * fu, bottom = p[k + hw] + (p[k + hw + 1] - p[k + hw]) * fu
                                return top + (bottom - top) * fv
                            }
                            let c = pattern[(y & 1) * 2 + (x & 1)]
                            let luma = (gn[0] * lerp(rr) + gn[1] * lerp(rg) + gn[2] * lerp(rb)) / 3
                            gp[j * gw + i] = luma + gn[c] * (Float(d[y * W + x]) - black - lerp(planes[c]))
                        }
                    }
                } } }
            }
        }
        let ew = bx1 - bx0, eh = by1 - by0
        var tensor = [Float](repeating: 0, count: ew * eh * 5)
        tensor.withUnsafeMutableBufferPointer { tp in guide.withUnsafeBufferPointer { gp in
            DispatchQueue.concurrentPerform(iterations: eh) { j in
                for i in 0..<ew {
                    var a: Float = 0, b: Float = 0, c: Float = 0, m: Float = 0, hf: Float = 0
                    for y in (2 * j)..<(2 * j + 4) { for x in (2 * i)..<(2 * i + 4) {
                        let p = gp[y * gw + x]
                        let ix = gp[y * gw + x + 1] - p, iy = gp[(y + 1) * gw + x] - p
                        a += ix * ix; b += ix * iy; c += iy * iy; m += p
                        var local: Float = 0
                        for yy in max(y - 1, 0)...min(y + 1, gh - 1) { for xx in max(x - 1, 0)...min(x + 1, gw - 1) { local += gp[yy * gw + xx] } }
                        let e = p - local / Float((min(y + 1, gh - 1) - max(y - 1, 0) + 1) * (min(x + 1, gw - 1) - max(x - 1, 0) + 1))
                        hf += e * e
                    } }
                    let o = (j * ew + i) * 5
                    tp[o] = a / 16; tp[o + 1] = b / 16; tp[o + 2] = c / 16; tp[o + 3] = m / 16; tp[o + 4] = hf / 16
                }
            }
        } }
        var out = [Float](repeating: 0, count: cbw * cbh * 3)
        var alias = [Float](repeating: 0, count: cbw * cbh)
        let kd = options.kDetail
        let toLuma = (1 / gn[0] + 2 + 1 / gn[2]) / 4
        let aliasK2 = options.aliasWeight * options.aliasWeight * toLuma * toLuma
        alias.withUnsafeMutableBufferPointer { al in
        out.withUnsafeMutableBufferPointer { op in tensor.withUnsafeBufferPointer { tp in
            DispatchQueue.concurrentPerform(iterations: cbh) { j in
                let ey = cby + j - by0
                for i in 0..<cbw {
                    let ex = cbx + i - bx0
                    var a: Float = 0, b: Float = 0, c: Float = 0, m: Float = 0, hf: Float = 0, wsum: Float = 0
                    for dj in -1...1 { for di in -1...1 {
                        let y = min(max(ey + dj, 0), eh - 1), x = min(max(ex + di, 0), ew - 1)
                        let w: Float = (dj == 0 ? 2 : 1) * (di == 0 ? 2 : 1)
                        let o = (y * ew + x) * 5
                        a += w * tp[o]; b += w * tp[o + 1]; c += w * tp[o + 2]; m += w * tp[o + 3]; hf += w * tp[o + 4]; wsum += w
                    } }
                    a /= wsum; b /= wsum; c /= wsum; m /= wsum; hf /= wsum
                    let guideVar = (noise.a * max(m, 0) + noise.b) * guideVarFactor
                    al[j * cbw + i] = aliasK2 * max(hf - guideVar * 10 / 9, 0)
                    let half = 0.5 * (a + c), root = (0.25 * (a - c) * (a - c) + b * b).squareRoot()
                    let l1 = half + root, l2 = max(half - root, 0)
                    let guideSigma = (2 * guideVar).squareRoot()
                    let strength = l1.squareRoot() / max(guideSigma, 1e-6)
                    let D = min(max((options.edgeHigh - strength) / (options.edgeHigh - options.edgeLow), 0), 1)
                    let aniso = options.anisotropic && l1 + l2 > 0 ? ((l1 - l2) / (l1 + l2)).squareRoot() : 0
                    let along = (1 - D) * kd * (1 + (options.kStretch - 1) * aniso) + D * kd * options.kDenoise
                    let across = (1 - D) * kd / (1 + (options.kShrink - 1) * aniso) + D * kd * options.kDenoise
                    let theta = 0.5 * atan2(2 * b, a - c)
                    let cs = cosf(theta), sn = sinf(theta)
                    let ia = 1 / (across * across), il = 1 / (along * along)
                    let o = (j * cbw + i) * 3
                    op[o] = cs * cs * ia + sn * sn * il
                    op[o + 1] = cs * sn * (ia - il)
                    op[o + 2] = sn * sn * ia + cs * cs * il
                }
            }
        } }
        }
        return (out, alias)
    }

    static let kernelTable: [Float] = (0...(9 * 64 + 1)).map { expf(-0.5 * Float($0) / 64) }

    static func accumulate(states: [FrameState], cols: Int, rows: Int, plan: Plan, pattern: [Int], windowWidth ww: Int,
                           windowHeight wh: Int, range: Float, kernels: [Float], options: Options) -> (rgb: [UInt16], coverage: Float) {
        let OW = plan.outWidth, OH = plan.outHeight
        let sx = plan.sx, sy = plan.sy
        let cx = Float(plan.cx), cy = Float(plan.cy)
        let cbx = plan.cx / 2, cby = plan.cy / 2, cbw = plan.crop.width / 2, cbh = plan.crop.height / 2
        let px = (0..<OW).map { cx + (Float($0) + 0.5) / sx - 0.5 }
        let py = (0..<OH).map { cy + (Float($0) + 0.5) / sy - 0.5 }
        let bxs = px.map { min(max(Int(floor(($0 + 0.5) / 2)) - cbx, 0), cbw - 1) }
        let bys = py.map { min(max(Int(floor(($0 + 0.5) / 2)) - cby, 0), cbh - 1) }
        let colLerp = px.map { tileLerp($0, cols) }
        let rowLerp = py.map { tileLerp($0, rows) }
        let band = 16
        let bands = (OH + band - 1) / band
        var rgb = [UInt16](repeating: 0, count: OW * OH * 3)
        var covered = [Int](repeating: 0, count: bands)
        let table = kernelTable
        let minW = options.minWeight
        let scaleOut = 65535 / range
        let pat = pattern
        let refData = states[0].data, refBlack = states[0].black
        rgb.withUnsafeMutableBufferPointer { out in covered.withUnsafeMutableBufferPointer { cov in
        kernels.withUnsafeBufferPointer { kp in table.withUnsafeBufferPointer { tb in
            DispatchQueue.concurrentPerform(iterations: bands) { bandIndex in
                let j0 = bandIndex * band, j1 = min(j0 + band, OH)
                var acc = [Float](repeating: 0, count: (j1 - j0) * OW * 6)
                acc.withUnsafeMutableBufferPointer { ap in
                    for st in states {
                        st.data.withUnsafeBufferPointer { d in st.fx.withUnsafeBufferPointer { fxp in st.fy.withUnsafeBufferPointer { fyp in
                            let black = st.black
                            let robust = st.robust
                            for j in j0..<j1 {
                                let (ty0, ty1, wy) = rowLerp[j]
                                let pyj = py[j], by = bys[j]
                                for i in 0..<OW {
                                    let k = by * cbw + bxs[i]
                                    var r: Float = 1
                                    if let robust { r = robust[k]; if r < 0.01 { continue } }
                                    let (tx0, tx1, wx) = colLerp[i]
                                    let a00 = ty0 * cols + tx0, a01 = ty0 * cols + tx1, a10 = ty1 * cols + tx0, a11 = ty1 * cols + tx1
                                    let ox = (fxp[a00] * (1 - wx) + fxp[a01] * wx) * (1 - wy) + (fxp[a10] * (1 - wx) + fxp[a11] * wx) * wy
                                    let oy = (fyp[a00] * (1 - wx) + fyp[a01] * wx) * (1 - wy) + (fyp[a10] * (1 - wx) + fyp[a11] * wx) * wy
                                    let Px = px[i] + 2 * ox, Py = pyj + 2 * oy
                                    let xc = Int((Px + 0.5).rounded(.down)), yc = Int((Py + 0.5).rounded(.down))
                                    guard xc >= 1, yc >= 1, xc < ww - 1, yc < wh - 1 else { continue }
                                    let ka = kp[k * 3], kb = kp[k * 3 + 1], kc = kp[k * 3 + 2]
                                    let o = ((j - j0) * OW + i) * 6
                                    let ddx = Float(xc) - Px, ddy = Float(yc) - Py
                                    for ky in -1...1 {
                                        let dy = ddy + Float(ky)
                                        let row = (yc + ky) * ww
                                        let prow = ((yc + ky) & 1) * 2
                                        for kx in -1...1 {
                                            let dx = ddx + Float(kx)
                                            let q = (ka * dx * dx + 2 * kb * dx * dy + kc * dy * dy) * 64
                                            guard q < 9 * 64 else { continue }
                                            let qi = Int(q), qf = q - Float(qi)
                                            let w = (tb[qi] + (tb[qi + 1] - tb[qi]) * qf) * r
                                            let c = pat[prow + ((xc + kx) & 1)]
                                            ap[o + c] += w
                                            ap[o + 3 + c] += w * (Float(d[row + xc + kx]) - black)
                                        }
                                    }
                                }
                            }
                        } } }
                    }
                    var n = 0
                    refData.withUnsafeBufferPointer { rd in
                        for j in j0..<j1 {
                            for i in 0..<OW {
                                let o = ((j - j0) * OW + i) * 6
                                var fallback: (Float, Float, Float)? = nil
                                var full = true
                                for c in 0..<3 {
                                    let w = ap[o + c]
                                    var v: Float
                                    if w >= minW {
                                        v = ap[o + 3 + c] / w
                                    } else {
                                        full = false
                                        if fallback == nil { fallback = demosaicAt(rd, ww, wh, refBlack, pat, px[i], py[j]) }
                                        let f = c == 0 ? fallback!.0 : c == 1 ? fallback!.1 : fallback!.2
                                        let alpha = w / minW
                                        v = w > 0 ? alpha * (ap[o + 3 + c] / w) + (1 - alpha) * f : f
                                    }
                                    out[(j * OW + i) * 3 + c] = UInt16(min(max(v * scaleOut + 0.5, 0), 65535))
                                }
                                if full { n += 1 }
                            }
                        }
                    }
                    cov[bandIndex] = n
                }
            }
        } } } }
        return (rgb, Float(covered.reduce(0, +)) / Float(max(OW * OH, 1)))
    }

    @inline(__always)
    static func demosaicAt(_ d: UnsafeBufferPointer<UInt16>, _ W: Int, _ H: Int, _ black: Float, _ pattern: [Int],
                           _ x: Float, _ y: Float) -> (Float, Float, Float) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        var s: [Float] = [0, 0, 0], w: [Float] = [0, 0, 0]
        for yy in (y0 - 1)...(y0 + 2) {
            let wy = max(0, 1 - abs(Float(yy) - y) / 2)
            guard wy > 0 else { continue }
            let cy = min(max(yy, 0), H - 1)
            for xx in (x0 - 1)...(x0 + 2) {
                let wx = max(0, 1 - abs(Float(xx) - x) / 2)
                guard wx > 0 else { continue }
                let cx = min(max(xx, 0), W - 1)
                let c = pattern[(yy & 1) * 2 + (xx & 1)]
                s[c] += wx * wy * (Float(d[cy * W + cx]) - black); w[c] += wx * wy
            }
        }
        return (w[0] > 0 ? s[0] / w[0] : 0, w[1] > 0 ? s[1] / w[1] : 0, w[2] > 0 ? s[2] / w[2] : 0)
    }
}

public struct SuperResolutionResult: Sendable {
    public var rgb: [UInt16]
    public var width: Int, height: Int
    public var referenceIndex: Int
    public var merged: Int
    public var coverage: Float
    public var crop: SuperResolution.Rect
    public var scaleX: Double, scaleY: Double
    public var noiseModel: (a: Float, b: Float)
    public var seconds: Double
}
