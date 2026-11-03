// Crepuscule - GPUAccumulator.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation
import Metal

// any failure (no device, app in the background) throws and callers redo it on the cpu
final class GPUAccumulator: @unchecked Sendable {
    nonisolated(unsafe) static var enabled = true
    private static let instance: GPUAccumulator? = try? GPUAccumulator()
    static var shared: GPUAccumulator? { enabled ? instance : nil }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let mergePSO: MTLComputePipelineState
    let superResPSO: MTLComputePipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw PipelineError.noDevice }
        guard let url = Bundle.module.url(forResource: "Accumulate", withExtension: "metal") else {
            throw PipelineError.shader("Accumulate.metal missing from bundle")
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        // no fast math or it stops matching the cpu
        if #available(macOS 15, iOS 18, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: options)
        func pso(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw PipelineError.shader("missing \(name)") }
            return try device.makeComputePipelineState(function: f)
        }
        self.device = device
        self.queue = queue
        mergePSO = try pso("mergeAccumulate")
        superResPSO = try pso("superResAccumulate")
    }

    func buffer<T>(_ a: [T]) throws -> MTLBuffer {
        guard !a.isEmpty else { return try zeroed(16) }
        let b = a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let b else { throw PipelineError.gpu("could not allocate \(a.count * MemoryLayout<T>.stride) bytes") }
        return b
    }

    func zeroed(_ bytes: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) else { throw PipelineError.gpu("could not allocate \(bytes) bytes") }
        memset(b.contents(), 0, b.length)
        return b
    }

    func encode(_ pso: MTLComputePipelineState, width: Int, height: Int, _ configure: (MTLComputeCommandEncoder) -> Void) throws -> MTLCommandBuffer {
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw PipelineError.gpu("no command buffer") }
        e.setComputePipelineState(pso)
        configure(e)
        let tw = pso.threadExecutionWidth, th = max(pso.maxTotalThreadsPerThreadgroup / tw / 2, 1)
        e.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        e.endEncoding()
        cb.commit()
        return cb
    }

    static func check(_ cb: MTLCommandBuffer) throws {
        cb.waitUntilCompleted()
        guard cb.status == .completed else { throw PipelineError.gpu(cb.error.map { "\($0)" } ?? "status \(cb.status.rawValue)") }
    }
}

public enum ShaderWarmup {
    public static func mergeKernels() { _ = GPUAccumulator.shared }
}

struct MergeAccParams {
    var W, H: UInt32
    var cols, rows: Int32
    var confWidth, same, hasGhost: UInt32
    var baseBlack, altBlack, range, altRange, scale, noiseA, noiseB, minVar: Float
}

extension BurstMerger {
    final class GPUMerge {
        let gpu: GPUAccumulator
        let base: BurstFrame
        let weight: MTLBuffer, value: MTLBuffer
        let baseData: MTLBuffer, conf: MTLBuffer, table: MTLBuffer
        let confWidth: Int
        var pending: [MTLCommandBuffer] = []

        init(gpu: GPUAccumulator, base: BurstFrame, confidence c: Plane) throws {
            self.gpu = gpu
            self.base = base
            let n = base.cfa.width * base.cfa.height * MemoryLayout<Float>.stride
            weight = try gpu.zeroed(n); value = try gpu.zeroed(n)
            baseData = try gpu.buffer(base.cfa.data)
            conf = try gpu.buffer(c.v); confWidth = c.width
            table = try gpu.buffer(expTable)
        }

        func accumulate(alt: BurstFrame, alignment al: Alignment, weights tw: [Float], noise: Noise, ghost: [Float]?) throws {
            let range = base.range, unit = range / 4095
            var p = MergeAccParams(W: UInt32(base.cfa.width), H: UInt32(base.cfa.height), cols: Int32(al.cols), rows: Int32(al.rows),
                                   confWidth: UInt32(confWidth), same: alt.isSameExposure ? 1 : 0, hasGhost: ghost == nil ? 0 : 1,
                                   baseBlack: base.cfa.black, altBlack: alt.cfa.black, range: range, altRange: alt.range,
                                   scale: alt.scale, noiseA: noise.a, noiseB: noise.b, minVar: max(unit * unit, noise.b))
            let altData = try gpu.buffer(alt.cfa.data)
            let offsets = try gpu.buffer(al.offsets.map { SIMD2<Int32>(Int32($0.dx), Int32($0.dy)) })
            let weights = try gpu.buffer(tw)
            let ghostBuffer = try ghost.map { try gpu.buffer($0) } ?? gpu.zeroed(16)
            pending.append(try gpu.encode(gpu.mergePSO, width: base.cfa.width, height: base.cfa.height) { e in
                for (i, b) in [baseData, altData, conf, offsets, weights, ghostBuffer, table, weight, value].enumerated() {
                    e.setBuffer(b, offset: 0, index: i)
                }
                e.setBytes(&p, length: MemoryLayout<MergeAccParams>.stride, index: 9)
            })
        }

        func finish() throws -> (weight: UnsafeBufferPointer<Float>, value: UnsafeBufferPointer<Float>) {
            for cb in pending { try GPUAccumulator.check(cb) }
            pending.removeAll()
            let n = base.cfa.width * base.cfa.height
            return (UnsafeBufferPointer(start: weight.contents().assumingMemoryBound(to: Float.self), count: n),
                    UnsafeBufferPointer(start: value.contents().assumingMemoryBound(to: Float.self), count: n))
        }
    }
}

struct SRParams {
    var OW, OH, ww, wh, cols, cbw, frames: UInt32
    var p0, p1, p2, p3: Int32
    var minW, scaleOut: Float
}

struct SRFrame { var dataOffset, gridOffset: UInt32; var robustOffset: Int32; var black: Float }
struct SRLerp { var t0, t1: Int32; var w: Float }

extension SuperResolution {
    static func accumulateGPU(_ gpu: GPUAccumulator, states: [FrameState], cols: Int, rows: Int, plan: Plan, pattern: [Int],
                              windowWidth ww: Int, windowHeight wh: Int, range: Float, kernels: [Float],
                              options: Options) throws -> (rgb: [UInt16], coverage: Float) {
        let OW = plan.outWidth, OH = plan.outHeight
        let sx = plan.sx, sy = plan.sy
        let cx = Float(plan.cx), cy = Float(plan.cy)
        let cbx = plan.cx / 2, cby = plan.cy / 2, cbw = plan.crop.width / 2, cbh = plan.crop.height / 2
        let px = (0..<OW).map { cx + (Float($0) + 0.5) / sx - 0.5 }
        let py = (0..<OH).map { cy + (Float($0) + 0.5) / sy - 0.5 }
        let bxs = px.map { Int32(min(max(Int(floor(($0 + 0.5) / 2)) - cbx, 0), cbw - 1)) }
        let bys = py.map { Int32(min(max(Int(floor(($0 + 0.5) / 2)) - cby, 0), cbh - 1)) }
        let lerp = { (p: Float, n: Int) -> SRLerp in let (a, b, w) = tileLerp(p, n); return SRLerp(t0: Int32(a), t1: Int32(b), w: w) }
        let colLerp = px.map { lerp($0, cols) }, rowLerp = py.map { lerp($0, rows) }

        let frameSize = ww * wh, grid = cols * rows, robustSize = cbw * cbh
        guard states.allSatisfy({ $0.data.count == frameSize && $0.fx.count == grid && $0.fy.count == grid && ($0.robust?.count ?? robustSize) == robustSize }),
              pattern.count == 4 else { throw PipelineError.gpu("inconsistent frame sizes") }
        guard let data = gpu.device.makeBuffer(length: frameSize * states.count * 2, options: .storageModeShared) else {
            throw PipelineError.gpu("could not allocate frame data")
        }
        var fxs: [Float] = [], fys: [Float] = [], robusts: [Float] = [], descriptors: [SRFrame] = []
        for (n, st) in states.enumerated() {
            st.data.withUnsafeBytes { (data.contents() + n * frameSize * 2).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            var robustOffset: Int32 = -1
            if let r = st.robust { robustOffset = Int32(robusts.count); robusts += r }
            descriptors.append(SRFrame(dataOffset: UInt32(n * frameSize), gridOffset: UInt32(fxs.count), robustOffset: robustOffset, black: st.black))
            fxs += st.fx; fys += st.fy
        }
        let out = try gpu.zeroed(OW * OH * 3 * 2), covered = try gpu.zeroed(4)
        var p = SRParams(OW: UInt32(OW), OH: UInt32(OH), ww: UInt32(ww), wh: UInt32(wh), cols: UInt32(cols), cbw: UInt32(cbw),
                         frames: UInt32(states.count), p0: Int32(pattern[0]), p1: Int32(pattern[1]), p2: Int32(pattern[2]), p3: Int32(pattern[3]),
                         minW: options.minWeight, scaleOut: 65535 / range)
        let buffers = try [data, gpu.buffer(descriptors), gpu.buffer(fxs), gpu.buffer(fys), gpu.buffer(robusts), gpu.buffer(kernels),
                           gpu.buffer(kernelTable), gpu.buffer(px), gpu.buffer(py), gpu.buffer(bxs), gpu.buffer(bys),
                           gpu.buffer(colLerp), gpu.buffer(rowLerp), out, covered]
        let cb = try gpu.encode(gpu.superResPSO, width: OW, height: OH) { e in
            for (i, b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i) }
            e.setBytes(&p, length: MemoryLayout<SRParams>.stride, index: 15)
        }
        try GPUAccumulator.check(cb)
        let rgb = Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: UInt16.self), count: OW * OH * 3))
        let n = covered.contents().load(as: UInt32.self)
        return (rgb, Float(n) / Float(max(OW * OH, 1)))
    }
}
