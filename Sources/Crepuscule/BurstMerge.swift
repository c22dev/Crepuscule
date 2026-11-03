// Crepuscule - BurstMerge.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public struct BurstFrame: Sendable {
    public var cfa: RawCFA
    public var scale: Float
    public var blurPixels: Float?
    public init(cfa: RawCFA, scale: Float, blurPixels: Float? = nil) { self.cfa = cfa; self.scale = scale; self.blurPixels = blurPixels }
    var isSameExposure: Bool { abs(scale - 1) < 0.001 }
    var range: Float { max(cfa.white - cfa.black, 1) }
}

public struct BurstMergeResult: Sendable {
    public var cfa: [UInt16]
    public var width: Int, height: Int
    public var referenceIndex: Int
    public var headroomStops: Float
    public var merged: Int, shorts: Int
    public var noiseModel: (a: Float, b: Float)

    public func marker(exposureBiasStops: Float = 0) -> String {
        String(format: BurstMerger.markerPrefix + "v=1;frames=%d;shorts=%d;headroom=%.3f;bias=%.3f;alg=%d",
               merged, shorts, headroomStops, exposureBiasStops, BurstMerger.algorithmVersion)
    }
}

public enum BurstMerger {
    public static let algorithmVersion = 3
    public static let markerPrefix = "crepuscule-merge;"
    static let legacyMarkerPrefix = "yCam-burst-merge;"

    struct Plane {
        var width: Int, height: Int
        var v: [Float]
        subscript(x: Int, y: Int) -> Float { v[y * width + x] }
    }

    static func luma(_ f: BurstFrame, cap: Float) -> Plane {
        let w = f.cfa.width / 2, h = f.cfa.height / 2
        var out = [Float](repeating: 0, count: w * h)
        let k = f.scale * 0.25, b4 = 4 * f.cfa.black
        f.cfa.data.withUnsafeBufferPointer { d in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let r0 = 2 * y * f.cfa.width, r1 = r0 + f.cfa.width
                    for x in 0..<w {
                        let s = Float(d[r0 + 2 * x]) + Float(d[r0 + 2 * x + 1]) + Float(d[r1 + 2 * x]) + Float(d[r1 + 2 * x + 1])
                        var v = (s - b4) * k
                        if cap > 0, v > cap { v = cap }
                        o[y * w + x] = v
                    }
                }
            }
        }
        return Plane(width: w, height: h, v: out)
    }

    static func pyramid(_ base: Plane) -> [Plane] {
        var levels = [base]
        for _ in 1..<4 {
            let p = levels.last!
            let w = max(p.width / 2, 1), h = max(p.height / 2, 1)
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                let ya = min(2 * y, p.height - 1), yb = min(2 * y + 1, p.height - 1)
                for x in 0..<w {
                    let xa = min(2 * x, p.width - 1), xb = min(2 * x + 1, p.width - 1)
                    out[y * w + x] = (p[xa, ya] + p[xb, ya] + p[xa, yb] + p[xb, yb]) * 0.25
                }
            }
            levels.append(Plane(width: w, height: h, v: out))
        }
        return levels
    }

    static func distance(_ ref: Plane, _ alt: Plane, _ tx: Int, _ ty: Int, _ dx: Int, _ dy: Int) -> Float {
        let x0 = tx * 16, y0 = ty * 16
        let x1 = min(x0 + 16, ref.width), y1 = min(y0 + 16, ref.height)
        guard x1 > x0, y1 > y0 else { return 1e30 }
        var sum: Float = 0
        let inside = x0 + dx >= 0 && x1 - 1 + dx < alt.width && y0 + dy >= 0 && y1 - 1 + dy < alt.height
        ref.v.withUnsafeBufferPointer { r in
            alt.v.withUnsafeBufferPointer { a in
                for y in y0..<y1 {
                    let ay = inside ? y + dy : min(max(y + dy, 0), alt.height - 1)
                    let rr = y * ref.width, ar = ay * alt.width
                    for x in x0..<x1 {
                        let ax = inside ? x + dx : min(max(x + dx, 0), alt.width - 1)
                        sum += abs(r[rr + x] - a[ar + ax])
                    }
                }
            }
        }
        return sum / Float((x1 - x0) * (y1 - y0))
    }

    struct Noise { var a: Float, b: Float }

    static func defaultNoise(range: Float) -> Noise {
        let u = range / 4095
        return Noise(a: u * 0.8, b: u * u * 4)
    }

    static func alignable(_ ref: Plane, _ tx: Int, _ ty: Int, level: Int, scale: Float, noise: Noise) -> Bool {
        let x0 = tx * 16, y0 = ty * 16
        let x1 = min(x0 + 16, ref.width), y1 = min(y0 + 16, ref.height)
        guard x1 > x0, y1 > y0 else { return false }
        var sum: Float = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += ref[x, y] } }
        let n = Float((x1 - x0) * (y1 - y0))
        let mean = sum / n
        var mad: Float = 0
        for y in y0..<y1 { for x in x0..<x1 { mad += abs(ref[x, y] - mean) } }
        mad /= n
        let m = max(mean, 0)
        var v = noise.b + m * noise.a
        if scale > 1 { v += scale * scale * noise.b + m * scale * noise.a }
        return sqrt(max(v, 1e-6)) / Float(2 << level) * 1.2 < mad
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    struct Alignment {
        var cols: Int, rows: Int
        var offsets: [(dx: Int, dy: Int)]
        var distance: [Float]
        var alignable: [Bool]
    }

    static func align(ref: [Plane], alt: [Plane], scale: Float, noise: Noise) -> Alignment {
        func grid(_ p: Plane) -> (Int, Int) { ((p.width + 15) / 16, (p.height + 15) / 16) }
        var (cols, rows) = grid(ref[3])
        var offsets = [(dx: Int, dy: Int)](repeating: (0, 0), count: cols * rows)
        var found = [Bool](repeating: false, count: cols * rows)
        let coarseCols = cols
        offsets.withUnsafeMutableBufferPointer { op in found.withUnsafeMutableBufferPointer { fp in
            DispatchQueue.concurrentPerform(iterations: rows) { ty in
                for tx in 0..<coarseCols where alignable(ref[3], tx, ty, level: 3, scale: scale, noise: noise) {
                    var best = distance(ref[3], alt[3], tx, ty, 0, 0), bx = 0, by = 0
                    for dy in -10...10 { for dx in -10...10 where dx != 0 || dy != 0 {
                        let d = distance(ref[3], alt[3], tx, ty, dx, dy)
                        if d < best { best = d; bx = dx; by = dy }
                    } }
                    op[ty * coarseCols + tx] = (bx, by)
                    fp[ty * coarseCols + tx] = true
                }
            }
        } }
        let mx = median(offsets.indices.filter { found[$0] }.map { offsets[$0].dx })
        let my = median(offsets.indices.filter { found[$0] }.map { offsets[$0].dy })
        for i in offsets.indices where !found[i] { offsets[i] = (mx, my) }

        var distances = [Float](repeating: 1e30, count: 0)
        var alignableTiles = [Bool]()
        for level in stride(from: 2, through: 0, by: -1) {
            let parent = offsets, pcols = cols, prows = rows
            (cols, rows) = grid(ref[level])
            var next = [(dx: Int, dy: Int)](repeating: (0, 0), count: cols * rows)
            var dist = [Float](repeating: 1e30, count: cols * rows)
            var ok = [Bool](repeating: false, count: cols * rows)
            let radius = level == 0 ? 1 : 2
            let lc = cols
            next.withUnsafeMutableBufferPointer { np in dist.withUnsafeMutableBufferPointer { dp in ok.withUnsafeMutableBufferPointer { kp in
            DispatchQueue.concurrentPerform(iterations: rows) { ty in
                let py = min(ty >> 1, prows - 1)
                let ny = min(max(py + ((ty & 1) != 0 ? 1 : -1), 0), prows - 1)
                for tx in 0..<lc {
                    let px = min(tx >> 1, pcols - 1)
                    let nx = min(max(px + ((tx & 1) != 0 ? 1 : -1), 0), pcols - 1)
                    let up = parent[py * pcols + px]
                    var best = (dx: up.dx * 2, dy: up.dy * 2)
                    var bestD: Float
                    let isOK = alignable(ref[level], tx, ty, level: level, scale: scale, noise: noise)
                    if !isOK {
                        bestD = level == 0 ? distance(ref[0], alt[0], tx, ty, best.dx, best.dy) : 1e30
                    } else {
                        bestD = distance(ref[level], alt[level], tx, ty, best.dx, best.dy)
                        if bestD >= 1e30 || bestD.isNaN { best = (0, 0) }
                        bestD = min(bestD, 1e30)
                        for c in [parent[py * pcols + nx], parent[ny * pcols + px]] {
                            let d = distance(ref[level], alt[level], tx, ty, c.dx * 2, c.dy * 2)
                            if d < bestD { bestD = d; best = (c.dx * 2, c.dy * 2) }
                        }
                        let center = best
                        bestD = distance(ref[level], alt[level], tx, ty, center.dx, center.dy)
                        for dy in -radius...radius { for dx in -radius...radius where dx != 0 || dy != 0 {
                            let d = distance(ref[level], alt[level], tx, ty, center.dx + dx, center.dy + dy)
                            if d < bestD { bestD = d; best = (center.dx + dx, center.dy + dy) }
                        } }
                        if level == 0 {
                            let d0 = bestD
                            let xm = distance(ref[0], alt[0], tx, ty, best.dx - 1, best.dy), xp = distance(ref[0], alt[0], tx, ty, best.dx + 1, best.dy)
                            let ym = distance(ref[0], alt[0], tx, ty, best.dx, best.dy - 1), yp = distance(ref[0], alt[0], tx, ty, best.dx, best.dy + 1)
                            var est = d0
                            for (a, b) in [(xm, xp), (ym, yp)] {
                                let denom = a - 2 * d0 + b
                                if denom > 1e-6, abs(0.5 * (a - b) / denom) <= 1 { est = min(est, d0 - 0.125 * (a - b) * (a - b) / denom) }
                            }
                            bestD = max(est, 0)
                        }
                    }
                    np[ty * lc + tx] = best
                    dp[ty * lc + tx] = bestD
                    kp[ty * lc + tx] = isOK
                }
            }
            } } }
            offsets = next; distances = dist; alignableTiles = ok
        }

        if scale > 1.01 {
            let mx = median(offsets.map(\.dx)), my = median(offsets.map(\.dy))
            for i in offsets.indices where abs(offsets[i].dx - mx) > 8 || abs(offsets[i].dy - my) > 8 {
                offsets[i] = (mx, my)
                distances[i] = distance(ref[0], alt[0], i % cols, i / cols, mx, my)
            }
        }
        return Alignment(cols: cols, rows: rows, offsets: offsets, distance: distances, alignable: alignableTiles)
    }

    static func fitNoise(base: BurstFrame, alt: BurstFrame, alignment al: Alignment) -> Noise? {
        let range = base.range, cap = range * 0.9
        let order = al.distance.sorted()
        guard !order.isEmpty else { return nil }
        let cut = order[order.count / 2]
        let logRange = log(max(range, 2))
        var sum2 = [Double](repeating: 0, count: 32), sumM = [Double](repeating: 0, count: 32), count = [Int](repeating: 0, count: 32)
        let W = base.cfa.width, H = base.cfa.height
        for ty in 0..<al.rows { for tx in 0..<al.cols where al.distance[ty * al.cols + tx] <= cut {
            let o = al.offsets[ty * al.cols + tx]
            for y in stride(from: ty * 32, to: min(ty * 32 + 32, H), by: 3) {
                let ay = y + 2 * o.dy
                guard ay >= 0, ay < H else { continue }
                for x in stride(from: tx * 32, to: min(tx * 32 + 32, W), by: 3) {
                    let ax = x + 2 * o.dx
                    guard ax >= 0, ax < W else { continue }
                    let r = Float(base.cfa.data[y * W + x]) - base.cfa.black
                    let a = Float(alt.cfa.data[ay * W + ax]) - alt.cfa.black
                    guard r <= cap, a <= cap else { continue }
                    let m = (r + a) * 0.5
                    guard m >= 1 else { continue }
                    let bin = Int(log(m) / logRange * 32)
                    guard bin >= 0, bin < 32 else { continue }
                    sum2[bin] += Double((r - a) * (r - a) * 0.5); sumM[bin] += Double(m); count[bin] += 1
                }
            }
        } }
        var S = 0.0, Sm = 0.0, Sv = 0.0, Smm = 0.0, Smv = 0.0, bins = 0
        for i in 0..<32 where count[i] >= 400 {
            let n = Double(count[i]), w = n.squareRoot(), m = sumM[i] / n, v = sum2[i] / n
            S += w; Sm += w * m; Sv += w * v; Smm += w * m * m; Smv += w * v * m; bins += 1
        }
        guard bins > 2 else { return nil }
        let det = S * Smm - Sm * Sm
        guard det != 0 else { return nil }
        var a = (S * Smv - Sv * Sm) / det, b = (Smm * Sv - Smv * Sm) / det
        if a < 0 { a = 0; b = Sv / S }
        let floor = Double((range / 4095) * (range / 4095))
        b = max(b, floor)
        return Noise(a: Float(a), b: Float(b))
    }

    static func tileWeights(ref: Plane, alignment al: inout Alignment, scale: Float, noise: Noise, cap: Float) -> (weights: [Float], good: Float) {
        var weights = [Float](repeating: 1, count: al.cols * al.rows)
        let limit = cap * 0.999
        for ty in 0..<al.rows { for tx in 0..<al.cols {
            let i = ty * al.cols + tx
            var sum: Float = 0, n = 0, below = 0
            for y in (ty * 16)..<min(ty * 16 + 16, ref.height) { for x in (tx * 16)..<min(tx * 16 + 16, ref.width) {
                let v = ref[x, y]; sum += v; n += 1; if v < limit { below += 1 }
            } }
            guard n > 0, below >= n / 4 else { al.alignable[i] = false; weights[i] = 1; continue }
            let m = max(sum / Float(n), 0)
            let sigma2 = 2 * (noise.b + m * noise.a + scale * scale * noise.b + m * scale * noise.a) * 0.25
            let expected = max(sqrt(max(sigma2, 1e-6) * 0.63662), 0.001)
            let excess = max(al.distance[i] - expected, 0) / (expected * 1.25)
            weights[i] = exp(-excess * excess)
        } }
        let good = weights.filter { $0 >= 0.5 }.count
        return (weights, Float(good) / Float(max(weights.count, 1)))
    }

    static func fillOffsets(_ al: inout Alignment) {
        let C = al.cols, R = al.rows
        var known = al.alignable
        guard known.contains(true), known.contains(false) else { return }
        for _ in 0..<(C + R) {
            var changed = false
            let snapshot = al.offsets, wasKnown = known
            for ty in 0..<R { for tx in 0..<C where !wasKnown[ty * C + tx] {
                var sx = 0, sy = 0, n = 0
                for (x, y) in [(tx - 1, ty), (tx + 1, ty), (tx, ty - 1), (tx, ty + 1)] where x >= 0 && x < C && y >= 0 && y < R && wasKnown[y * C + x] {
                    sx += snapshot[y * C + x].dx; sy += snapshot[y * C + x].dy; n += 1
                }
                if n > 0 { al.offsets[ty * C + tx] = (Int(Double(sx) / Double(n)), Int(Double(sy) / Double(n))); known[ty * C + tx] = true; changed = true }
            } }
            if !changed { break }
        }
        for _ in 0..<2 {
            let snapshot = al.offsets
            for ty in 0..<R { for tx in 0..<C where !al.alignable[ty * C + tx] {
                var sx = snapshot[ty * C + tx].dx, sy = snapshot[ty * C + tx].dy, n = 1
                for (x, y) in [(tx - 1, ty), (tx + 1, ty), (tx, ty - 1), (tx, ty + 1)] where x >= 0 && x < C && y >= 0 && y < R {
                    sx += snapshot[y * C + x].dx; sy += snapshot[y * C + x].dy; n += 1
                }
                al.offsets[ty * C + tx] = (Int(Double(sx) / Double(n)), Int(Double(sy) / Double(n)))
            } }
        }
    }

    static let expTable: [Float] = (0...4097).map { expf(Float($0) * -20 / 4096) }

    struct Accumulator { var weight: [Float], value: [Float] }

    static func accumulate(base: BurstFrame, alt: BurstFrame, confidence c: Plane, alignment al: Alignment, weights tw: [Float],
                           noise: Noise, ghost: [Float]?, into acc: inout Accumulator) {
        let W = base.cfa.width, H = base.cfa.height
        let range = base.range, altRange = alt.range, scale = alt.scale, same = alt.isSameExposure
        let unit = range / 4095
        let minVar = max(unit * unit, noise.b)
        let table = expTable
        acc.weight.withUnsafeMutableBufferPointer { sw in
        acc.value.withUnsafeMutableBufferPointer { sv in
        base.cfa.data.withUnsafeBufferPointer { rb in
        alt.cfa.data.withUnsafeBufferPointer { altData in
        c.v.withUnsafeBufferPointer { cb in
            nonisolated(unsafe) let ab = altData
            DispatchQueue.concurrentPerform(iterations: H) { y in
                let fyRaw = (Float(y) - 16) * 0.03125
                var ty0 = Int(fyRaw), fy: Float = fyRaw >= 0 ? fyRaw - Float(Int(fyRaw)) : 0
                if fyRaw < 0 { ty0 = 0 }
                if ty0 >= al.rows - 1 { ty0 = al.rows - 1; fy = 0 }
                let ty1 = min(ty0 + 1, al.rows - 1)
                for x in 0..<W {
                    let r = Float(rb[y * W + x]) - base.cfa.black
                    let cv = cb[(y >> 1) * c.width + (x >> 1)]
                    let refVar = max(minVar, noise.b + max(r, 0) * noise.a)
                    let fxRaw = (Float(x) - 16) * 0.03125
                    var tx0 = Int(fxRaw), fx: Float = fxRaw >= 0 ? fxRaw - Float(Int(fxRaw)) : 0
                    if fxRaw < 0 { tx0 = 0 }
                    if tx0 >= al.cols - 1 { tx0 = al.cols - 1; fx = 0 }
                    let tx1 = min(tx0 + 1, al.cols - 1)
                    let i00 = ty0 * al.cols + tx0, i01 = ty0 * al.cols + tx1, i10 = ty1 * al.cols + tx0, i11 = ty1 * al.cols + tx1
                    var wSum: Float = 0, vSum: Float = 0

                    func sample(_ bilinear: Float, _ tileW: Float, _ o: (dx: Int, dy: Int)) {
                        let fw = same ? tileW : tileW + (1 - tileW) * (1 - cv)
                        guard bilinear > 0, fw > 0.02 else { return }
                        let ax = x + 2 * o.dx, ay = y + 2 * o.dy
                        guard ax >= 0, ax < W, ay >= 0, ay < H else { return }
                        var v = Float(ab[ay * W + ax]) - alt.cfa.black
                        var ramp: Float = 1
                        if v > altRange * 0.9 { ramp = v >= altRange * 0.98 ? 0 : (altRange * 0.98 - v) / (altRange * 0.98 - altRange * 0.9) }
                        let k: Float
                        if same {
                            k = min(ramp, cv)
                            guard k > 0 else { return }
                            v *= scale
                        } else {
                            k = (1 - cv) * ramp
                            guard k > 0 else { return }
                            v *= scale
                            if cv < 0.5, r >= range * 0.9, v < range * 0.9 {
                                guard tileW > 0.5, v >= range * 0.5 else { return }
                            }
                            if let ghost {
                                let g = ghost[y * W + x]
                                if g > 0, g > scale * altRange * 0.98 { return }
                            }
                        }
                        let variance = max(scale * noise.a * max(v, 0) + scale * scale * noise.b, minVar)
                        let d = (v - r) * (v - r) / (18 * (variance + refVar))
                        var robust: Float = 0
                        if d < 20 {
                            let t = d * 204.8
                            let i = Int(t), f = t - Float(i)
                            robust = table[i] + (table[i + 1] - table[i]) * f
                        }
                        robust = cv * robust + (1 - cv)
                        let iv = min(refVar / max(variance, 1e-6), 1)
                        let w = bilinear * fw * robust * iv * k
                        wSum += w; vSum += w * v
                    }

                    let o = al.offsets
                    if o[i00] == o[i01] && o[i00] == o[i10] && o[i00] == o[i11] {
                        let blended = (1 - fy) * (1 - fx) * tw[i00] + (1 - fy) * fx * tw[i01] + fy * (1 - fx) * tw[i10] + fy * fx * tw[i11]
                        sample(1, blended, o[i00])
                    } else {
                        sample((1 - fy) * (1 - fx), tw[i00], o[i00])
                        sample((1 - fy) * fx, tw[i01], o[i01])
                        sample(fy * (1 - fx), tw[i10], o[i10])
                        sample(fy * fx, tw[i11], o[i11])
                    }
                    sw[y * W + x] += wSum
                    sv[y * W + x] += vSum
                }
            }
        } } } } }
    }

    static func confidence(_ f: BurstFrame) -> Plane {
        let w = f.cfa.width / 2, h = f.cfa.height / 2, W = f.cfa.width
        let range = f.range
        var out = [Float](repeating: 1, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var m: Float = 1
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let v = Float(f.cfa.data[(2 * y + dy) * W + 2 * x + dx]) - f.cfa.black
                let r: Float = v <= range * 0.9 ? 1 : (v >= range * 0.98 ? 0 : (range * 0.98 - v) / (range * 0.08))
                m = min(m, r)
            }
            out[y * w + x] = m
        } }
        return Plane(width: w, height: h, v: out)
    }

    static func shortDisagreement(base: BurstFrame, alt: BurstFrame, alignment al: Alignment) -> Float {
        let W = base.cfa.width, H = base.cfa.height, range = base.range
        var n = 0, bad = 0
        for y in stride(from: 0, to: H, by: 2) { for x in stride(from: 0, to: W, by: 2) {
            guard Float(base.cfa.data[y * W + x]) - base.cfa.black >= range * 0.9 else { continue }
            let o = al.offsets[min(y >> 5, al.rows - 1) * al.cols + min(x >> 5, al.cols - 1)]
            let ax = x + 2 * o.dx, ay = y + 2 * o.dy
            guard ax >= 0, ax < W, ay >= 0, ay < H else { continue }
            n += 1
            if alt.scale * (Float(alt.cfa.data[ay * W + ax]) - alt.cfa.black) < range * 0.5 { bad += 1 }
        } }
        return n < 2000 ? -1 : Float(bad) / Float(n)
    }

    static func updateGhost(_ ghost: inout [Float], started: Bool, alt: BurstFrame, alignment al: Alignment) {
        let W = alt.cfa.width, H = alt.cfa.height, range = alt.range
        ghost.withUnsafeMutableBufferPointer { g in
            DispatchQueue.concurrentPerform(iterations: H) { y in
                for x in 0..<W {
                    let o = al.offsets[min(y >> 5, al.rows - 1) * al.cols + min(x >> 5, al.cols - 1)]
                    let ax = x + 2 * o.dx, ay = y + 2 * o.dy
                    guard ax >= 0, ax < W, ay >= 0, ay < H else { continue }
                    let v = Float(alt.cfa.data[ay * W + ax]) - alt.cfa.black
                    if !started || v < range * 0.98 { g[y * W + x] = max(g[y * W + x], alt.scale * v) }
                }
            }
        }
    }

    static func measuredScale(base: BurstFrame, alt: BurstFrame) -> Float? {
        let W = base.cfa.width, H = base.cfa.height, rr = base.range, ra = alt.range
        var ratios: [Float] = []
        var offset = 0
        for y in stride(from: 0, to: H, by: 2) {
            for x in stride(from: offset, to: W, by: 2) {
                let r = Float(base.cfa.data[y * W + x]) - base.cfa.black
                let a = Float(alt.cfa.data[y * W + x]) - alt.cfa.black
                if r >= rr * 0.3, r <= rr * 0.8, a >= ra * 0.02, a <= ra * 0.8 { ratios.append(r / a) }
            }
            offset ^= 1
        }
        guard ratios.count >= 20000 else { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    static func finalize(base: BurstFrame, confidence conf: Plane, acc: Accumulator, ghost: [Float]?, noise: Noise,
                         maxScale: Float) -> (values: [Float], marked: [Bool]) {
        let W = base.cfa.width, H = base.cfa.height, R = base.range
        var out = [Float](repeating: 0, count: W * H)
        var marked = [Bool](repeating: false, count: W * H)
        let sd = ghost == nil ? 0 : sqrt(maxScale * maxScale * noise.b + max(R, 0) * maxScale * noise.a)
        for y in 0..<H { for x in 0..<W {
            let i = y * W + x
            let r = Float(base.cfa.data[i]) - base.cfa.black
            let c = conf.v[(y >> 1) * conf.width + (x >> 1)]
            let total = c + acc.weight[i]
            let m = total > 0.02 ? (acc.value[i] + r * c) / total : r
            var g: Float = -1
            if let ghost, ghost[i] > 0 { g = ghost[i] }
            let stuck = c < 0.5 && r >= 0.9 * R && m >= 0.9 * R && m < 1.05 * R
            if !stuck || (g < 1.05 * R + sd && g >= 0.9 * R - 2 * sd) {
                out[i] = m
            } else {
                out[i] = min(max(g, r), R * maxScale)
                marked[i] = true
            }
        } }
        for y in stride(from: 0, to: H - 1, by: 2) { for x in stride(from: 0, to: W - 1, by: 2) {
            guard conf.v[(y >> 1) * conf.width + (x >> 1)] < 0.5 else { continue }
            let idx = [y * W + x, y * W + x + 1, (y + 1) * W + x, (y + 1) * W + x + 1]
            let refs = idx.map { Float(base.cfa.data[$0]) - base.cfa.black }
            var disagree = false
            for k in 0..<4 where !marked[idx[k]] && refs[k] > 0 && refs[k] < 0.9 * R {
                if out[idx[k]] > refs[k] * 1.5 || out[idx[k]] * 1.5 < refs[k] { disagree = true }
            }
            guard disagree || idx.contains(where: { marked[$0] }) else { continue }
            for k in 0..<4 where !marked[idx[k]] {
                if refs[k] >= 0.9 * R {
                    if disagree, out[idx[k]] < refs[k] { out[idx[k]] = refs[k]; marked[idx[k]] = true }
                } else {
                    out[idx[k]] = max(refs[k], 0)
                }
            }
        } }
        return (out, marked)
    }

    static func repairHighlights(_ out: inout [Float], marked: [Bool], base: BurstFrame, ceiling: Float) {
        let W = base.cfa.width, H = base.cfa.height, R = base.range
        let bw = W / 2, bh = H / 2
        let gains = base.cfa.gains.map { $0 > 0 ? $0 : 1 }
        func gain(_ x: Int, _ y: Int) -> Float { gains[base.cfa.color(x, y)] }
        var level = [Float](repeating: 0, count: bw * bh)
        var mask = [Bool](repeating: false, count: bw * bh)
        for by in 0..<bh { for bx in 0..<bw {
            var m: Float = 1e30, any = false
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let x = 2 * bx + dx, y = 2 * by + dy, i = y * W + x
                m = min(m, max(out[i], R) * gain(x, y))
                if marked[i] { any = true }
            }
            level[by * bw + bx] = m; mask[by * bw + bx] = any
        } }
        for _ in 0..<3 {
            let src = level
            for by in 0..<bh { for bx in 0..<bw where src[by * bw + bx] > R {
                var sum: Float = 0, n = 0
                for ny in (by - 1)...(by + 1) where ny >= 0 && ny < bh { for nx in (bx - 1)...(bx + 1) where nx >= 0 && nx < bw && src[ny * bw + nx] > R {
                    sum += src[ny * bw + nx]; n += 1
                } }
                if n > 0 { level[by * bw + bx] = sum / Float(n) }
            } }
        }
        for by in 0..<bh { for bx in 0..<bw where mask[by * bw + bx] {
            let L = level[by * bw + bx]
            let t = min(max((L / ceiling - 0.8) / 0.15, 0), 1)
            let s = t * t * (3 - 2 * t)
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let x = 2 * bx + dx, y = 2 * by + dy, i = y * W + x
                var target = (L + s * (ceiling - L)) / gain(x, y)
                if !marked[i], out[i] <= target { target = out[i] }
                out[i] = target
            }
        } }
        for by in 0..<bh { for bx in 0..<bw {
            var v = [Float](repeating: 0, count: 4), peak: Float = 0
            let pos = [(0, 0), (1, 0), (0, 1), (1, 1)]
            for (k, (dx, dy)) in pos.enumerated() {
                let x = 2 * bx + dx, y = 2 * by + dy
                v[k] = out[y * W + x] * gain(x, y); peak = max(peak, v[k])
            }
            guard peak > R else { continue }
            let t = min((peak - R) / (R * 3), 1)
            let s = t * t * (3 - 2 * t)
            for (k, (dx, dy)) in pos.enumerated() {
                let x = 2 * bx + dx, y = 2 * by + dy
                out[y * W + x] = (v[k] + s * (peak - v[k])) / gain(x, y)
            }
        } }
    }

    static func sharpness(_ f: BurstFrame) -> Float {
        let base = pyramid(luma(f, cap: 0))[1]
        guard base.width > 2, base.height > 2 else { return 0 }
        var sum: Float = 0, n = 0
        for y in 1..<(base.height - 1) { for x in 1..<(base.width - 1) {
            let l = 4 * base[x, y] - base[x - 1, y] - base[x + 1, y] - base[x, y - 1] - base[x, y + 1]
            sum += l * l; n += 1
        } }
        return n > 0 ? sum / Float(n) : 0
    }

    public static func merge(_ frames: [BurstFrame]) throws -> BurstMergeResult {
        guard let first = frames.first else { throw PipelineError.decode("no frames to merge") }
        guard frames.allSatisfy({ $0.cfa.width == first.cfa.width && $0.cfa.height == first.cfa.height }),
              first.cfa.width >= 64, first.cfa.height >= 64 else { throw PipelineError.decode("burst frames differ in size") }
        let candidates = frames.indices.filter { frames[$0].isSameExposure }
        guard !candidates.isEmpty else { throw PipelineError.decode("no base-exposure frame") }
        let refIndex: Int
        if candidates.count == 1 {
            refIndex = candidates[0]
        } else if frames.allSatisfy({ ($0.blurPixels ?? -1) >= 0 }) {
            refIndex = candidates.min { frames[$0].blurPixels! < frames[$1].blurPixels! }!
        } else {
            refIndex = candidates.max { sharpness(frames[$0]) < sharpness(frames[$1]) }!
        }
        let base = frames[refIndex]
        let range = base.range, cap = range * 0.9
        let refPyramid = pyramid(luma(base, cap: cap))
        let conf = confidence(base)
        var noise = defaultNoise(range: range)
        var fitted = false
        let count = base.cfa.width * base.cfa.height
        var acc = Accumulator(weight: [Float](repeating: 0, count: count), value: [Float](repeating: 0, count: count))
        var maxScale: Float = 1, merged = 1, shorts = 0
        var ghost: [Float]? = nil
        let order = frames.indices.filter { $0 != refIndex }.sorted { frames[$0].isSameExposure && !frames[$1].isSameExposure }
        for i in order {
            var alt = frames[i]
            if let e0 = base.cfa.exposure, let e1 = alt.cfa.exposure, e1 > 0 {
                let ratio = Float(e0 / e1)
                if abs(ratio - 1) < 0.001 { alt.scale = 1 } else { alt.scale = ratio }
            }
            if alt.scale > 1.01, let measured = measuredScale(base: base, alt: alt) { alt.scale = measured }
            let altPyramid = pyramid(luma(alt, cap: cap))
            var al = align(ref: refPyramid, alt: altPyramid, scale: alt.scale, noise: noise)
            if !fitted, alt.isSameExposure, let n = fitNoise(base: base, alt: alt, alignment: al) { noise = n; fitted = true }
            let (weights, good) = tileWeights(ref: refPyramid[0], alignment: &al, scale: alt.scale, noise: noise, cap: cap)
            guard good >= 0.15 else { continue }
            if alt.scale > 1.01 {
                guard shortDisagreement(base: base, alt: alt, alignment: al) <= 0.25 else { continue }
                var g = ghost ?? [Float](repeating: 0, count: count)
                updateGhost(&g, started: ghost != nil, alt: alt, alignment: al)
                ghost = g
            }
            fillOffsets(&al)
            accumulate(base: base, alt: alt, confidence: conf, alignment: al, weights: weights, noise: noise, ghost: ghost, into: &acc)
            maxScale = max(maxScale, alt.scale)
            merged += 1
            if !alt.isSameExposure { shorts += 1 }
        }

        let headroom = maxScale * range
        var (values, marked) = finalize(base: base, confidence: conf, acc: acc, ghost: ghost, noise: noise, maxScale: maxScale)
        if maxScale > 1.05 { repairHighlights(&values, marked: marked, base: base, ceiling: headroom) }
        let factor = 65535 / max(headroom, 1)
        let W = base.cfa.width
        let out = values.map { UInt16(min(max($0 * factor + 0.5, 0), 65535)) }
        return BurstMergeResult(cfa: out, width: W, height: base.cfa.height, referenceIndex: refIndex,
                                headroomStops: log2(maxScale), merged: merged, shorts: shorts, noiseModel: (noise.a, noise.b))
    }

    @discardableResult
    public static func mergeFiles(_ frames: [(url: URL, scale: Float)], blurPixels: [Float?] = [], exposureBiasStops: Float = 0, to output: URL) throws -> BurstMergeResult {
        let decoded = try frames.enumerated().map { i, f in
            BurstFrame(cfa: try RawCFA(url: f.url), scale: f.scale, blurPixels: i < blurPixels.count ? blurPixels[i] : nil)
        }
        let result = try merge(decoded)
        let ref = try DNGFile(url: frames[result.referenceIndex].url)
        let n = Double(result.merged), h = Double(pow(2, result.headroomStops))
        try ref.writeMerged(cfa: result.cfa, width: result.width, height: result.height, marker: result.marker(exposureBiasStops: exposureBiasStops),
                            noiseScale: (1 / (n * h), 1 / (h * h * n)), exposureBias: exposureBiasStops, to: output)
        return result
    }
}
