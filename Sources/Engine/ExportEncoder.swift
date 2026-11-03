// Crepuscule - ExportEncoder.swift
// Constantin Clerc (c22dev) - 0.1
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case jpeg, heic
    public var type: UTType { self == .heic ? .heic : .jpeg }
    public var fileExtension: String { self == .heic ? "heic" : "jpg" }
}

public enum ExportEncoder {
    static let exifAllowlist: [CFString] = [
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifOffsetTime, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
        kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifSubsecTimeDigitized,
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifShutterSpeedValue,
        kCGImagePropertyExifFNumber, kCGImagePropertyExifApertureValue,
        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifBrightnessValue,
        kCGImagePropertyExifExposureProgram, kCGImagePropertyExifExposureMode, kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifFlash, kCGImagePropertyExifSensingMethod, kCGImagePropertyExifSceneType,
        kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensSpecification,
    ]
    static let tiffAllowlist: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime]

    public static func metadata(from source: URL?, software: String) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        var props: [CFString: Any] = [:]
        if let source, let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let p = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
            props = p
        }
        if let gps = props[kCGImagePropertyGPSDictionary] { out[kCGImagePropertyGPSDictionary] = gps }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let kept = exif.filter { exifAllowlist.contains($0.key) }
            if !kept.isEmpty { out[kCGImagePropertyExifDictionary] = kept }
        }
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]).filter { tiffAllowlist.contains($0.key) }
        tiff[kCGImagePropertyTIFFSoftware] = software
        out[kCGImagePropertyTIFFDictionary] = tiff
        return out
    }

    public static func encode(_ image: CGImage, format: ExportFormat, quality: Float, metadata: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw PipelineError.encode
        }
        var options = metadata
        options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PipelineError.encode }
        return data as Data
    }
}
