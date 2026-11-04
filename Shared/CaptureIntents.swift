// Crepuscule - CaptureIntents.swift
// Constantin Clerc (c22dev) - 0.1
import AppIntents
import Foundation

// lock screen cant read app data so looks go as Grade json, also built into the widget (no Crepuscule)
struct LockedCaptureContext: Codable, Sendable {
    struct Look: Codable, Sendable { var name: String; var grade: Data }

    var stack = true
    var muteShutter = false
    var shutterLimit = 0
    var nightBursts = true
    var mirrorFront = false
    var highlightRetentionStops = 2.0
    var bracketMetering: String?
    var aspect: Int?
    var look: Data?
    var looks: [Look] = []
    var showGrid = false
    var showLook = false
    var scanCodes = false
    var defaultLens = 0
    var lensReadout: String?
    var vignette = 1.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stack = try c.decodeIfPresent(Bool.self, forKey: .stack) ?? true
        muteShutter = try c.decodeIfPresent(Bool.self, forKey: .muteShutter) ?? false
        shutterLimit = try c.decodeIfPresent(Int.self, forKey: .shutterLimit) ?? 0
        nightBursts = try c.decodeIfPresent(Bool.self, forKey: .nightBursts) ?? true
        mirrorFront = try c.decodeIfPresent(Bool.self, forKey: .mirrorFront) ?? false
        highlightRetentionStops = try c.decodeIfPresent(Double.self, forKey: .highlightRetentionStops) ?? 2
        bracketMetering = try c.decodeIfPresent(String.self, forKey: .bracketMetering)
        aspect = try c.decodeIfPresent(Int.self, forKey: .aspect)
        look = try c.decodeIfPresent(Data.self, forKey: .look)
        looks = try c.decodeIfPresent([Look].self, forKey: .looks) ?? []
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? false
        showLook = try c.decodeIfPresent(Bool.self, forKey: .showLook) ?? false
        scanCodes = try c.decodeIfPresent(Bool.self, forKey: .scanCodes) ?? false
        defaultLens = try c.decodeIfPresent(Int.self, forKey: .defaultLens) ?? 0
        lensReadout = try c.decodeIfPresent(String.self, forKey: .lensReadout)
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 1
    }
}

struct CrepusculeCaptureIntent: CameraCaptureIntent {
    typealias AppContext = LockedCaptureContext
    static let title: LocalizedStringResource = "Open Camera"
    static let description = IntentDescription("Opens the Crepuscule camera, even from the Lock Screen.")

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.camera)
        #endif
        return .result()
    }
}

enum DriveOption: String, AppEnum {
    case single, burst3, burst5, bracket3, bracket5
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Drive"
    static let caseDisplayRepresentations: [DriveOption: DisplayRepresentation] = [
        .single: "Single", .burst3: "Burst 3", .burst5: "Burst 5", .bracket3: "Bracket 3", .bracket5: "Bracket 5",
    ]
}

enum TimerOption: Int, AppEnum {
    case off = 0, three = 3, ten = 10
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static let caseDisplayRepresentations: [TimerOption: DisplayRepresentation] = [
        .off: "Off", .three: "3 Seconds", .ten: "10 Seconds",
    ]
}

struct TakePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Photo"
    static let description = IntentDescription("Opens Crepuscule and takes a RAW photo. Drive and timer apply to this shot only.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Drive") var drive: DriveOption?
    @Parameter(title: "Timer") var timer: TimerOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Take a photo") {
            \.$drive
            \.$timer
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.shoot(drive: drive.flatMap { .init(rawValue: $0.rawValue) }, timer: timer.flatMap { .init(rawValue: $0.rawValue) }))
        #endif
        return .result()
    }
}

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Opens your latest Crepuscule photo.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor func perform() async throws -> some IntentResult {
        #if CREPUSCULE_APP
        IntentRouter.shared.request(.library)
        #endif
        return .result()
    }
}
