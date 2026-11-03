// Crepuscule - SuperResolutionDNG.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

extension SuperResolution {
    @discardableResult
    public static func reconstructFiles(_ urls: [URL], cropFactor: Double, outputScale: Double? = nil, blurPixels: [Float?] = [],
                                        to output: URL) throws -> SuperResolutionResult {
        try reconstructFiles(urls, cropFactor: cropFactor, outputScale: outputScale, blurPixels: blurPixels, options: Options(), to: output)
    }

    static func baseExposure(_ exposures: [Double?]) -> Double? {
        let known = exposures.compactMap { $0 }.filter { $0 > 0 }
        let groups = known.map { e in (e, known.filter { abs($0 / e - 1) <= 0.03 }.count) }
        return groups.max { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }?.0
    }

    static func reconstructFiles(_ urls: [URL], cropFactor: Double, outputScale: Double?, blurPixels: [Float?], options: Options,
                                 to output: URL) throws -> SuperResolutionResult {
        guard let firstURL = urls.first else { throw PipelineError.decode("no frames") }
        let firstFile = try DNGFile(url: firstURL)
        let first = try firstFile.readCFA()
        let geometry = firstFile.geometry(width: first.width, height: first.height)
        let plan = try self.plan(width: first.width, height: first.height, area: geometry.visible, cropFactor: cropFactor,
                                 outputScale: outputScale, margin: options.margin)
        var frames: [BurstFrame?] = []
        for (i, url) in urls.enumerated() {
            let cfa = i == 0 ? first : try RawCFA(url: url)
            let blur = i < blurPixels.count ? blurPixels[i] : nil
            guard cfa.width == first.width, cfa.height == first.height else { frames.append(nil); continue }
            frames.append(BurstFrame(cfa: window(cfa, plan.window), scale: 1, blurPixels: blur))
        }
        // only keep the most common exposure, shorts made the ref way too dark
        if let base = baseExposure(frames.map { $0?.cfa.exposure }) {
            for i in frames.indices {
                if let e = frames[i]?.cfa.exposure, e > 0, abs(e / base - 1) > 0.03 { frames[i]?.scale = Float(base / e) }
            }
        }
        var noise: BurstMerger.Noise? = nil
        let np = firstFile.reader.doubles(firstFile.reader.entries(at: firstFile.rawOffset)[51041]
                                          ?? firstFile.reader.entries(at: firstFile.ifd0Offset)[51041])
        if np.count >= 2, np[0] > 0, np[1] >= 0 {
            let range = Double(max(first.white - first.black, 1))
            noise = BurstMerger.Noise(a: Float(np[0] * range), b: Float(max(np[1] * range * range, 1e-3)))
        }
        let result = try run(frames, plan: plan, noiseModel: noise, options: options)
        frames.removeAll()
        let ref = result.referenceIndex == 0 ? firstFile : try DNGFile(url: urls[result.referenceIndex])
        try ref.writeLinearRaw(result, plan: plan, geometry: ref.geometry(width: first.width, height: first.height),
                              cropFactor: cropFactor, to: output)
        return result
    }

    static func marker(_ r: SuperResolutionResult, cropFactor: Double, apple: Bool) -> String {
        String(format: BurstMerger.markerPrefix + "v=1;frames=%d;shorts=0;headroom=%.3f;bias=0.000;alg=%d;sr=%.3f;crop=%.3f;srv=%d",
               r.merged, apple ? -1.5 : 0, BurstMerger.algorithmVersion, r.scaleX, cropFactor, algorithmVersion)
    }
}

struct DNGGeometry {
    var active: SuperResolution.Rect
    var visible: SuperResolution.Rect
    var sensorWidth: Int, sensorHeight: Int
}

extension DNGFile {
    func geometry(width W: Int, height H: Int) -> DNGGeometry {
        let e = reader.entries(at: rawOffset)
        var active = SuperResolution.Rect(x: 0, y: 0, width: W, height: H)
        let aa = reader.ints(e[50829])
        if aa.count == 4, aa[0] >= 0, aa[1] >= 0, aa[2] <= H, aa[3] <= W, aa[2] > aa[0], aa[3] > aa[1] {
            active = .init(x: aa[1], y: aa[0], width: aa[3] - aa[1], height: aa[2] - aa[0])
        }
        var visible = active
        let origin = reader.doubles(e[50719]), size = reader.doubles(e[50720])
        if origin.count == 2, size.count == 2 {
            let x = Int(origin[0].rounded()), y = Int(origin[1].rounded()), w = Int(size[0].rounded()), h = Int(size[1].rounded())
            if x >= 0, y >= 0, w > 0, h > 0, x + w <= active.width, y + h <= active.height {
                visible = .init(x: active.x + x, y: active.y + y, width: w, height: h)
            }
        }
        return DNGGeometry(active: active, visible: visible, sensorWidth: W, sensorHeight: H)
    }

    func writeLinearRaw(_ r: SuperResolutionResult, plan: SuperResolution.Plan, geometry: DNGGeometry, cropFactor: Double, to url: URL) throws {
        let little = reader.little
        let e0 = reader.entries(at: rawOffset)
        let oldOffsets = e0[324] != nil ? reader.ints(e0[324]) : reader.ints(e0[273])
        let oldCounts = e0[325] != nil ? reader.ints(e0[325]) : reader.ints(e0[279])
        var out = data
        if let first = oldOffsets.min(), first >= metadataEnd(),
           zip(oldOffsets, oldCounts).map({ $0 + $1 }).max().map({ $0 + 16 >= data.count }) == true {
            out = data.prefix(first)
        }
        func align() { while out.count % 4 != 0 { out.append(0) } }
        func b16(_ v: UInt16) -> [UInt8] { let b = little ? v.littleEndian : v.bigEndian; return withUnsafeBytes(of: b) { Array($0) } }
        func b32(_ v: UInt32) -> [UInt8] { let b = little ? v.littleEndian : v.bigEndian; return withUnsafeBytes(of: b) { Array($0) } }
        func b64(_ v: Double) -> [UInt8] { let b = little ? v.bitPattern.littleEndian : v.bitPattern.bigEndian; return withUnsafeBytes(of: b) { Array($0) } }

        let W = r.width, H = r.height
        let rowsPerStrip = max(1, min(H, (1 << 20) / (W * 6)))
        var stripOffsets: [UInt32] = [], stripCounts: [UInt32] = []
        align()
        guard out.count + W * H * 6 < Int(UInt32.max) else { throw PipelineError.encode }
        r.rgb.withUnsafeBufferPointer { src in
            for y0 in stride(from: 0, to: H, by: rowsPerStrip) {
                let n = min(rowsPerStrip, H - y0) * W * 3
                stripOffsets.append(UInt32(out.count)); stripCounts.append(UInt32(n * 2))
                let slice = UnsafeBufferPointer(rebasing: src[(y0 * W * 3)..<(y0 * W * 3 + n)])
                if little == (UInt16(1).littleEndian == 1) {
                    out.append(UnsafeBufferPointer(start: UnsafeRawPointer(slice.baseAddress!).assumingMemoryBound(to: UInt8.self), count: n * 2))
                } else {
                    var swapped = [UInt16](repeating: 0, count: n)
                    for i in 0..<n { swapped[i] = slice[i].byteSwapped }
                    swapped.withUnsafeBytes { out.append(contentsOf: $0) }
                }
            }
        }

        typealias Entry = (tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])
        func rawEntries(_ offset: Int) -> [Entry] {
            let n = Int(reader.u16(offset))
            return (0..<n).map { i in
                let p = offset + 2 + i * 12
                return (reader.u16(p), reader.u16(p + 2), reader.u32(p + 4), Array(data[(p + 8)..<(p + 12)]))
            }
        }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: Int, _ payload: [UInt8]) -> Entry {
            if payload.count <= 4 { return (tag, type, UInt32(count), payload + [UInt8](repeating: 0, count: 4 - payload.count)) }
            align()
            let at = out.count
            out.append(contentsOf: payload)
            return (tag, type, UInt32(count), b32(UInt32(at)))
        }
        func longs(_ tag: UInt16, _ v: [UInt32]) -> Entry { entry(tag, 4, v.count, v.flatMap(b32)) }
        func shorts(_ tag: UInt16, _ v: [UInt16]) -> Entry { entry(tag, 3, v.count, v.flatMap(b16)) }
        func writeIFD(_ entries: [Entry], next: UInt32) -> Int {
            align()
            let at = out.count
            let sorted = entries.sorted { $0.tag < $1.tag }
            out.append(contentsOf: b16(UInt16(sorted.count)))
            for e in sorted { out.append(contentsOf: b16(e.tag) + b16(e.type) + b32(e.count) + e.value) }
            out.append(contentsOf: b32(next))
            return at
        }

        let nEff = max(1, Double(r.merged) / 2)
        func noiseEntry(_ e: [UInt16: TIFFReader.Entry]) -> Entry? {
            let np = reader.doubles(e[51041])
            guard !np.isEmpty, np.count % 2 == 0 else { return nil }
            return entry(51041, 12, np.count, np.map { $0 / nEff }.flatMap(b64))
        }

        let lists: [(tag: UInt16, image: SuperResolution.Rect)] = [
            (51008, .init(x: 0, y: 0, width: geometry.sensorWidth, height: geometry.sensorHeight)),
            (51009, geometry.active), (51022, geometry.active),
        ]
        var opcodeEntries: [Entry] = []
        for (tag, image) in lists {
            guard let list = e0[tag] ?? reader.entries(at: ifd0Offset)[tag], list.valueOffset + list.count <= data.count else { continue }
            let bytes = [UInt8](data[list.valueOffset..<(list.valueOffset + list.count)])
            if let remapped = OpcodeRemap.remap(bytes, image: image, crop: plan.crop, outWidth: W, outHeight: H, pattern: readPattern()) {
                opcodeEntries.append(entry(tag, 7, remapped.count, remapped))
            }
        }

        let dropped: Set<UInt16> = [
            256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 322, 323, 324, 325,
            33421, 33422, 50710, 50711, 50712, 50713, 50714, 50715, 50716, 50717, 50718, 50719, 50720,
            50733, 50738, 50780, 50829, 50830, 51008, 51009, 51022, 51041, 51110, 51125, 65000,
        ]
        let make = reader.string(reader.entries(at: ifd0Offset)[271])
        let markerBytes = Array(SuperResolution.marker(r, cropFactor: cropFactor, apple: make.lowercased().hasPrefix("apple")).utf8) + [0]
        var raw = rawEntries(rawOffset).filter { !dropped.contains($0.tag) }
        raw += [
            longs(256, [UInt32(W)]), longs(257, [UInt32(H)]), shorts(258, [16, 16, 16]), shorts(259, [1]), shorts(262, [34892]),
            shorts(277, [3]), longs(278, [UInt32(rowsPerStrip)]), longs(273, stripOffsets), longs(279, stripCounts), shorts(284, [1]),
            longs(50714, [0, 0, 0]), longs(50717, [65535, 65535, 65535]),
            longs(50719, [0, 0]), longs(50720, [UInt32(W), UInt32(H)]),
        ]
        raw += opcodeEntries
        if let n = noiseEntry(e0) { raw.append(n) }
        let rawNext = reader.u32(rawOffset + 2 + Int(reader.u16(rawOffset)) * 12)
        let rootNext = reader.u32(ifd0Offset + 2 + Int(reader.u16(ifd0Offset)) * 12)
        let newRoot: Int
        if rawOffset == ifd0Offset {
            raw.append(entry(65000, 2, markerBytes.count, markerBytes))
            newRoot = writeIFD(raw, next: rootNext)
        } else {
            let newRaw = writeIFD(raw, next: rawNext)
            let rootE = reader.entries(at: ifd0Offset)
            var root = rawEntries(ifd0Offset).filter { $0.tag != 330 && $0.tag != 65000 && $0.tag != 51041 }
            let subs = reader.ints(rootE[330]).map { UInt32($0 == rawOffset ? newRaw : $0) }
            root.append(longs(330, subs))
            if let n = noiseEntry(rootE) { root.append(n) }
            root.append(entry(65000, 2, markerBytes.count, markerBytes))
            newRoot = writeIFD(root, next: rootNext)
        }
        let at = b32(UInt32(newRoot))
        for i in 0..<4 { out[4 + i] = at[i] }
        try out.write(to: url, options: .atomic)
    }

    func readPattern() -> [Int] {
        let p = reader.ints(reader.entries(at: rawOffset)[33422])
        return p.count == 4 && p.allSatisfy({ (0...2).contains($0) }) ? p : [0, 1, 1, 2]
    }
}

enum OpcodeRemap {
    static func remap(_ b: [UInt8], image: SuperResolution.Rect, crop: SuperResolution.Rect, outWidth: Int, outHeight: Int,
                      pattern: [Int]) -> [UInt8]? {
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(b[o + $1]) } }
        func f64(_ o: Int) -> Double { Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[o + $1]) }) }
        func p32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(24 - $0 * 8)) } }
        func p64(_ v: Double) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v.bitPattern >> UInt64(56 - $0 * 8)) } }
        guard b.count >= 4 else { return nil }
        let ox = Double(crop.x - image.x), oy = Double(crop.y - image.y)
        let cw = Double(crop.width), ch = Double(crop.height), iw = Double(image.width), ih = Double(image.height)
        func rho(_ cx: Double, _ cy: Double) -> (Double, Double, Double) {
            let px = cx * iw, py = cy * ih
            let mOld = [(0.0, 0.0), (iw, 0), (0, ih), (iw, ih)].map { hypot($0.0 - px, $0.1 - py) }.max()!
            let nx = px - ox, ny = py - oy
            let mNew = [(0.0, 0.0), (cw, 0), (0, ch), (cw, ch)].map { hypot($0.0 - nx, $0.1 - ny) }.max()!
            return (mNew / max(mOld, 1e-9), nx / cw, ny / ch)
        }
        var out: [UInt8] = []
        var kept = 0
        var gainColours = Set<Int>()
        var p = 4
        for _ in 0..<Int(u32(0)) {
            guard p + 16 <= b.count else { break }
            let id = u32(p), version = Array(b[(p + 4)..<(p + 8)]), flags = u32(p + 8), size = Int(u32(p + 12))
            let q = p + 16
            guard q + size <= b.count else { break }
            defer { p = q + size }
            var params: [UInt8]? = nil
            switch id {
            case 3 where size >= 56:
                let (rh, ncx, ncy) = rho(f64(q + 40), f64(q + 48))
                params = (0..<5).flatMap { p64(f64(q + $0 * 8) * pow(rh, Double(2 * $0 + 2))) } + p64(ncx) + p64(ncy)
            case 1 where size >= 4:
                let planes = Int(u32(q))
                guard size >= 4 + planes * 48 + 16 else { break }
                let c = q + 4 + planes * 48
                let (rh, ncx, ncy) = rho(f64(c), f64(c + 8))
                var v = p32(UInt32(planes))
                for k in 0..<planes {
                    let o = q + 4 + k * 48
                    for i in 0..<4 { v += p64(f64(o + i * 8) * pow(rh, Double(2 * i))) }
                    v += p64(f64(o + 32) * rh) + p64(f64(o + 40) * rh)
                }
                params = v + p64(ncx) + p64(ncy)
            case 9 where size >= 76:
                let top = Int(u32(q)), left = Int(u32(q + 4))
                var plane = u32(q + 16), planes = u32(q + 20)
                let rowPitch = u32(q + 24), colPitch = u32(q + 28)
                if rowPitch == 2, colPitch == 2, planes == 1 {
                    let colour = pattern[((top + image.y) & 1) * 2 + ((left + image.x) & 1)]
                    guard gainColours.insert(colour).inserted else { break }
                    plane = UInt32(colour); planes = 1
                } else if rowPitch != 1 || colPitch != 1 {
                    break
                }
                let spacingV = f64(q + 40), spacingH = f64(q + 48), originV = f64(q + 56), originH = f64(q + 64)
                var v = p32(0) + p32(0) + p32(UInt32(outHeight)) + p32(UInt32(outWidth)) + p32(plane) + p32(planes) + p32(1) + p32(1)
                v += Array(b[(q + 32)..<(q + 40)])
                v += p64(spacingV * ih / ch) + p64(spacingH * iw / cw) + p64((originV * ih - oy) / ch) + p64((originH * iw - ox) / cw)
                v += Array(b[(q + 72)..<(q + size)])
                params = v
            default:
                break
            }
            guard let params else { continue }
            out += p32(id) + version + p32(flags) + p32(UInt32(params.count)) + params
            kept += 1
        }
        return kept == 0 ? nil : p32(UInt32(kept)) + out
    }
}
