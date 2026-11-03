// Crepuscule - LivePreview.swift
// Constantin Clerc (c22dev) - 0.1
import CoreImage
import CoreVideo
import Foundation
import Metal
import simd

public struct FrameStats: Equatable, Sendable {
    public var luma: [Float]
    public var nearClipFraction: Float, hardClipFraction: Float, shadowFraction: Float
    public var time: TimeInterval

    public static let bins = 48

    public init(luma: [Float] = Array(repeating: 0, count: FrameStats.bins), nearClipFraction: Float = 0, hardClipFraction: Float = 0, shadowFraction: Float = 0, time: TimeInterval = 0) {
        self.luma = luma; self.nearClipFraction = nearClipFraction; self.hardClipFraction = hardClipFraction
        self.shadowFraction = shadowFraction; self.time = time
    }

    public func hints(now: TimeInterval) -> BurstHints {
        BurstHints(nearClipFraction: nearClipFraction, hardClipFraction: hardClipFraction, shadowFraction: shadowFraction, sampleAgeSeconds: now - time)
    }

    public static func measure(bgra: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int, time: TimeInterval, stride step: Int = 8) -> FrameStats {
        var bins = [Float](repeating: 0, count: Self.bins)
        var near = 0, hard = 0, shadow = 0, count = 0
        let p = bgra.assumingMemoryBound(to: UInt8.self)
        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = p + y * rowBytes
            for x in Swift.stride(from: 0, to: width, by: step) {
                let b = Int(row[x * 4]), g = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
                let l = (r * 54 + g * 183 + b * 19) >> 8
                bins[min(l * Self.bins / 256, Self.bins - 1)] += 1
                let top = max(r, g, b)
                if top >= 254 { hard += 1 }
                if top >= 245 { near += 1 }
                if l < 16 { shadow += 1 }
                count += 1
            }
        }
        guard count > 0 else { return FrameStats(time: time) }
        let peak = max(bins.max() ?? 1, 1)
        let n = Float(count)
        return FrameStats(luma: bins.map { ($0 / peak).squareRoot() }, nearClipFraction: Float(near) / n, hardClipFraction: Float(hard) / n,
                          shadowFraction: Float(shadow) / n, time: time)
    }

    public static func measure(_ buffer: CVPixelBuffer, time: TimeInterval) -> FrameStats? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return measure(bgra: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                       rowBytes: CVPixelBufferGetBytesPerRow(buffer), time: time)
    }
}

public final class LiveGrader {
    private let renderer: ColorPipelineRenderer
    private let lut: MTLTexture
    private let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private var source: MTLTexture?

    static let rec709ToAWG: simd_float3x3 = {
        let awgToXYZ = simd_float3x3(rows: [SIMD3(0.638008, 0.214704, 0.097744), SIMD3(0.291954, 0.823841, -0.115795), SIMD3(0.002798, -0.067034, 1.153294)])
        let rec709ToXYZ = simd_float3x3(rows: [SIMD3(0.4124564, 0.3575761, 0.1804375), SIMD3(0.2126729, 0.7151522, 0.0721750), SIMD3(0.0193339, 0.1191920, 0.9503041)])
        return awgToXYZ.inverse * rec709ToXYZ
    }()

    public init(renderer: ColorPipelineRenderer, lut: MTLTexture) {
        self.renderer = renderer
        self.lut = lut
    }

    public static func previewGrade(from g: Grade) -> Grade {
        var out = g
        out.grainAmplitude = 0
        out.halation.enabled = false
        out.cropInsets = CropInsets()
        out.mirrored = false
        out.rotationQuarterTurns = 0
        out.fineRotationDegrees = 0
        return out
    }

    public func render(_ image: CIImage, grade g: Grade, baselineStops: Float = 0) throws -> MTLTexture {
        let bounds = image.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        if source?.width != w || source?.height != h { source = try renderer.texture(.rgba16Float, w, h) }
        guard let source, let cb = renderer.queue.makeCommandBuffer() else { throw PipelineError.texture }
        let m = Self.rec709ToAWG
        let f = CIFilter(name: "CIColorMatrix")!
        f.setValue(image.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(m[0][0]), y: CGFloat(m[1][0]), z: CGFloat(m[2][0]), w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: CGFloat(m[0][1]), y: CGFloat(m[1][1]), z: CGFloat(m[2][1]), w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: CGFloat(m[0][2]), y: CGFloat(m[1][2]), z: CGFloat(m[2][2]), w: 0), forKey: "inputBVector")
        guard let output = f.outputImage else { throw PipelineError.texture }
        renderer.ciContext.render(output, to: source, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: linear)
        cb.commit()
        return try renderer.grade(source, grade: Self.previewGrade(from: g), baselineStops: baselineStops, lut: lut, seed: 0)
    }

    public func render(_ buffer: CVPixelBuffer, grade g: Grade, baselineStops: Float = 0) throws -> MTLTexture {
        try render(CIImage(cvPixelBuffer: buffer), grade: g, baselineStops: baselineStops)
    }
}
