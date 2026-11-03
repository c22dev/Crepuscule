// Crepuscule - AppSettings.swift
// Constantin Clerc (c22dev) - 0.1
import Foundation

public enum AspectRatioPreset: Int, Codable, CaseIterable, Sendable {
    case native, portrait, square, academy, stills35, hd, flat, scope, custom

    public func ratio(custom: (width: Double, height: Double) = (16, 9)) -> Double? {
        switch self {
        case .native: return nil
        case .portrait: return 0.8
        case .square: return 1
        case .academy: return 1.375
        case .stills35: return 1.5
        case .hd: return 16.0 / 9
        case .flat: return 1.85
        case .scope: return 2.39
        case .custom:
            guard custom.width > 0, custom.height > 0 else { return nil }
            return min(max(custom.width / custom.height, 0.1), 10)
        }
    }

    public func centeredCropInsets(imageWidth w: Double, imageHeight h: Double, custom: (width: Double, height: Double) = (16, 9)) -> CropInsets {
        guard let target = ratio(custom: custom), w > 0, h > 0 else { return CropInsets() }
        let current = w / h
        if target < current {
            let inset = (1 - target / current) / 2
            return CropInsets(left: inset, right: inset)
        }
        let inset = (1 - current / target) / 2
        return CropInsets(top: inset, bottom: inset)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case jpeg, heic }

    public var perImageDefaults = Grade()
    public var exportLongSide: Int? = 2880
    public var exportQuality: Float = 1
    public var exportFormat: Format = .heic
    public var autoExport = false
    public var saveRawsPermanently = true
    public var useDiskCache = true
    public var aspectRatioPreset = AspectRatioPreset.native
    public var customAspectWidth = 16.0
    public var customAspectHeight = 9.0
    public var highlightRetentionStops = 2.0

    public init() {}

    public static let exportSizeRange = 720...6144
    private static let key = "Crepuscule.AppSettings"

    public var exportFormatForEncoder: ExportFormat { exportFormat == .heic ? .heic : .jpeg }
    public mutating func setCustomExportSize(_ pixels: Int) {
        exportLongSide = min(max(pixels, Self.exportSizeRange.lowerBound), Self.exportSizeRange.upperBound)
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}
