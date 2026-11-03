// Crepuscule - DNGRaw.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public struct RawCFA: Sendable {
    public var width: Int, height: Int
    public var data: [UInt16]
    public var black: Float, white: Float
    public var pattern: [Int] = [0, 1, 1, 2]
    public var gains: [Float] = [1, 1, 1]
    public var exposure: Double?

    public init(width: Int, height: Int, data: [UInt16], black: Float, white: Float) {
        self.width = width; self.height = height; self.data = data; self.black = black; self.white = white
    }

    func color(_ x: Int, _ y: Int) -> Int { pattern[(y & 1) * 2 + (x & 1)] }

    public init(url: URL) throws {
        let file = try DNGFile(url: url)
        self = try file.readCFA()
    }
}

struct DNGFile {
    let data: Data
    let reader: TIFFReader
    let ifd0Offset: Int
    let rawOffset: Int

    init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    init(data: Data) throws {
        self.data = data
        guard data.count > 8 else { throw PipelineError.invalidDNG("file too short") }
        switch (data[0], data[1]) {
        case (0x49, 0x49): reader = TIFFReader(data: data, little: true)
        case (0x4D, 0x4D): reader = TIFFReader(data: data, little: false)
        default: throw PipelineError.invalidDNG("not a TIFF container")
        }
        ifd0Offset = Int(reader.u32(4))
        let root = reader.entries(at: ifd0Offset)
        var best = (offset: -1, area: 0)
        for offset in [ifd0Offset] + reader.ints(root[330]) {
            let e = reader.entries(at: offset)
            guard (reader.ints(e[254]).first ?? 0) == 0, reader.ints(e[262]).first == 32803 else { continue }
            let area = (reader.ints(e[256]).first ?? 0) * (reader.ints(e[257]).first ?? 0)
            if area > best.area { best = (offset, area) }
        }
        guard best.offset > 0 else { throw PipelineError.invalidDNG("no Bayer raw IFD") }
        rawOffset = best.offset
    }

    func readCFA() throws -> RawCFA {
        let e = reader.entries(at: rawOffset)
        let w = reader.ints(e[256]).first ?? 0, h = reader.ints(e[257]).first ?? 0
        guard w > 0, h > 0, (reader.ints(e[277]).first ?? 1) == 1 else { throw PipelineError.invalidDNG("unsupported raw layout") }
        let compression = reader.ints(e[259]).first ?? 1
        let bits = reader.ints(e[258]).first ?? 16
        var out = [UInt16](repeating: 0, count: w * h)
        let tileW = reader.ints(e[322]).first, tileH = reader.ints(e[323]).first
        let offsets = tileW != nil ? reader.ints(e[324]) : reader.ints(e[273])
        let counts = tileW != nil ? reader.ints(e[325]) : reader.ints(e[279])
        let pieceW = tileW ?? w, pieceH = tileH ?? (reader.ints(e[278]).first ?? h)
        let across = (w + pieceW - 1) / pieceW
        for (i, offset) in offsets.enumerated() {
            guard i < counts.count, offset + counts[i] <= data.count else { throw PipelineError.invalidDNG("raw data out of range") }
        }
        guard compression == 7 || compression == 1 else { throw PipelineError.invalidDNG("unsupported compression \(compression)") }
        guard compression != 1 || bits == 16 else { throw PipelineError.invalidDNG("unsupported bit depth \(bits)") }
        let lock = NSLock()
        var failure: Error?
        out.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: offsets.count) { i in
                let offset = offsets[i]
                let x0 = (i % across) * pieceW, y0 = (i / across) * pieceH
                let piece: (samples: [UInt16], width: Int, height: Int)
                if compression == 7 {
                    do { piece = try LosslessJPEG.decode(data[offset..<(offset + counts[i])]) } catch {
                        lock.lock(); if failure == nil { failure = error }; lock.unlock()
                        return
                    }
                } else {
                    let n = counts[i] / 2
                    piece = ((0..<n).map { reader.u16(offset + $0 * 2) }, pieceW, n / pieceW)
                }
                let rowLen = piece.samples.count / max(piece.height, 1)
                for r in 0..<min(pieceH, h - y0) {
                    let dst = (y0 + r) * w + x0
                    let src = r * rowLen
                    guard src < piece.samples.count else { break }
                    let n = min(min(pieceW, w - x0), piece.samples.count - src)
                    for c in 0..<n { o[dst + c] = piece.samples[src + c] }
                }
            }
        }
        if let failure { throw failure }
        if let table = e[50712].map({ reader.ints($0) }), !table.isEmpty {
            for i in out.indices { out[i] = UInt16(clamping: table[min(Int(out[i]), table.count - 1)]) }
        }
        let blacks = reader.doubles(e[50714])
        let black = blacks.isEmpty ? 0 : Float(blacks.reduce(0, +) / Double(blacks.count))
        let white = Float(reader.doubles(e[50717]).first ?? Double((1 << bits) - 1))
        var cfa = RawCFA(width: w, height: h, data: out, black: black, white: white)
        let pattern = reader.ints(e[33422])
        if pattern.count == 4, pattern.allSatisfy({ (0...2).contains($0) }) { cfa.pattern = pattern }
        let root = reader.entries(at: ifd0Offset)
        let neutral = reader.doubles(root[50728])
        if neutral.count == 3, neutral.allSatisfy({ $0 > 0 }) { cfa.gains = neutral.map { Float(1 / $0) } }
        if let exifAt = reader.ints(root[34665]).first {
            let exif = reader.entries(at: exifAt)
            if let t = reader.doubles(exif[33434]).first, let iso = reader.doubles(exif[34855]).first, t > 0, iso > 0 { cfa.exposure = t * iso }
        }
        return cfa
    }

    static func scalingVignette(in data: Data, by scale: Double) -> Data {
        guard let file = try? DNGFile(data: data) else { return data }
        var out = data
        func be32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(data[o + $1]) } }
        let root = file.reader.entries(at: file.ifd0Offset)
        for ifd in Set([file.ifd0Offset, file.rawOffset] + file.reader.ints(root[330])) {
            guard let list = file.reader.entries(at: ifd)[51022], list.count >= 4, list.valueOffset + list.count <= data.count else { continue }
            let end = list.valueOffset + list.count
            var p = list.valueOffset + 4
            for _ in 0..<be32(list.valueOffset) {
                guard p + 16 <= end else { break }
                let id = be32(p), size = be32(p + 12), params = p + 16
                guard params + size <= end else { break }
                if id == 3, size >= 56 {
                    for k in 0..<5 {
                        let at = params + k * 8
                        let bits = (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(data[at + $1]) }
                        let scaled = (Double(bitPattern: bits) * scale).bitPattern
                        for b in 0..<8 { out[at + b] = UInt8(truncatingIfNeeded: scaled >> UInt64(56 - b * 8)) }
                    }
                }
                p = params + size
            }
        }
        return out
    }

    func metadataEnd() -> Int {
        var end = 8, seen = Set<Int>()
        let sizes: [UInt16: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        func visit(_ offset: Int) {
            guard offset > 0, offset + 2 <= data.count, seen.insert(offset).inserted else { return }
            let n = Int(reader.u16(offset))
            end = max(end, offset + 2 + n * 12 + 4)
            let e = reader.entries(at: offset)
            for (tag, entry) in e {
                let size = (sizes[entry.type] ?? 1) * entry.count
                if size > 4 { end = max(end, entry.valueOffset + size) }
                if [330, 34665, 34853, 40965].contains(tag) { reader.ints(entry).forEach(visit) }
            }
            let image: (UInt16, UInt16) = e[324] != nil ? (324, 325) : (273, 279)
            if offset != rawOffset {
                for (o, c) in zip(reader.ints(e[image.0]), reader.ints(e[image.1])) { end = max(end, o + c) }
            }
            visit(Int(reader.u32(offset + 2 + n * 12)))
        }
        visit(ifd0Offset)
        return end
    }

    func writeMerged(cfa: [UInt16], width: Int, height: Int, marker: String, noiseScale: (Double, Double)? = nil, exposureBias: Float? = nil, to url: URL) throws {
        let e0 = reader.entries(at: rawOffset)
        let oldOffsets = e0[324] != nil ? reader.ints(e0[324]) : reader.ints(e0[273])
        let oldCounts = e0[325] != nil ? reader.ints(e0[325]) : reader.ints(e0[279])
        var out = data
        if let first = oldOffsets.min(), first >= metadataEnd(),
           zip(oldOffsets, oldCounts).map({ $0 + $1 }).max().map({ $0 + 16 >= data.count }) == true {
            out = data.prefix(first)
        }
        func align() { if out.count % 2 == 1 { out.append(0) } }
        func put16(_ v: UInt16) { let b = reader.little ? v : v.byteSwapped; withUnsafeBytes(of: b) { out.append(contentsOf: $0) } }
        func put32(_ v: UInt32) { let b = reader.little ? v : v.byteSwapped; withUnsafeBytes(of: b) { out.append(contentsOf: $0) } }
        func patch32(_ at: Int, _ v: UInt32) {
            let b = reader.little ? v : v.byteSwapped
            withUnsafeBytes(of: b) { for i in 0..<4 { out[at + i] = $0[i] } }
        }
        func patchDouble(_ at: Int, _ v: Double) {
            let bits = reader.little ? v.bitPattern : v.bitPattern.byteSwapped
            withUnsafeBytes(of: bits) { for i in 0..<8 { out[at + i] = $0[i] } }
        }

        if let (sScale, oScale) = noiseScale {
            for at in Set([ifd0Offset, rawOffset]) {
                guard let np = reader.entries(at: at)[51041], np.type == 12, np.count >= 2, np.valueOffset + np.count * 8 <= out.count else { continue }
                for i in 0..<np.count {
                    let o = np.valueOffset + i * 8
                    let raw = reader.little ? UInt64(littleEndian: data[o..<(o + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
                                            : UInt64(bigEndian: data[o..<(o + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
                    patchDouble(o, Double(bitPattern: raw) * (i % 2 == 0 ? sScale : oScale))
                }
            }
        }

        if let exposureBias, let exifAt = reader.ints(reader.entries(at: ifd0Offset)[34665]).first,
           let tag = reader.entries(at: exifAt)[37380], tag.type == 10, tag.count == 1, tag.valueOffset + 8 <= out.count {
            patch32(tag.valueOffset, UInt32(bitPattern: Int32((exposureBias * 1000).rounded())))
            patch32(tag.valueOffset + 4, 1000)
        }

        let oldTile = reader.ints(e0[322]).first ?? 0
        let tile = oldTile > 0 && oldTile <= 256 && oldTile % 16 == 0 ? oldTile : 256
        let across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
        var tiles = [Data](repeating: Data(), count: across * down)
        tiles.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: across * down) { t in
                let x0 = (t % across) * tile, y0 = (t / across) * tile
                var samples = [UInt16](repeating: 0, count: tile * tile)
                for r in 0..<tile {
                    let y = min(y0 + r, height - 1)
                    for c in 0..<tile { samples[r * tile + c] = cfa[y * width + min(x0 + c, width - 1)] }
                }
                buf[t] = LosslessJPEG.encode(samples, width: tile, height: tile)
            }
        }
        align()
        var tileOffsets: [UInt32] = []
        for t in tiles { align(); tileOffsets.append(UInt32(out.count)); out.append(t) }
        align()
        let markerBytes = Array(marker.utf8) + [0]
        let markerOffset = out.count
        out.append(contentsOf: markerBytes)
        align()

        typealias Entry = (tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])
        func raw(_ offset: Int) -> [Entry] {
            let n = Int(reader.u16(offset))
            return (0..<n).map { i in
                let p = offset + 2 + i * 12
                return (reader.u16(p), reader.u16(p + 2), reader.u32(p + 4), Array(data[(p + 8)..<(p + 12)]))
            }
        }
        func inline32(_ v: UInt32) -> [UInt8] { let b = reader.little ? v : v.byteSwapped; return withUnsafeBytes(of: b) { Array($0) } }
        func inline16(_ v: UInt16) -> [UInt8] { let b = reader.little ? v : v.byteSwapped; return withUnsafeBytes(of: b) { Array($0) } + [0, 0] }
        func array32(_ values: [UInt32]) -> [UInt8] {
            if values.count == 1 { return inline32(values[0]) }
            align()
            let at = out.count
            values.forEach(put32)
            return inline32(UInt32(at))
        }
        func writeIFD(_ entries: [Entry], next: UInt32) -> Int {
            align()
            let at = out.count
            let sorted = entries.sorted { $0.tag < $1.tag }
            put16(UInt16(sorted.count))
            for e in sorted { put16(e.tag); put16(e.type); put32(e.count); out.append(contentsOf: e.value) }
            put32(next)
            return at
        }

        let dropped: Set<UInt16> = [259, 258, 273, 278, 279, 322, 323, 324, 325, 50712, 50713, 50714, 50715, 50716, 50717]
        var rawEntries = raw(rawOffset).filter { !dropped.contains($0.tag) }
        let one16 = Array(inline16(1).prefix(2))
        let offsetsValue = array32(tileOffsets)
        let countsValue = array32(tiles.map { UInt32($0.count) })
        rawEntries += [
            (259, 3, 1, inline16(7)), (258, 3, 1, inline16(16)),
            (322, 4, 1, inline32(UInt32(tile))), (323, 4, 1, inline32(UInt32(tile))),
            (324, 4, UInt32(tiles.count), offsetsValue), (325, 4, UInt32(tiles.count), countsValue),
            (50713, 3, 2, one16 + one16), (50714, 4, 1, inline32(0)),
            (50717, 4, 1, inline32(65535)),
        ]
        let rawNext = reader.u32(rawOffset + 2 + Int(reader.u16(rawOffset)) * 12)
        var root = raw(ifd0Offset).filter { $0.tag != 65000 }
        let rootNext = reader.u32(ifd0Offset + 2 + Int(reader.u16(ifd0Offset)) * 12)
        if rawOffset == ifd0Offset {
            root = rawEntries
        } else {
            let newRaw = writeIFD(rawEntries, next: rawNext)
            let oldSubs = reader.ints(reader.entries(at: ifd0Offset)[330]).map { $0 == rawOffset ? newRaw : $0 }
            let subValue = array32(oldSubs.map(UInt32.init))
            root = root.filter { $0.tag != 330 } + [(330, 4, UInt32(oldSubs.count), subValue)]
        }
        let count = UInt32(markerBytes.count)
        root.append((65000, 2, count, count <= 4 ? Array(markerBytes) + Array(repeating: 0, count: 4 - markerBytes.count) : inline32(UInt32(markerOffset))))
        let newRoot = writeIFD(root, next: rootNext)
        patch32(4, UInt32(newRoot))
        try out.write(to: url, options: .atomic)
    }
}

enum LosslessJPEG {
    struct Huffman {
        var lookup = [UInt16](repeating: 0xFFFF, count: 1 << 16)
        init(counts: [Int], symbols: [UInt8]) {
            var code = 0, k = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    let shift = 16 - length
                    let first = code << shift, last = first + (1 << shift)
                    for v in first..<min(last, 1 << 16) { lookup[v] = UInt16(length) << 8 | UInt16(symbols[k]) }
                    code += 1; k += 1
                }
                code <<= 1
            }
        }
    }

    static func decode(_ bytes: Data) throws -> (samples: [UInt16], width: Int, height: Int) {
        let b = [UInt8](bytes)
        var p = 0
        var tables: [Int: Huffman] = [:]
        var precision = 16, width = 0, height = 0, comps = 1, predictor = 1, pointTransform = 0, restart = 0
        var compTables: [Int] = []
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { throw PipelineError.invalidDNG("lossless JPEG: no SOI") }
        p = 2
        while p + 4 <= b.count {
            guard b[p] == 0xFF else { p += 1; continue }
            let marker = b[p + 1]
            let len = u16(p + 2)
            let body = p + 4
            switch marker {
            case 0xC4:
                var q = body
                while q < p + 2 + len {
                    let id = Int(b[q] & 0x0F)
                    let counts = (0..<16).map { Int(b[q + 1 + $0]) }
                    let n = counts.reduce(0, +)
                    tables[id] = Huffman(counts: counts, symbols: Array(b[(q + 17)..<(q + 17 + n)]))
                    q += 17 + n
                }
            case 0xC3:
                precision = Int(b[body]); height = u16(body + 1); width = u16(body + 3); comps = Int(b[body + 5])
            case 0xDD:
                restart = u16(body)
            case 0xDA:
                let ns = Int(b[body])
                compTables = (0..<ns).map { Int(b[body + 2 + $0 * 2] >> 4) }
                predictor = Int(b[body + 1 + ns * 2])
                pointTransform = Int(b[body + 3 + ns * 2] & 0x0F)
                p = p + 2 + len
                return try scan(b, from: p, width: width, height: height, comps: comps, precision: precision, predictor: predictor,
                                pointTransform: pointTransform, restart: restart, tables: compTables.map { tables[$0] })
            case 0xD9: break
            default: break
            }
            p += 2 + len
        }
        throw PipelineError.invalidDNG("lossless JPEG: no scan")
    }

    private static func scan(_ b: [UInt8], from start: Int, width: Int, height: Int, comps: Int, precision: Int, predictor: Int,
                             pointTransform: Int, restart: Int, tables: [Huffman?]) throws -> (samples: [UInt16], width: Int, height: Int) {
        guard width > 0, height > 0, comps > 0, tables.count == comps, tables.allSatisfy({ $0 != nil }) else {
            throw PipelineError.invalidDNG("lossless JPEG: bad header")
        }
        let huff = tables.map { $0! }
        let rowLen = width * comps
        var out = [UInt16](repeating: 0, count: rowLen * height)
        var pos = start
        var bitBuf: UInt64 = 0, bitCount = 0
        func fill() {
            while bitCount <= 48 {
                var byte: UInt64 = 0
                if pos < b.count {
                    let v = b[pos]
                    if v == 0xFF {
                        let next = pos + 1 < b.count ? b[pos + 1] : 0
                        if next == 0x00 { byte = 0xFF; pos += 2 }
                        else { byte = 0 }
                    } else { byte = UInt64(v); pos += 1 }
                }
                bitBuf |= byte << UInt64(56 - bitCount)
                bitCount += 8
            }
        }
        func bits(_ n: Int) -> Int {
            if n == 0 { return 0 }
            if bitCount < n { fill() }
            let v = Int(bitBuf >> UInt64(64 - n))
            bitBuf <<= UInt64(n); bitCount -= n
            return v
        }
        func diff(_ t: Huffman) throws -> Int {
            if bitCount < 16 { fill() }
            let e = t.lookup[Int(bitBuf >> 48)]
            guard e != 0xFFFF else { throw PipelineError.invalidDNG("lossless JPEG: bad code") }
            let len = Int(e >> 8), s = Int(e & 0xFF)
            bitBuf <<= UInt64(len); bitCount -= len
            if s == 0 { return 0 }
            if s == 16 { return 32768 }
            let v = bits(s)
            return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
        }
        func resync() {
            bitBuf = 0; bitCount = 0
            while pos + 1 < b.count, !(b[pos] == 0xFF && (0xD0...0xD7).contains(b[pos + 1])) { pos += 1 }
            pos += 2
        }
        let initial = 1 << (precision - pointTransform - 1)
        let mask = (1 << precision) - 1
        var rowsSinceRestart = 0
        let restartRows = restart > 0 ? max(restart / width, 1) : Int.max
        try out.withUnsafeMutableBufferPointer { o in
            for y in 0..<height {
                if y > 0, restart > 0, rowsSinceRestart == restartRows { resync(); rowsSinceRestart = 0 }
                let firstRow = y == 0 || rowsSinceRestart == 0
                let row = y * rowLen
                for x in 0..<width {
                    for c in 0..<comps {
                        let i = row + x * comps + c
                        let pred: Int
                        if firstRow {
                            pred = x == 0 ? initial : Int(o[i - comps])
                        } else if x == 0 {
                            pred = Int(o[i - rowLen])
                        } else {
                            let a = Int(o[i - comps]), bb = Int(o[i - rowLen]), cc = Int(o[i - rowLen - comps])
                            switch predictor {
                            case 1: pred = a
                            case 2: pred = bb
                            case 3: pred = cc
                            case 4: pred = a + bb - cc
                            case 5: pred = a + ((bb - cc) >> 1)
                            case 6: pred = bb + ((a - cc) >> 1)
                            default: pred = (a + bb) >> 1
                            }
                        }
                        o[i] = UInt16((pred + (try diff(huff[c]))) & mask)
                    }
                }
                rowsSinceRestart += 1
            }
        }
        if pointTransform > 0 { for i in out.indices { out[i] <<= UInt16(pointTransform) } }
        return (out, rowLen, height)
    }

    static func encode(_ samples: [UInt16], width: Int, height: Int) -> Data {
        var diffs = [Int32](repeating: 0, count: samples.count)
        var freq = [Int](repeating: 0, count: 17)
        func category(_ d: Int) -> Int { d == 0 ? 0 : (d == 32768 || d == -32768 ? 16 : (Int.bitWidth - abs(d).leadingZeroBitCount)) }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let pred = y == 0 ? (x == 0 ? 32768 : Int(samples[i - 1])) : (x == 0 ? Int(samples[i - width]) : Int(samples[i - 1]))
                var d = (Int(samples[i]) - pred) & 0xFFFF
                if d >= 32768 { d -= 65536 }
                diffs[i] = Int32(d)
                freq[category(d)] += 1
            }
        }
        let lengths = codeLengths(freq)
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [UInt8] = []
        for len in 1...16 { for s in 0..<17 where lengths[s] == len { counts[len - 1] += 1; symbols.append(UInt8(s)) } }
        var codes = [Int](repeating: 0, count: 17)
        var code = 0, k = 0
        for len in 1...16 {
            for _ in 0..<counts[len - 1] { codes[Int(symbols[k])] = code; code += 1; k += 1 }
            code <<= 1
        }
        var out = Data([0xFF, 0xD8])
        func seg(_ marker: UInt8, _ body: [UInt8]) {
            out.append(contentsOf: [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)])
            out.append(contentsOf: body)
        }
        seg(0xC4, [0x00] + counts.map(UInt8.init) + symbols)
        seg(0xC3, [16, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 1, 1, 0x11, 0])
        seg(0xDA, [1, 1, 0x00, 1, 0, 0])
        var acc: UInt64 = 0, n = 0
        var body = [UInt8](); body.reserveCapacity(samples.count)
        func emit(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            acc = (acc << UInt64(bits)) | UInt64(value & ((1 << bits) - 1)); n += bits
            while n >= 8 {
                let byte = UInt8((acc >> UInt64(n - 8)) & 0xFF)
                body.append(byte); if byte == 0xFF { body.append(0) }
                n -= 8
            }
        }
        for d in diffs {
            let di = Int(d), s = category(di)
            emit(codes[s], lengths[s])
            if s > 0 && s < 16 { emit(di < 0 ? di + (1 << s) - 1 : di, s) }
        }
        if n > 0 { emit((1 << (8 - n)) - 1, 8 - n) }
        out.append(contentsOf: body)
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    private static func codeLengths(_ freq: [Int]) -> [Int] {
        var nodes: [(weight: Int, symbols: [Int])] = freq.enumerated().map { ($0.element + 1, [$0.offset]) }
        var lengths = [Int](repeating: 0, count: freq.count)
        while nodes.count > 1 {
            nodes.sort { $0.weight < $1.weight }
            let a = nodes.removeFirst(), b = nodes.removeFirst()
            for s in a.symbols + b.symbols { lengths[s] += 1 }
            nodes.append((a.weight + b.weight, a.symbols + b.symbols))
        }
        let deepest = lengths.indices.max { lengths[$0] < lengths[$1] }!
        lengths[deepest] += 1
        return lengths.max()! > 16 ? Array(repeating: 5, count: freq.count) : lengths
    }
}
