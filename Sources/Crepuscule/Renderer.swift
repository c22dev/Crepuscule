// Crepuscule - Renderer.swift
// Constantin Clerc (c22dev) - 0.1
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum PipelineError: Error, CustomStringConvertible {
    case invalidDNG(String), noDevice, shader(String), texture, decode(String), lut(String), encode, gpu(String)
    public var description: String {
        switch self {
        case .invalidDNG(let s): return "invalid DNG: \(s)"
        case .noDevice: return "no Metal device"
        case .shader(let s): return "shader: \(s)"
        case .texture: return "could not allocate texture"
        case .gpu(let s): return "GPU work failed: \(s)"
        case .decode(let s): return "decode: \(s)"
        case .lut(let s): return "LUT: \(s)"
        case .encode: return "could not encode output"
        }
    }
}

public struct LightWrapParams { public var redSens, redIntens, colorR, colorG, colorB: Float }
public struct ShoulderToeParams { public var highlights, shadows, highlightsFalloff, shadowsFalloff: Float; public var enabled: UInt32 }
struct EdgeBlurParams { var normSens, gradientStride: Float }
struct AtanContrastParams { var contrast, pivot: Float }
struct PreExposureParams { var redGain, greenGain, blueGain, saturation: Float }
struct PostHalationParams { var grainAmplitude: Float; var blackAndWhite: UInt32 }
struct FusedGradeParams { var redGain, greenGain, blueGain, saturation, grainAmplitude: Float; var blackAndWhite: UInt32 }
struct RawUnpackParams { var srcWidth, srcHeight, dstWidth, dstHeight: UInt32; var parameterB, parameterC: Float }

public struct DecodedRaw {
    public let rgb16: Data
    public let width, height: Int
    public let baselineExposureStops: Float
}

public final class ColorPipelineRenderer {
    public var appleVignetteAmount: Double = 1
    public let device: MTLDevice
    let queue: MTLCommandQueue
    public let library: MTLLibrary
    let ciContext: CIContext
    private var psos: [String: MTLComputePipelineState] = [:]
    private var bakedLUT: (base: ObjectIdentifier, contrast: Float, pivot: Float, texture: MTLTexture)?
    private var zeroPlate: MTLTexture?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), library: MTLLibrary? = nil) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw PipelineError.noDevice }
        self.device = device
        self.queue = queue
        if let library {
            self.library = library
        } else {
            guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
                throw PipelineError.shader("Shaders.metal missing from bundle")
            }
            let options = MTLCompileOptions()
            options.languageVersion = .version3_1
            self.library = try device.makeLibrary(source: String(contentsOf: url), options: options)
        }
        ciContext = CIContext(mtlDevice: device)
    }

    func pso(_ name: String) throws -> MTLComputePipelineState {
        if let p = psos[name] { return p }
        guard let f = library.makeFunction(name: name) else { throw PipelineError.shader("missing \(name)") }
        let p = try device.makeComputePipelineState(function: f)
        psos[name] = p
        return p
    }

    func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw PipelineError.texture }
        return t
    }

    func dispatch(_ cb: MTLCommandBuffer, _ name: String, _ w: Int, _ h: Int, _ configure: (MTLComputeCommandEncoder) -> Void) throws {
        guard let e = cb.makeComputeCommandEncoder() else { throw PipelineError.texture }
        e.setComputePipelineState(try pso(name))
        configure(e)
        e.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
    }

    public func decode(url: URL, metadata: DNGMetadata? = nil, noiseReductionOff: Bool = false, fullQuality: Bool = true) throws -> DecodedRaw {
        let meta = try metadata ?? DNGMetadata(url: url)
        let filter: CIRAWFilter?
        if appleVignetteAmount == 1 {
            filter = CIRAWFilter(imageURL: url)
        } else {
            let patched = DNGFile.scalingVignette(in: try Data(contentsOf: url), by: appleVignetteAmount)
            filter = CIRAWFilter(imageData: patched, identifierHint: "com.adobe.raw-image")
        }
        guard let f = filter else { throw PipelineError.decode("CIRAWFilter could not open the file") }
        f.baselineExposure = 0
        f.exposure = 0
        f.boostAmount = 0
        f.isGamutMappingEnabled = false
        f.isDraftModeEnabled = !fullQuality
        f.scaleFactor = fullQuality ? 1 : 0.25
        if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = true }
        if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        f.extendedDynamicRangeAmount = 0
        f.shadowBias = 0
        f.sharpnessAmount = 0
        f.detailAmount = 0
        if f.isMoireReductionSupported { f.moireReductionAmount = 0 }
        if noiseReductionOff {
            f.luminanceNoiseReductionAmount = 0
            f.colorNoiseReductionAmount = 0
        }
        if !fullQuality { f.colorNoiseReductionAmount = 0 }
        guard let image = f.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else {
            throw PipelineError.decode("no output image")
        }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let mosaicStop: Float = meta.isMosaic ? 1 : 0
        let scale = powf(2, -mosaicStop)
        let m = linearSRGBToCameraSpace(meta).map { CGFloat($0 * scale) }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
        matrix.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
        matrix.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = matrix.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let output = clamp.outputImage else { throw PipelineError.decode("colour clamp failed") }
        let bounds = image.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear,
                                          .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue), .cacheIntermediates: false])
        var rgba = [UInt16](repeating: 0, count: w * h * 4)
        context.render(output, toBitmap: &rgba, rowBytes: w * 8, bounds: bounds, format: .RGBA16, colorSpace: linear)
        var rgb = Data(count: w * h * 6)
        rgb.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<(w * h) {
                p[i * 3] = rgba[i * 4]; p[i * 3 + 1] = rgba[i * 4 + 1]; p[i * 3 + 2] = rgba[i * 4 + 2]
            }
        }
        return DecodedRaw(rgb16: rgb, width: w, height: h, baselineExposureStops: mosaicStop + meta.baselineExposureStops)
    }

    public func upload(_ raw: DecodedRaw, maxDimension: Int? = nil) throws -> MTLTexture {
        let longest = max(raw.width, raw.height)
        let ratio = Double(maxDimension ?? longest) / Double(longest)
        let dw = ratio < 1 ? max(Int(ratio * Double(raw.width)), 1) : raw.width
        let dh = ratio < 1 ? max(Int(ratio * Double(raw.height)), 1) : raw.height
        let dst = try texture(.rgba16Float, dw, dh)
        var params = RawUnpackParams(srcWidth: UInt32(raw.width), srcHeight: UInt32(raw.height), dstWidth: UInt32(dw), dstHeight: UInt32(dh),
                                     parameterB: Float(bitPattern: 0x3ea8f5c3), parameterC: Float(bitPattern: 0x3ea8f5c3))
        guard let buffer = raw.rgb16.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        if dw != raw.width || dh != raw.height {
            let mid = try texture(.rgba16Float, dw, raw.height)
            try dispatch(cb, "cubicResizeHorizontalFromRGB16", dw, raw.height) { e in
                e.setBuffer(buffer, offset: 0, index: 0)
                e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 1)
                e.setTexture(mid, index: 0)
            }
            try dispatch(cb, "cubicResizeVerticalToRGBA16Float", dw, dh) { e in
                e.setTexture(mid, index: 0)
                e.setTexture(dst, index: 1)
                e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 0)
            }
        } else {
            try dispatch(cb, "unpackRGB16UIntToRGBA16Float", dw, dh) { e in
                e.setBuffer(buffer, offset: 0, index: 0)
                e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 1)
                e.setTexture(dst, index: 0)
            }
        }
        cb.commit()
        try cb.finish()
        return dst
    }

    public func uploadPacked(_ raw: DecodedRaw, maxDimension: Int) throws -> (data: Data, width: Int, height: Int) {
        let longest = max(raw.width, raw.height)
        let ratio = Double(maxDimension) / Double(longest)
        guard ratio < 1 else { return (raw.rgb16, raw.width, raw.height) }
        let dw = max(Int(ratio * Double(raw.width)), 1), dh = max(Int(ratio * Double(raw.height)), 1)
        var params = RawUnpackParams(srcWidth: UInt32(raw.width), srcHeight: UInt32(raw.height), dstWidth: UInt32(dw), dstHeight: UInt32(dh),
                                     parameterB: Float(bitPattern: 0x3ea8f5c3), parameterC: Float(bitPattern: 0x3ea8f5c3))
        guard let buffer = raw.rgb16.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let out = device.makeBuffer(length: dw * dh * 6, options: .storageModeShared),
              let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        let mid = try texture(.rgba16Float, dw, raw.height)
        try dispatch(cb, "cubicResizeHorizontalFromRGB16", dw, raw.height) { e in
            e.setBuffer(buffer, offset: 0, index: 0)
            e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 1)
            e.setTexture(mid, index: 0)
        }
        try dispatch(cb, "cubicResizeVerticalToRGB16Packed", dw, dh) { e in
            e.setTexture(mid, index: 0)
            e.setBuffer(out, offset: 0, index: 0)
            e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 1)
        }
        cb.commit()
        try cb.finish()
        return (Data(bytes: out.contents(), count: dw * dh * 6), dw, dh)
    }

    public func unpack(_ packed: Data, width: Int, height: Int) throws -> MTLTexture {
        let dst = try texture(.rgba16Float, width, height)
        var params = RawUnpackParams(srcWidth: UInt32(width), srcHeight: UInt32(height), dstWidth: UInt32(width), dstHeight: UInt32(height), parameterB: 0, parameterC: 0)
        guard packed.count >= width * height * 6,
              let buffer = packed.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: width * height * 6) }),
              let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        try dispatch(cb, "unpackRGB16UIntToRGBA16Float", width, height) { e in
            e.setBuffer(buffer, offset: 0, index: 0)
            e.setBytes(&params, length: MemoryLayout<RawUnpackParams>.size, index: 1)
            e.setTexture(dst, index: 0)
        }
        cb.commit()
        try cb.finish()
        return dst
    }

    static func inscribed(_ w: Double, _ h: Double, _ angle: Double) -> (Double, Double) {
        guard w > 0, h > 0 else { return (0, 0) }
        let long = max(w, h), short = min(w, h)
        let s = abs(sin(angle)), c = abs(cos(angle))
        if short <= long * s * c * 2 || abs(s - c) < 1e-10 {
            let half = short * 0.5
            return w < h ? (half / c, half / s) : (half / s, half / c)
        }
        let d = c * c - s * s
        return ((w * c - h * s) / d, (h * c - w * s) / d)
    }

    public func applyGeometry(_ source: MTLTexture, grade: Grade, longSide: Int? = nil) throws -> MTLTexture {
        let turns = ((grade.rotationQuarterTurns % 4) + 4) % 4
        let c = grade.cropInsets
        if longSide == nil, !grade.mirrored, turns == 0, abs(grade.fineRotationDegrees) <= 0.001, c == CropInsets() { return source }
        let rgb = CGColorSpaceCreateDeviceRGB()
        guard var image = CIImage(mtlTexture: source, options: [.colorSpace: rgb]) else { throw PipelineError.texture }
        var w = Double(source.width), h = Double(source.height)
        if grade.mirrored { image = image.oriented(.upMirrored) }
        if turns != 0 {
            image = image.oriented(turns == 1 ? .left : turns == 2 ? .down : .right)
            if turns != 2 { swap(&w, &h) }
        }
        var iw = w, ih = h
        if abs(grade.fineRotationDegrees) > 0.001 {
            let radians = grade.fineRotationDegrees * .pi / 180
            let t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
                .concatenating(CGAffineTransform(rotationAngle: radians))
                .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
            image = image.transformed(by: t)
            (iw, ih) = Self.inscribed(w, h, abs(radians))
        }
        let rect = CGRect(x: c.left * iw + (w - iw) * 0.5, y: c.top * ih + (h - ih) * 0.5,
                          width: iw - c.left * iw - c.right * iw, height: ih - c.top * ih - c.bottom * ih).integral
        guard rect.width > 0, rect.height > 0 else { throw PipelineError.texture }
        image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let out = try texture(.rgba16Float, Int(rect.width), Int(rect.height))
        guard let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        ciContext.render(image, to: out, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), colorSpace: rgb)
        cb.commit()
        try cb.finish()
        guard let longSide, longSide > 0, longSide < max(out.width, out.height) else { return out }
        return try resizeInLogC(out, longSide: longSide)
    }

    private func resizeInLogC(_ crop: MTLTexture, longSide: Int) throws -> MTLTexture {
        let cropW = Double(crop.width), cropH = Double(crop.height)
        let outW: Int, outH: Int
        if cropH <= cropW {
            outW = longSide; outH = max(Int(cropH * Double(longSide) / cropW), 1)
        } else {
            outH = longSide; outW = max(Int(cropW * Double(longSide) / cropH), 1)
        }
        let rgb = CGColorSpaceCreateDeviceRGB()
        let encoded = try texture(.rgba16Float, crop.width, crop.height)
        let scaled = try texture(.rgba16Float, outW, outH)
        let out = try texture(.rgba16Float, outW, outH)
        guard let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        try dispatch(cb, "encodeLogCUnclamped", crop.width, crop.height) { e in
            e.setTexture(crop, index: 0); e.setTexture(encoded, index: 1)
        }
        cb.commit(); try cb.finish()
        guard let input = CIImage(mtlTexture: encoded, options: [.colorSpace: rgb]) else { throw PipelineError.texture }
        let f = CIFilter.bicubicScaleTransform()
        f.inputImage = input
        f.scale = Float(Double(outH) / cropH)
        f.aspectRatio = Float(cropH * Double(outW) / (cropW * Double(outH)))
        f.parameterB = Float(bitPattern: 0x3ea8f5c3)
        f.parameterC = Float(bitPattern: 0x3ea8f5c3)
        guard let output = f.outputImage, let cb2 = queue.makeCommandBuffer() else { throw PipelineError.texture }
        ciContext.render(output, to: scaled, commandBuffer: cb2, bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: rgb)
        try dispatch(cb2, "decodeLogCUnclamped", outW, outH) { e in
            e.setTexture(scaled, index: 0); e.setTexture(out, index: 1)
        }
        cb2.commit(); try cb2.finish()
        return out
    }

    public func loadCube(url: URL) throws -> MTLTexture {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                guard let s = line.split(separator: " ").last.flatMap({ Int($0) }) else { throw PipelineError.lut("Malformed LUT_3D_SIZE") }
                size = s
                values.reserveCapacity(size * size * size * 4)
                continue
            }
            let p = line.split(separator: " ")
            if p.count == 3, let r = Float(p[0]), let g = Float(p[1]), let b = Float(p[2]) {
                values.append(contentsOf: [r, g, b, 1])
            }
        }
        guard size > 0, values.count == size * size * size * 4 else { throw PipelineError.lut("LUT data does not match declared size") }
        let t = try lutTexture(size)
        t.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: values, bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        return t
    }

    private func lutTexture(_ size: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba32Float
        d.width = size; d.height = size; d.depth = size
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw PipelineError.texture }
        return t
    }

    public func bakeContrast(_ lut: MTLTexture, contrast: Float, pivot: Float) throws -> MTLTexture {
        let out = try lutTexture(lut.width)
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw PipelineError.texture }
        e.setComputePipelineState(try pso("bakeAtanContrastIntoLUT"))
        e.setTexture(lut, index: 0)
        e.setTexture(out, index: 1)
        // pivot 1 does 0/0 on white (original does it too)
        var p = AtanContrastParams(contrast: contrast, pivot: min(pivot, 0.999))
        e.setBytes(&p, length: 8, index: 0)
        let g = (lut.width + 7) / 8
        e.dispatchThreadgroups(MTLSize(width: g, height: g, depth: g), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 8))
        e.endEncoding()
        cb.commit()
        try cb.finish()
        return out
    }

    private func cachedBakedLUT(_ lut: MTLTexture, contrast: Float, pivot: Float) throws -> MTLTexture {
        let id = ObjectIdentifier(lut)
        if let b = bakedLUT, b.base == id, b.contrast == contrast, b.pivot == pivot { return b.texture }
        let t = try bakeContrast(lut, contrast: contrast, pivot: pivot)
        bakedLUT = (id, contrast, pivot, t)
        return t
    }

    private func zeroGrainPlate(_ w: Int, _ h: Int) throws -> MTLTexture {
        if let z = zeroPlate, z.width == w, z.height == h { return z }
        let t = try texture(.r16Float, w, h, usage: [.shaderRead])
        let zeros = [UInt8](repeating: 0, count: w * h * 2)
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: zeros, bytesPerRow: w * 2)
        zeroPlate = t
        return t
    }

    public func makeGrainPlate(grainSize: Float, cropScale: Float, seed: Float, width: Int, height: Int, referenceWidth: Int? = nil, pixelSize: Bool) throws -> MTLTexture {
        let w = max(width, 1), h = max(height, 1)
        let reference = max(referenceWidth ?? w, w)
        var seedValue = seed
        if pixelSize {
            let plate = try texture(.r16Float, w, h)
            var comp: Float = 1
            guard let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
            try dispatch(cb, "generateClassicGrainPlatePixelSize", w, h) { e in
                e.setTexture(plate, index: 0)
                e.setBytes(&seedValue, length: 4, index: 0)
                e.setBytes(&comp, length: 4, index: 1)
            }
            cb.commit()
            try cb.finish()
            return plate
        }
        let area = max(Double(grainSize) * Double(cropScale), 0.0001)
        let gridWidth = max(Int((1 / area) * 3686), 1)
        let scaled = Int(Double(w) * Double(gridWidth) / Double(reference))
        var coarseW = max(scaled, 1)
        var comp: Float = 1
        if w < scaled {
            comp = Float(sqrt(Double(w) / Double(coarseW)))
            coarseW = w
        }
        let coarseH = max(Int(Double(coarseW) * Double(h) / Double(w)), 1)
        let coarse = try texture(.r16Float, coarseW, coarseH)
        let plate = try texture(.r16Float, w, h)
        guard let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }
        try dispatch(cb, "generateClassicGrainPlateCoarse", coarseW, coarseH) { e in
            e.setTexture(coarse, index: 0)
            e.setBytes(&seedValue, length: 4, index: 0)
            e.setBytes(&comp, length: 4, index: 1)
        }
        let rgb = CGColorSpaceCreateDeviceRGB()
        guard let input = CIImage(mtlTexture: coarse, options: [.colorSpace: rgb]) else { throw PipelineError.texture }
        let up = CIFilter.lanczosScaleTransform()
        up.inputImage = input
        up.scale = 2
        up.aspectRatio = 1
        let down = CIFilter.lanczosScaleTransform()
        down.inputImage = up.outputImage
        let doubledH = Double(coarseH) * 2, doubledW = Double(coarseW) * 2
        down.scale = Float(Double(h) / doubledH)
        down.aspectRatio = Float(doubledH * Double(w) / (doubledW * Double(h)))
        guard let output = down.outputImage else { throw PipelineError.texture }
        ciContext.render(output, to: plate, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: rgb)
        cb.commit()
        try cb.finish()
        return plate
    }

    public func grade(_ source: MTLTexture, grade: Grade, baselineStops: Float, lut baseLUT: MTLTexture, seed: Float? = nil, referenceWidth: Int? = nil, cropScale: Float? = nil) throws -> MTLTexture {
        let w = source.width, h = source.height
        let lut = try cachedBakedLUT(baseLUT, contrast: grade.atanContrast, pivot: grade.atanPivot)
        let final = try texture(.rgba8Unorm, w, h, usage: [.shaderWrite, .shaderRead])
        let gain = exp2f(grade.exposureStops + baselineStops)
        let wb = WhiteBalance.gains(colorTemp: grade.colorTemp, tint: grade.tint)
        let scale = cropScale ?? Float(sqrt(max(grade.cropInsets.areaFraction, 0.0001)))
        let plate: MTLTexture
        if grade.grainAmplitude == 0 {
            plate = try zeroGrainPlate(w, h)
        } else {
            plate = try makeGrainPlate(grainSize: grade.grainSize, cropScale: scale, seed: seed ?? Float.random(in: 0..<1_000_000),
                                       width: w, height: h, referenceWidth: referenceWidth, pixelSize: grade.pixSizeGrain)
        }
        var tone = shoulderToeParams(highlights: grade.highlights, shadows: grade.shadows)
        let bw: UInt32 = grade.blackAndWhite ? 1 : 0
        let red = gain * (wb.red / wb.green), green = gain, blue = (wb.blue / wb.green) * gain
        guard let cb = queue.makeCommandBuffer() else { throw PipelineError.texture }

        guard grade.halation.enabled else {
            var p = FusedGradeParams(redGain: red, greenGain: green, blueGain: blue, saturation: grade.saturation, grainAmplitude: grade.grainAmplitude, blackAndWhite: bw)
            try dispatch(cb, "gradeFusedNoHalation", w, h) { e in
                e.setTexture(source, index: 0); e.setTexture(final, index: 1); e.setTexture(plate, index: 2); e.setTexture(lut, index: 3)
                e.setBytes(&p, length: 24, index: 0)
                e.setBytes(&tone, length: 20, index: 1)
            }
            cb.commit(); try cb.finish()
            return final
        }

        let t0 = try texture(.rgba16Float, w, h), t1 = try texture(.rgba16Float, w, h)
        let t2 = try texture(.rgba16Float, w, h), t3 = try texture(.rgba16Float, w, h)
        var pre = PreExposureParams(redGain: red, greenGain: green, blueGain: blue, saturation: grade.saturation)
        try dispatch(cb, "preHalationExposureLogC", w, h) { e in
            e.setTexture(source, index: 0); e.setTexture(t0, index: 1)
            e.setBytes(&pre, length: 16, index: 0)
            e.setBytes(&tone, length: 20, index: 1)
        }
        var wrap = grade.halation.preset.lightWrap
        try dispatch(cb, "lightWrapTintMask", w, h) { e in
            e.setTexture(t0, index: 0); e.setTexture(t1, index: 1)
            e.setBytes(&wrap, length: 20, index: 0)
        }
        let basis = Float(referenceWidth ?? w)
        var radius = basis * 10 * 0.00048828125
        func blur(_ name: String, _ a: MTLTexture, _ b: MTLTexture) throws {
            try dispatch(cb, name, w, h) { e in
                e.setTexture(a, index: 0); e.setTexture(b, index: 1)
                e.setBytes(&radius, length: 4, index: 0)
            }
        }
        try blur("coneBlurSeparableHorizontal", t1, t3)
        try blur("coneBlurSeparableVertical", t3, t2)
        try dispatch(cb, "lightWrapComposite", w, h) { e in
            e.setTexture(t0, index: 0); e.setTexture(t1, index: 1); e.setTexture(t2, index: 2); e.setTexture(t3, index: 3)
        }
        try blur("coneBlurSeparableHorizontal", t3, t0)
        try blur("coneBlurSeparableVertical", t0, t1)
        var edge = EdgeBlurParams(normSens: 1.5, gradientStride: basis / 2048)
        try dispatch(cb, "edgeBlurComposite", w, h) { e in
            e.setTexture(t3, index: 0); e.setTexture(t1, index: 1); e.setTexture(t2, index: 2)
            e.setBytes(&edge, length: 8, index: 0)
        }
        var post = PostHalationParams(grainAmplitude: grade.grainAmplitude, blackAndWhite: bw)
        try dispatch(cb, "postHalationLUTGrainFinal", w, h) { e in
            e.setTexture(t2, index: 0); e.setTexture(final, index: 1); e.setTexture(plate, index: 2); e.setTexture(lut, index: 3)
            e.setBytes(&post, length: 8, index: 0)
        }
        cb.commit(); try cb.finish()
        return final
    }

    public func render(dng url: URL, grade g: Grade, lut: MTLTexture, seed: Float? = nil, maxDimension: Int? = nil, exportLongSide: Int? = nil) throws -> CGImage {
        let meta = try DNGMetadata(url: url)
        let raw = try decode(url: url, metadata: meta)
        let base = try upload(raw, maxDimension: maxDimension)
        let cropped = try applyGeometry(base, grade: g, longSide: exportLongSide)
        return try cgImage(try grade(cropped, grade: g, baselineStops: raw.baselineExposureStops, lut: lut, seed: seed,
                                     referenceWidth: exportLongSide == nil ? nil : base.width))
    }

    public func cgImage(_ t: MTLTexture) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: t.width, height: t.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: t.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PipelineError.encode }
        return image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw PipelineError.encode }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw PipelineError.encode }
    }
}

extension MTLCommandBuffer {
    func finish() throws {
        waitUntilCompleted()
        guard status == .completed else { throw PipelineError.gpu(error.map { "\($0)" } ?? "status \(status.rawValue)") }
    }
}
